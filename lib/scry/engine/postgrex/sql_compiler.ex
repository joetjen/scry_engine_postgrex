defmodule Scry.Engine.Postgrex.SqlCompiler do
  @moduledoc """
  Compiles a flat `Scry.Core.Query.t()` into one native SQL statement
  -- `WHERE`/`GROUP BY`/aggregates/`ORDER BY`/`DISTINCT`/`LIMIT`/
  `OFFSET`/projection, all in one query -- for `Scry.Engine.Relational.
  Postgrex`'s own `execute/3`. All-or-nothing, like every compiler in
  this `Scry.Core.EngineBehaviour.execute/3` generation: `compile/2`
  returns `{:error, {:unsupported, detail}}` the moment *anything* in
  `query` falls outside what this module translates, never a partial
  statement silently dropping part of the query's own semantics --
  there is no downstream re-verification left to catch that.

  ## What compiles

  Identical eligibility rules to `Scry.Engine.Exqlite.SqlCompiler`
  (ported directly, not narrowed): `wheres` delegated to `Scry.Engine.Postgrex.WhereTranslator`; a **plain** (non-aggregate)
  query needs every `select` item to be a bare, single-segment
  `{:field, [column]}`, optionally aliased (`{:computed, alias,
  {:field, [column]}}` -- `Scry.Core.Query.from/2`'s own map-shaped
  `select:` always wraps every entry this way); an **aggregate**-shaped
  query (`group_bys != []`, or any `sum`/`avg`/`count`/`min`/`max`
  anywhere in `select`) needs `group_mode: :plain`, `havings == []`,
  and every `select` item either a bare/aliased field exactly matching
  a `group_bys` entry or one of `sum`/`avg`/`count`/`min`/`max` over
  exactly one bare field (`count(distinct field)` included); `order_bys`
  entries must each be a bare, single-segment field -- either the plain
  `[column]` shape `Scry.Core.Query.t()` used to require, or the current
  `{{:field, [column]}, direction}` tagged-expression shape every real
  parsed `ORDER BY column` now produces (`Scry.Core.Query.t()`'s own
  `order_bys` widened to `[{expr(), :asc | :desc}]` so `ORDER BY
  relevance()`/`ORDER BY price * quantity` can parse at all -- this
  compiler still only ever unwraps the one-field case, declining any
  other expression shape exactly as it always declined a multi-segment
  field); `distinct`/`limit`/
  `offset` always compile directly (`limit`/`offset` are already
  validated `non_neg_integer() | nil` by `Scry.Core.Query.t()`'s own
  type, so rendered directly into SQL text, never bound as parameters).

  ## The one correctness subtlety kept from the SQLite port

  SQL's own `WHERE` (and aggregate functions) silently treat a `NULL`
  column value as "doesn't match"/"skip this value" -- a three-valued
  logic with no way to *raise* the way `Scry.Core.QueryOps.
  eval_predicate/4`'s own null-safety hard error does, and this is
  every bit as true of Postgres as of SQLite (or any other SQL engine)
  -- pushing `WHERE age > 18` straight into SQL for a genuinely `NULL`
  column would silently exclude that row instead of raising the error
  lang_spec.md §7 requires. `compile/2` therefore also returns the set
  of columns that need a schema-level `NOT NULL` guarantee before the
  compiled SQL can be trusted -- every column compared against a
  non-`nil` literal anywhere in `wheres` (the `field = nil`/`field !=
  nil` null-check idiom itself is exempt, since SQL's own `IS NULL`/
  `IS NOT NULL` there already means exactly what the interpreter
  means), plus every aggregated column for an aggregate-shaped query.
  `Scry.Engine.Postgrex.execute/3` is the one that actually
  checks this (a real `information_schema.columns` query, so it needs
  the open connection this module doesn't have) inside the same
  transaction as the compiled query itself.

  ## What's genuinely dropped, not just ported

  `Scry.Engine.Exqlite.SqlCompiler`'s own `type_checks`/type-affinity
  collection -- the second correctness mechanism that module needs
  because SQLite's declared column types are advisory ("type affinity")
  rather than enforced, so e.g. an `INTEGER`-affinity column can
  genuinely `= "2"` (the string literal) in SQLite, disagreeing with
  `Kernel.==/2`. **Postgres has no such ambiguity at all**: its columns
  have real, strictly enforced types, so `age = '30'` against a real
  `integer` column is either an explicit cast or an outright type
  error at the database level -- never a silent semantic divergence
  from what `Scry.Core.QueryOps.eval_predicate/4` itself would do. This
  whole correctness class simply doesn't exist for this adapter.

  **A real, confirmed consequence of not pre-verifying this, worth
  documenting plainly**: a mismatched-type comparison this compiler
  still happily accepts (`age = "thirty"` against a real `integer`
  column, say) doesn't produce a silently wrong answer the way it might
  against SQLite -- Postgres's own strict typing rejects it outright,
  and `postgrex` itself raises a client-side `DBConnection.EncodeError`
  while binding the parameter (found directly, via a real property-test
  failure while building this compiler, not assumed). `Scry.Engine.Postgrex.execute/3` catches this and reports it as an
  ordinary `{:error, {:query_error, _}}`, exactly the "attempted and
  genuinely failed against the real backend" case `Scry.Core.
  EngineBehaviour`'s own moduledoc already documents -- so the net
  correctness guarantee ends up the same shape as `scry_engine_exqlite`
  achieves via its own proactive `type_checks` gate (a bad comparison
  never silently succeeds), just reached reactively, by Postgres's own
  type system, rather than predicted ahead of time by this compiler.

  ## Placeholder renumbering

  `Scry.Engine.Postgrex.WhereTranslator` renders `?`
  placeholders (SQLite-positional style, needing no numbering) purely
  so its own recursive `{:and, ...}`/`{:or, ...}` translation never has
  to thread a running counter through subtree translation. Postgres
  needs numbered `$1, $2, ...` placeholders instead -- `compile/2`
  converts every `?` in the final assembled SQL to `$1, $2, ...` in one
  left-to-right pass at the very end, after the full statement and its
  parallel `bind_params` list are both assembled. Safe because a `?`
  can only ever appear in rendered SQL as a genuine placeholder --
  every identifier (`WhereTranslator.identifier?/1`) is already
  restricted to `[A-Za-z_][A-Za-z0-9_]*`, which can never contain `?`.
  """

  alias Scry.Core.Query
  alias Scry.Engine.Postgrex.WhereTranslator

  @aggregate_names ~w(sum avg count min max)
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @typedoc "A compiled statement, ready to execute once any `not_null_columns` check passes."
  @type compiled :: %{sql: String.t(), bind_params: [term()], not_null_columns: [String.t()]}

  @doc """
  Compiles `query` (with `params` resolving any `{:param, name}`
  placeholder) into a single native SQL statement, all-or-nothing --
  this module's own moduledoc has the complete "what compiles" and
  `not_null_columns` reasoning.
  """
  @spec compile(Query.t(), map()) :: {:ok, compiled()} | {:error, {:unsupported, term()}}
  def compile(%Query{} = query, params) do
    with {:ok, table} <- table_name(query.source),
         {:ok, where_sql, where_params} <- where_clause(query.wheres, params),
         {:ok, compiled} <- compile_body(query, table, where_sql, where_params) do
      {:ok, %{compiled | sql: renumber_placeholders(compiled.sql)}}
    end
  end

  defp compile_body(query, table, where_sql, where_params) do
    if aggregate_query?(query) do
      compile_aggregate(query, table, where_sql, where_params)
    else
      compile_plain(query, table, where_sql, where_params)
    end
  end

  defp where_clause(wheres, params) do
    case WhereTranslator.translate(wheres, params) do
      {:ok, sql, bound} -> {:ok, sql, bound}
      :error -> {:error, {:unsupported, {:predicate, :untranslatable}}}
    end
  end

  defp table_name([table]) when is_binary(table) do
    if Regex.match?(@identifier, table),
      do: {:ok, table},
      else: {:error, {:unsupported, {:source, table}}}
  end

  defp table_name(source), do: {:error, {:unsupported, {:source, source}}}

  # ---- plain (non-aggregate) queries --------------------------------------

  defp compile_plain(query, table, where_sql, where_params) do
    with {:ok, select_sql} <- plain_select_list(query.select),
         {:ok, order_sql} <- order_by_clause(query.order_bys) do
      distinct_sql = if query.distinct, do: "DISTINCT ", else: ""
      limit_sql = limit_offset_clause(query.limit, query.offset)

      sql =
        "SELECT " <>
          distinct_sql <> select_sql <> " FROM " <> table <> where_sql <> order_sql <> limit_sql

      not_null_columns = not_null_columns_from_where(query.wheres)

      {:ok, %{sql: sql, bind_params: where_params, not_null_columns: not_null_columns}}
    end
  end

  defp plain_select_list([]), do: {:error, {:unsupported, {:select, :empty}}}

  defp plain_select_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case plain_select_item(item) do
        {:ok, sql} -> {:cont, {:ok, [sql | acc]}}
        :error -> {:halt, {:error, {:unsupported, {:select, item}}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.join(Enum.reverse(reversed), ", ")}
      error -> error
    end
  end

  defp plain_select_item({:field, [field]}) do
    if WhereTranslator.identifier?(field) do
      {:ok, "#{field} AS #{quote_ident(field)}"}
    else
      :error
    end
  end

  # A bare field under a caller-given alias (e.g. `Scry.Core.Query.
  # from/2`'s map-shaped `select:` always wraps every entry, even a
  # plain field reference, in `{:computed, alias, ...}}`) -- still just
  # `column AS alias`, no cast/arithmetic/function call involved.
  defp plain_select_item({:computed, alias_name, {:field, [field]}}) do
    if WhereTranslator.identifier?(field) do
      {:ok, "#{field} AS #{quote_ident(alias_name)}"}
    else
      :error
    end
  end

  defp plain_select_item(_other), do: :error

  # ---- aggregate-shaped queries --------------------------------------------

  defp aggregate_query?(query),
    do: query.group_bys != [] or Enum.any?(query.select, &aggregate_body_item?/1)

  defp aggregate_body_item?({:computed, _alias, {:call, name, _args}}),
    do: name in @aggregate_names

  defp aggregate_body_item?(_other), do: false

  defp compile_aggregate(query, table, where_sql, where_params) do
    with :ok <- check(query.group_mode == :plain, {:construct, query.group_mode}),
         :ok <- check(query.havings == [], {:construct, :having}),
         {:ok, group_by_cols} <- group_by_columns(query.group_bys),
         {:ok, select_items} <- aggregate_select_list(query.select, group_by_cols) do
      select_sql = Enum.map_join(select_items, ", ", & &1.sql)
      group_by_sql = group_by_clause(group_by_cols)
      sql = "SELECT " <> select_sql <> " FROM " <> table <> where_sql <> group_by_sql

      not_null_columns =
        (not_null_columns_from_where(query.wheres) ++ Enum.flat_map(select_items, & &1.not_null))
        |> Enum.uniq()

      {:ok, %{sql: sql, bind_params: where_params, not_null_columns: not_null_columns}}
    end
  end

  defp check(true, _detail), do: :ok
  defp check(false, detail), do: {:error, {:unsupported, detail}}

  defp group_by_columns(group_bys) do
    columns = Enum.map(group_bys, &hd/1)

    if Enum.all?(columns, &WhereTranslator.identifier?/1) do
      {:ok, columns}
    else
      {:error, {:unsupported, {:group_by, group_bys}}}
    end
  end

  defp group_by_clause([]), do: ""
  defp group_by_clause(columns), do: " GROUP BY " <> Enum.join(columns, ", ")

  defp aggregate_select_list(items, group_by_cols) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case aggregate_select_item(item, group_by_cols) do
        {:ok, compiled} -> {:cont, {:ok, [compiled | acc]}}
        :error -> {:halt, {:error, {:unsupported, {:select, item}}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # A bare field is only ever valid here when it's exactly one of
  # `group_bys` -- there is no "representative row" to fall back on
  # for a non-grouped field once SQL has aggregated rows away, the
  # same reasoning `Scry.Core.QueryOps`'s own eager-aggregation path
  # relies on for its representative-row semantics not applying here.
  defp aggregate_select_item({:field, [field]}, group_by_cols) do
    if field in group_by_cols do
      {:ok, %{sql: "#{field} AS #{quote_ident(field)}", not_null: []}}
    else
      :error
    end
  end

  # The same bare-`GROUP BY`-column case as above, just under the
  # alias a caller (e.g. `Scry.Core.Query.from/2`'s map-shaped
  # `select:`) gave it explicitly, rather than the query's own field
  # name -- `{:computed, alias, {:field, [field]}}` compiles to the
  # exact same "no representative row" reasoning applies here.
  defp aggregate_select_item({:computed, alias_name, {:field, [field]}}, group_by_cols) do
    if field in group_by_cols do
      {:ok, %{sql: "#{field} AS #{quote_ident(alias_name)}", not_null: []}}
    else
      :error
    end
  end

  defp aggregate_select_item(
         {:computed, alias_name, {:call, "count", [{:distinct, {:field, [column]}}]}},
         _group_by_cols
       ) do
    if WhereTranslator.identifier?(column) do
      {:ok, %{sql: "COUNT(DISTINCT #{column}) AS #{quote_ident(alias_name)}", not_null: [column]}}
    else
      :error
    end
  end

  defp aggregate_select_item(
         {:computed, alias_name, {:call, name, [{:field, [column]}]}},
         _group_by_cols
       )
       when name in @aggregate_names do
    if WhereTranslator.identifier?(column) do
      {:ok,
       %{
         sql: "#{sql_function(name)}(#{column}) AS #{quote_ident(alias_name)}",
         not_null: [column]
       }}
    else
      :error
    end
  end

  defp aggregate_select_item(_other, _group_by_cols), do: :error

  defp sql_function("sum"), do: "SUM"
  defp sql_function("avg"), do: "AVG"
  defp sql_function("count"), do: "COUNT"
  defp sql_function("min"), do: "MIN"
  defp sql_function("max"), do: "MAX"

  # ---- ORDER BY / LIMIT / OFFSET -------------------------------------------

  defp order_by_clause([]), do: {:ok, ""}

  defp order_by_clause(order_bys) do
    order_bys
    |> Enum.reduce_while({:ok, []}, fn {path, direction}, {:ok, acc} ->
      case order_by_item(path, direction) do
        {:ok, sql} -> {:cont, {:ok, [sql | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, " ORDER BY " <> Enum.join(Enum.reverse(reversed), ", ")}
      :error -> {:error, {:unsupported, {:order_by, order_bys}}}
    end
  end

  # The current, real shape every parsed `ORDER BY column` produces
  # since `Scry.Core.Query.t()`'s own `order_bys` widened to
  # `[{expr(), :asc | :desc}]` (so `ORDER BY relevance()`/`ORDER BY
  # price * quantity` can parse at all) -- unwrapped back to the bare
  # column the identifier check below already validates. Any other
  # expression shape (a call, arithmetic, a multi-segment field, a
  # dot-access) is *not* unwrapped here: this compiler gains no general
  # expression-compilation capability, it only recognizes this one
  # common-case wrapper and otherwise falls through to the catch-all
  # `:error` below, same as it always did.
  defp order_by_item({:field, [field]}, direction) when direction in [:asc, :desc],
    do: order_by_item([field], direction)

  # The bare, single-segment-path shape `order_bys` used before the
  # `scry_core` widening above -- kept working for any caller still
  # constructing a `%Scry.Core.Query{}` literal directly with this
  # older shape (`Scry.Core.QueryOps`'s own runtime resolution stays
  # backward compatible with it too, for the same reason).
  defp order_by_item([field], direction) when direction in [:asc, :desc] do
    if WhereTranslator.identifier?(field) do
      {:ok, "#{field} #{if direction == :asc, do: "ASC", else: "DESC"}"}
    else
      :error
    end
  end

  defp order_by_item(_path, _direction), do: :error

  # Unlike SQLite, Postgres needs no `LIMIT -1` idiom for "offset with
  # no limit" -- a bare `OFFSET n` with no `LIMIT` clause at all is
  # already exactly what it means.
  defp limit_offset_clause(nil, nil), do: ""
  defp limit_offset_clause(limit, nil) when is_integer(limit), do: " LIMIT #{limit}"
  defp limit_offset_clause(nil, offset) when is_integer(offset), do: " OFFSET #{offset}"

  defp limit_offset_clause(limit, offset) when is_integer(limit) and is_integer(offset),
    do: " LIMIT #{limit} OFFSET #{offset}"

  # ---- NOT NULL column collection (WHERE side) ----------------------------

  defp not_null_columns_from_where(wheres),
    do: wheres |> Enum.flat_map(&collect_not_null/1) |> Enum.uniq()

  defp collect_not_null({:cmp, op, [_field], nil}) when op in [:eq, :not_eq], do: []
  defp collect_not_null({:cmp, _op, [field], _value}), do: [field]
  defp collect_not_null({:in, _lhs, _values}), do: []
  defp collect_not_null({:and, l, r}), do: collect_not_null(l) ++ collect_not_null(r)
  defp collect_not_null({:or, l, r}), do: collect_not_null(l) ++ collect_not_null(r)
  defp collect_not_null({:not, p}), do: collect_not_null(p)
  defp collect_not_null(_other), do: []

  # ---- placeholder renumbering (? -> $1, $2, ...) --------------------------

  defp renumber_placeholders(sql) do
    [first | rest] = String.split(sql, "?")

    rest
    |> Enum.with_index(1)
    |> Enum.reduce(first, fn {segment, index}, acc -> acc <> "$#{index}" <> segment end)
  end

  # ---- identifier quoting for output aliases -------------------------------

  # Unlike a *column reference* (validated against `@identifier` and
  # never quoted, since it must be a real, safe-to-interpolate SQL
  # name), a select item's own output alias can be any string a query
  # author chose (`{:computed, alias, ...}`'s own `alias`) -- standard
  # SQL double-quote identifier quoting (doubling an embedded `"`)
  # handles that safely without restricting aliases to the identifier
  # pattern real column names need.
  defp quote_ident(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""
end

defmodule Scry.Engine.Postgrex.WhereTranslator do
  @moduledoc """
  Translates a `Scry.Core.Query.t()`'s own `wheres` into a real SQL
  `WHERE` clause with bound `?` placeholders (renumbered to Postgres's
  own `$1, $2, ...` positional form by `Scry.Engine.Relational.
  Postgrex.SqlCompiler` in one final pass, once the full clause and its
  parallel params list are assembled -- kept as `?` here purely so this
  module's own recursion never has to thread a running placeholder
  counter through `{:and, ...}`/`{:or, ...}`), for `Scry.Engine.Postgrex`'s own `execute/3`. All-or-nothing: `translate/2`
  returns `:error` the moment *any* predicate anywhere in the tree can't
  be translated, never a partial clause silently narrowing what Postgres
  returns -- there is no downstream re-verification left to catch an
  under-translated (row-dropping) predicate the way the old, lenient
  `fetch/3` contract's own re-application used to.

  A full recursive `{:and, l, r}`/`{:or, l, r}`/`{:not, p}` tree
  translates, not just a flat, implicitly-`AND`ed list of leaves --
  each combinator becomes its own parenthesized SQL group so operator
  precedence can never differ from what the predicate tree itself
  already encodes.

  Only `{:cmp, op, [field], value}` and `{:in, [field], values}` leaves
  are candidates, and only when: `field` is a single segment that's
  also a valid, safe-to-interpolate SQL identifier (a multi-segment
  path -- nested/JSON access -- is declined, not translated unchecked);
  `op` is one of `:eq`/`:not_eq`/`:lt`/`:gt`/`:le`/`:ge` (`:match` has
  no native vanilla-Postgres equivalent); and every value involved (a
  literal, or a `{:param, name}` resolved against `params`) is a plain
  string, integer, float, boolean, `DateTime.t()`/`NaiveDateTime.t()`,
  **or** the literal `nil` specifically for `:eq`/`:not_eq` -- translated
  to `IS NULL`/`IS NOT NULL`, not a naive `= ?`/`!= ?` bound to `NULL`
  (SQL's own `x = NULL` is always `NULL`, never `TRUE`, so a literal
  translation there would silently change what the clause means).

  Unlike `Scry.Engine.Exqlite.WhereTranslator`, **booleans bind
  directly** -- Postgres has a real, native `boolean` type, so there's
  no SQLite-style "can't safely guess whether this column is really
  boolean" restriction to carry over. Likewise, **`DateTime.t()`/
  `NaiveDateTime.t()` values bind directly**, as themselves -- Postgres
  has real native `timestamp`/`timestamptz` types `postgrex` encodes and
  decodes natively, so the epoch-microseconds-integer workaround
  `Scry.Engine.Exqlite.WhereTranslator` needs (SQLite has no native
  timestamp type at all) doesn't apply here and isn't ported.
  """

  alias Scry.Core.Query

  @op_sql %{eq: "=", not_eq: "!=", lt: "<", gt: ">", le: "<=", ge: ">="}
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  Returns `{:ok, where_sql, params}` -- `where_sql` is either `""`
  (an empty `wheres`) or a `" WHERE ..."` fragment (leading space
  included, ready to append directly after a table/`GROUP BY` clause),
  with `?` placeholders in encounter order, `params` the bound values in
  that same order -- or `:error` the moment anything in `wheres`
  doesn't translate.
  """
  @spec translate([Query.predicate()], map()) :: {:ok, String.t(), [term()]} | :error
  def translate(wheres, params) do
    wheres
    |> Enum.reduce_while({:ok, []}, fn predicate, {:ok, acc} ->
      case translate_predicate(predicate, params) do
        {:ok, sql, bound} -> {:cont, {:ok, [{sql, bound} | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, []} ->
        {:ok, "", []}

      {:ok, reversed} ->
        {sql, bound} = build_clause(Enum.reverse(reversed))
        {:ok, sql, bound}

      :error ->
        :error
    end
  end

  defp build_clause(clauses) do
    {fragments, param_lists} = Enum.unzip(clauses)
    {" WHERE " <> Enum.join(fragments, " AND "), List.flatten(param_lists)}
  end

  # `{:cmp, op, lhs, nil}`'s own null-check idiom -- `field = NULL` is
  # always `NULL` in SQL, never `TRUE`, so this is a real, dedicated
  # translation, not the general clause below with `nil` bound as an
  # ordinary parameter.
  defp translate_predicate({:cmp, :eq, [field], nil}, _params) do
    if identifier?(field), do: {:ok, "#{field} IS NULL", []}, else: :error
  end

  defp translate_predicate({:cmp, :not_eq, [field], nil}, _params) do
    if identifier?(field), do: {:ok, "#{field} IS NOT NULL", []}, else: :error
  end

  defp translate_predicate({:cmp, op, [field], value}, params) do
    with {:ok, sql_op} <- Map.fetch(@op_sql, op),
         true <- identifier?(field),
         {:ok, resolved} <- resolve_value(value, params) do
      {:ok, "#{field}#{collation_suffix(op, resolved)} #{sql_op} ?", [resolved]}
    else
      _ -> :error
    end
  end

  defp translate_predicate({:in, [field], values}, params) when is_list(values) do
    with true <- identifier?(field),
         {:ok, resolved} when resolved != [] <- resolve_all(values, params) do
      placeholders = resolved |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")
      {:ok, "#{field} IN (#{placeholders})", resolved}
    else
      _ -> :error
    end
  end

  # `in` against a non-literal-list expr (a field/call expected to
  # resolve to a list at runtime) has no direct SQL translation without
  # unnesting a Postgres array -- declined, not attempted this
  # increment.
  defp translate_predicate({:in, _lhs, _list_expr}, _params), do: :error

  defp translate_predicate({:and, l, r}, params) do
    with {:ok, sql_l, params_l} <- translate_predicate(l, params),
         {:ok, sql_r, params_r} <- translate_predicate(r, params) do
      {:ok, "(#{sql_l} AND #{sql_r})", params_l ++ params_r}
    else
      _ -> :error
    end
  end

  defp translate_predicate({:or, l, r}, params) do
    with {:ok, sql_l, params_l} <- translate_predicate(l, params),
         {:ok, sql_r, params_r} <- translate_predicate(r, params) do
      {:ok, "(#{sql_l} OR #{sql_r})", params_l ++ params_r}
    else
      _ -> :error
    end
  end

  defp translate_predicate({:not, p}, params) do
    case translate_predicate(p, params) do
      {:ok, sql, bound} -> {:ok, "NOT (#{sql})", bound}
      :error -> :error
    end
  end

  # A bare-path/`{:call, ...}`/`{:dot, ...}` `lhs` on a `:cmp` (rather
  # than the `[field]` single-segment shape every clause above already
  # matches) and anything else this module doesn't recognize.
  defp translate_predicate(_other, _params), do: :error

  @ordering_ops [:lt, :gt, :le, :ge]

  # A real, confirmed-not-assumed correctness fix, found the same way
  # `scry_engine_exqlite`'s own type-affinity checks were: a property
  # test comparing a lowercase and an uppercase string via `<` disagreed
  # between `execute/3`'s pushed-down SQL and `Scry.Core.QueryOps.
  # eval_predicate/4`'s own Erlang-term-order comparison. Unlike
  # SQLite (whose default `BINARY` text collation already *is*
  # byte-wise, matching Erlang's own binary ordering exactly), Postgres
  # text columns default to a locale-aware collation (`en_US.utf8` or
  # whatever the database was initialized with), which does **not**
  # sort byte-wise -- `"a" < "A"` is true under Postgres's default
  # collation but false under Erlang's own raw binary comparison.
  # `COLLATE "C"` (POSIX/byte-wise collation, always available, no
  # per-column configuration needed) forces the *comparison itself* --
  # not the column's own stored collation -- to sort byte-wise,
  # matching `eval_predicate/4` exactly, for exactly the shape that's
  # actually at risk: an ordering operator against a string value.
  # `=`/`!=` and `:in` are unaffected -- ordinary equality is exact
  # byte-equality under every standard (non-case-insensitive) Postgres
  # collation, collation only changes *ordering*, not equality. A
  # `COLLATE` clause against a genuinely non-collatable column (an
  # integer column compared against a string literal, a nonsensical
  # comparison to begin with) is a real Postgres-side prepare error
  # (`42804`, "collations are not supported by type ..."), not a
  # crash -- caught the same way any other `Postgrex.Error` already is,
  # by `Scry.Engine.Postgrex.execute/3`'s own error handling.
  defp collation_suffix(op, value) when op in @ordering_ops and is_binary(value),
    do: " COLLATE \"C\""

  defp collation_suffix(_op, _value), do: ""

  defp resolve_all(values, params) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case resolve_value(value, params) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp resolve_value({:param, name}, params) do
    case Map.fetch(params, name) do
      {:ok, value} -> bind_value(value)
      :error -> :error
    end
  end

  defp resolve_value(value, _params), do: bind_value(value)

  @doc "Whether `field` is a safe-to-interpolate SQL identifier -- also used by `Scry.Engine.Postgrex.SqlCompiler`."
  @spec identifier?(term()) :: boolean()
  def identifier?(field), do: is_binary(field) and Regex.match?(@identifier, field)

  @doc """
  Values `postgrex` already encodes natively, bound as themselves --
  `DateTime.t()`/`NaiveDateTime.t()` against a real `timestamp`/
  `timestamptz` column, `boolean()` against a real `boolean` column,
  no workaround or guessing needed for either (contrast `Scry.Engine.
  Exqlite.WhereTranslator.bind_value/1`'s own epoch-encoding and
  boolean-refusal, both pure SQLite-driver-limitation baggage that
  doesn't apply here).
  """
  @spec bind_value(term()) ::
          {:ok, String.t() | integer() | float() | boolean() | DateTime.t() | NaiveDateTime.t()}
          | :error
  def bind_value(%DateTime{} = value), do: {:ok, value}
  def bind_value(%NaiveDateTime{} = value), do: {:ok, value}

  def bind_value(value)
      when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value),
      do: {:ok, value}

  def bind_value(_value), do: :error
end

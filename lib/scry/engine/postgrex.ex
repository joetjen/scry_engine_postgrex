defmodule Scry.Engine.Postgrex do
  @moduledoc """
  A real `Scry.Core.EngineBehaviour` implementation over PostgreSQL, via
  the `postgrex` driver -- the direct Postgres counterpart to `Scry.
  Engine.Exqlite`, ported deliberately from that package (see this
  repo's own `CHANGELOG.md` for exactly what's generic versus what
  needed real redesign).

  `execute/3` compiles the *entire* flat query -- `WHERE`/`GROUP BY`/
  aggregates/`ORDER BY`/`DISTINCT`/`LIMIT`/`OFFSET`/projection -- into
  one native SQL statement via `Scry.Engine.Postgrex.
  SqlCompiler`, all or nothing: that module's own moduledoc has the
  exact eligible query shapes and the real correctness work behind
  declining anything it can't (a schema-level `NOT NULL` check, run in
  the same transaction as the compiled query itself, for every column
  a nullable value could otherwise make SQL's own three-valued
  `WHERE`/aggregate semantics silently diverge from `Scry.Core.
  QueryOps.eval_predicate/4`'s own null-safety hard error).

  **Rows come back as `Scry.Core.Row.t()` values, not plain maps**, for
  this direct, wholly-pushed-down path (a nested/correlated `SELECT`/
  `WITH`-bound source still returns plain maps -- delegated to `Scry.
  Core.QueryOps.run_document/4`, whose own final projection step always
  builds one). A caller wanting a plain map calls `Scry.Core.Row.
  to_map/1`; `Scry.Core.QueryOps` itself already treats a `Row` as a
  first-class row shape throughout.

  **A pushed-down `sum`/`avg`/etc. over an `integer`/`bigint`/`numeric`
  column comes back genuinely exact**, not a native float -- Postgres's
  own `SUM()`/`AVG()` over those column types returns `numeric`
  (arbitrary-precision decimal), which `postgrex` decodes as a
  `Decimal.t()`; this module converts that to a `Scry.Core.Rational`
  (or a plain integer, when the decimal is already whole) before
  returning the row, so exactness survives the round trip. A column
  declared `real`/`double precision` still decodes as a native
  `float()` either way -- no exactness is possible there regardless of
  this adapter, the same situation `scry_engine_exqlite`'s own SQLite
  `REAL` columns already have.

  **Deliberately eager, not lazy, this increment** -- every query this
  module actually executes fully materializes its own result rows
  before `execute/3` returns, never a genuinely lazy, still-streaming
  `Enumerable.t()`. `Postgrex.stream/4`'s own server-side cursor is
  scoped to the `Postgrex.transaction/3` callback's own function body --
  unlike `scry_engine_exqlite`'s raw SQLite file handle, which can stay
  open and be stepped through across an arbitrary caller-controlled
  consumption window, holding a checked-out Postgres connection + open
  transaction + live cursor across `execute/3`'s own return boundary
  needs real, separate machinery (a `DBConnection.checkout/2`-based
  resource pattern) disproportionate to a first working version of this
  adapter. A real, explicit scope decision, not an oversight -- a
  natural, well-motivated follow-on once genuine streaming is needed.

  A query `SqlCompiler` declines (a window function, `ROLLUP`/`CUBE`, a
  real `HAVING` clause, `json(...)`/other casts or arithmetic in
  `select`, a `WHERE` predicate wider than it translates) is a real,
  clean `{:error, {:unsupported, detail}}` -- no fallback exists here to
  fully interpret it in Elixir instead; a caller wanting that construct
  against a Postgres connection needs a future increment of this
  compiler, or a different engine.

  A query containing a nested/correlated `SELECT` body item, or whose
  own `source` names a declared `WITH` binding, is delegated whole to
  `Scry.Core.QueryOps.run_document/4` instead of attempted here -- this
  module doesn't (yet) translate either into a native `JOIN`/CTE, though
  a future increment legitimately could; `run_document/4` recurses back
  into this same module's `execute/3` for each flat leaf it resolves,
  so whatever native pushdown *does* apply to those leaves still does.

  Table (and column) names are validated against a plain SQL-identifier
  pattern before ever being interpolated into a SQL string --
  `WhereTranslator.identifier?/1`, reused by `SqlCompiler` directly.
  Every *value* is always bound via a real numbered placeholder
  (`$1, $2, ...`), never string-interpolated.

  Connection pool lifecycle (`Postgrex.start_link/1`), schema, and
  index creation are deliberately not this module's job: `Scry.Engine.Postgrex.Conn.open/1` opens a pool once, reused across as
  many `execute/3` calls as the caller likes; creating tables/indexes
  against it is entirely up to the caller (this package is schema-
  agnostic, issuing nothing but `SELECT`/`information_schema` queries).
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, EngineBehaviour, Query, QueryOps, Rational, Row}
  alias Scry.Engine.Postgrex.{Conn, Schema, SqlCompiler}

  @impl true
  def execute(conn, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(conn, combined, params, __MODULE__)

  def execute(%Conn{} = conn, %Query{source: source} = query, params) do
    if Enum.any?(query.select, &match?(%Query{}, &1)) or with_bound_source?(query) do
      QueryOps.run_document(conn, query, params, __MODULE__)
    else
      case SqlCompiler.compile(query, params) do
        {:ok, %{not_null_columns: []} = compiled} ->
          run_sql(conn, compiled)

        {:ok, compiled} ->
          [table] = source
          run_sql_with_schema_check(conn, table, compiled)

        {:error, _} = error ->
          error
      end
    end
  end

  defp with_bound_source?(%Query{source: [name], with_bindings: with_bindings}),
    do: Map.has_key?(with_bindings, name)

  defp with_bound_source?(_query), do: false

  defp run_sql(%Conn{pool: pool}, %{sql: sql, bind_params: bind_params}) do
    case Postgrex.query(pool, sql, bind_params) do
      {:ok, result} -> {:ok, rows_from_result(result)}
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  rescue
    error -> {:error, {:query_error, error}}
  end

  # `Scry.Engine.Postgrex.SqlCompiler`'s own moduledoc has
  # the full reasoning for the schema check this makes: the check and
  # the compiled query itself run inside one transaction, over the
  # *same* checked-out connection, so a schema change on another
  # session between an isolated check and the query can't let a real
  # `NULL` slip through none of Scry's own guarantees would have
  # caught -- an `ALTER TABLE ... DROP NOT NULL` needs an `ACCESS
  # EXCLUSIVE` lock that can't proceed until this transaction ends.
  #
  # Both `Postgrex.query/3` calls here are wrapped defensively (`rescue`,
  # not just their own `{:ok,_}/{:error,_}` return) -- confirmed
  # directly, not assumed, via a real property-test failure while
  # building this module: unlike SQLite's weakly-typed columns,
  # `postgrex` raises a client-side `DBConnection.EncodeError` (not a
  # returned `{:error, _}`) when a bound parameter's own Elixir type
  # can't be encoded as the column's real, strictly-typed Postgres type
  # (e.g. a string literal compared against an `integer` column) --
  # `Scry.Core.EngineBehaviour`'s own contract requires `execute/3` to
  # decline via `{:error, error()}`, never raise, so this failure mode
  # has to be caught here, not left to crash the caller.
  defp run_sql_with_schema_check(%Conn{pool: pool} = conn, table, compiled) do
    pool
    |> Postgrex.transaction(fn transaction_conn ->
      transaction_scoped_conn = %Conn{conn | pool: transaction_conn}

      case Schema.verify(transaction_scoped_conn, table, compiled.not_null_columns) do
        :ok ->
          case Postgrex.query(transaction_conn, compiled.sql, compiled.bind_params) do
            {:ok, result} -> rows_from_result(result)
            {:error, reason} -> Postgrex.rollback(transaction_conn, {:query_error, reason})
          end

        {:error, reason} ->
          Postgrex.rollback(transaction_conn, reason)
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:query_error, error}}
  end

  defp rows_from_result(%Postgrex.Result{columns: columns, rows: rows}) do
    index = Row.build_index(columns)
    Enum.map(rows, fn row -> Row.new(index, Enum.map(row, &decode_value/1)) end)
  end

  # `postgrex` decodes a `numeric` column value (the type Postgres's own
  # `SUM()`/`AVG()` return for an `integer`/`bigint`/`numeric` argument)
  # as a `Decimal.t()` -- converted here to a `Scry.Core.Rational` (or a
  # plain integer, when the decimal's own exponent is non-negative, i.e.
  # already whole) so an aggregate pushed down through this adapter
  # stays exact, not a lossy float. A `Decimal.t()` whose own `coef` is
  # `:NaN`/`:inf` (never produced by this compiler's own eligible
  # aggregates in practice) is passed through unconverted rather than
  # crashing -- honest, since there is no rational value to convert it
  # to.
  defp decode_value(%Decimal{coef: coef} = value) when is_integer(coef),
    do: decimal_to_rational(value)

  defp decode_value(value), do: value

  defp decimal_to_rational(%Decimal{sign: sign, coef: coef, exp: exp}) when exp >= 0,
    do: sign * coef * Integer.pow(10, exp)

  defp decimal_to_rational(%Decimal{sign: sign, coef: coef, exp: exp}),
    do: Rational.new(sign * coef, Integer.pow(10, -exp))

  @doc """
  `Scry.Core.EngineBehaviour`'s optional `describe_source/2` callback --
  delegates straight to `Scry.Engine.Postgrex.Schema.
  describe_source/2`, which routes through the exact same per-`Conn`
  ETS cache the schema check above already uses.
  """
  @impl true
  @spec describe_source(Conn.t(), String.t()) ::
          {:ok, [EngineBehaviour.introspected_field()]}
          | {:error, :not_found}
          | {:error, {:introspection_error, term()}}
  def describe_source(conn, source), do: Schema.describe_source(conn, source)
end

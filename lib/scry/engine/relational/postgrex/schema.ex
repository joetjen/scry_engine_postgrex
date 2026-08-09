defmodule Scry.Engine.Relational.Postgrex.Schema do
  @moduledoc """
  Postgres schema introspection (`information_schema.columns`),
  extracted into its own module for the same reason `Scry.Engine.
  Exqlite.Schema` is: two independent consumers share one set of
  underlying facts and one cache. `Scry.Engine.Relational.Postgrex`'s
  own per-query, transaction-scoped `NOT NULL` gate (`Scry.Engine.
  Relational.Postgrex.execute/3`, re-checked on every call specifically
  because a concurrent schema change mid-query must still be caught)
  and this module's own `describe_source/2` (`Scry.Core.EngineBehaviour`'s
  optional callback, consumed by `Scry.Core.TypeCheck.Introspection` --
  a much less frequent, connection-level check, not a per-query one).

  ## Caching -- a real, deliberate difference from the SQLite port

  `Scry.Engine.Exqlite.Schema` re-checks freshness automatically and
  cheaply, via SQLite's own `PRAGMA schema_version` (one global integer,
  bumped by *any* schema-altering statement against that database file,
  from any connection). Postgres has no equally cheap, equally global
  "has this table's shape changed" signal without new infrastructure
  this package isn't in a position to impose on a caller (`LISTEN`/
  `NOTIFY` triggers the schema owner would have to set up themselves,
  or scraping catalog OIDs that don't reliably signal "this table's
  shape changed" the way a single counter does).

  This module's own cache, once populated for a `(table)` key, therefore
  stays valid **until explicitly busted** (`invalidate/2`) or the pool
  restarts -- not re-verified against live schema state on every call
  the way `Scry.Engine.Exqlite.Schema`'s is. This is a real, accepted
  limitation, not an oversight: a concurrent external DDL statement (a
  migration run from a different process while this pool stays up)
  won't be picked up by a cached `Conn` until a caller explicitly calls
  `invalidate/2`. A `%Conn{schema_cache: nil}` (built by hand, common in
  tests) always re-queries and is unaffected.
  """

  alias Scry.Core.EngineBehaviour
  alias Scry.Engine.Relational.Postgrex.Conn

  @typedoc "One `information_schema.columns` row: `[column_name, data_type, is_nullable]`."
  @type column_row :: [String.t()]

  @doc """
  Fetches `table`'s own columns (`information_schema.columns`, `public`
  schema) via `conn`, through its per-`Conn` ETS cache when one exists
  (`schema_cache: nil` -- a `%Conn{}` built by hand, common in tests --
  always re-queries). Returns `{:ok, []}` for a table that doesn't
  exist at all (a real, empty `information_schema.columns` result, not
  an error -- indistinguishable, from this query alone, from "a real
  zero-column table," which never happens in practice).
  """
  @spec column_info(Conn.t(), String.t()) :: {:ok, [column_row()]} | {:error, term()}
  def column_info(%Conn{schema_cache: nil} = conn, table), do: fetch_column_info(conn.pool, table)

  def column_info(%Conn{pool: pool, schema_cache: cache}, table) do
    case :ets.lookup(cache, table) do
      [{^table, rows}] ->
        {:ok, rows}

      [] ->
        with {:ok, rows} <- fetch_column_info(pool, table) do
          :ets.insert(cache, {table, rows})
          {:ok, rows}
        end
    end
  end

  @doc "Explicitly busts `table`'s own cached entry, if any -- see this module's own moduledoc for why this is manual rather than automatic."
  @spec invalidate(Conn.t(), String.t()) :: :ok
  def invalidate(%Conn{schema_cache: nil}, _table), do: :ok

  def invalidate(%Conn{schema_cache: cache}, table) do
    :ets.delete(cache, table)
    :ok
  end

  defp fetch_column_info(pool, table) do
    sql = """
    SELECT column_name, data_type, is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = $1
    ORDER BY ordinal_position
    """

    case Postgrex.query(pool, sql, [table]) do
      {:ok, %Postgrex.Result{rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  @doc """
  Verifies every entry in `not_null_columns` is schema-guaranteed
  `NOT NULL` (`is_nullable = 'NO'`), against `table`'s own real schema
  via `conn`. Returns `:ok` for a table with zero columns (see
  `column_info/2`'s own moduledoc) -- letting whatever real query runs
  next surface the genuine `{:query_error, ...}` for an actually-missing
  relation, rather than a misleading `{:unsupported, _}` from this
  check.
  """
  @spec verify(Conn.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def verify(conn, table, not_null_columns) do
    with {:ok, rows} <- column_info(conn, table) do
      verify_schema(rows, not_null_columns)
    end
  end

  defp verify_schema([], _not_null_columns), do: :ok

  defp verify_schema(rows, not_null_columns) do
    guaranteed_not_null =
      rows
      |> Enum.filter(fn [_name, _type, is_nullable] -> is_nullable == "NO" end)
      |> MapSet.new(fn [name, _type, _is_nullable] -> name end)

    if Enum.all?(not_null_columns, &MapSet.member?(guaranteed_not_null, &1)) do
      :ok
    else
      {:error, {:unsupported, {:nullable_column, not_null_columns}}}
    end
  end

  @doc """
  `Scry.Core.EngineBehaviour`'s optional `describe_source/2` callback,
  proper -- converts `source`'s own real `information_schema.columns`
  rows (via the same cache `verify/3` uses) into `Scry.Core.
  EngineBehaviour.introspected_field()`s.
  """
  @spec describe_source(Conn.t(), String.t()) ::
          {:ok, [EngineBehaviour.introspected_field()]}
          | {:error, :not_found}
          | {:error, {:introspection_error, term()}}
  def describe_source(conn, source) do
    case column_info(conn, source) do
      {:ok, []} -> {:error, :not_found}
      {:ok, rows} -> {:ok, Enum.map(rows, &introspected_field/1)}
      {:error, reason} -> {:error, {:introspection_error, reason}}
    end
  end

  defp introspected_field([name, data_type, is_nullable]) do
    %{name: name, nullable: is_nullable == "YES", scalar: introspected_scalar(data_type)}
  end

  # Postgres's `information_schema.columns.data_type` is a real,
  # disambiguated, already-human-readable type name -- no affinity
  # guessing needed, unlike `Scry.Engine.Exqlite.Schema`'s own 5-rule
  # SQLite classifier. `numeric` maps to `:float` as the closest
  # existing bucket -- `introspected_field.scalar`'s enum has no
  # separate exact-decimal slot, and `Scry.Core.TypeCheck`'s own
  # `@known_scalars` only ever enforces `Int`/`String` by name anyway,
  # so this is an honest descriptive choice, not a behavior-changing
  # one. Everything without a dedicated slot (timestamps, arrays,
  # `uuid`, `bytea`, enum/custom types) honestly reports `:unknown`
  # rather than guessing, the same posture the SQLite classifier
  # already established.
  defp introspected_scalar(data_type) do
    case data_type do
      t when t in ["integer", "bigint", "smallint"] -> :integer
      t when t in ["character varying", "character", "text"] -> :string
      "boolean" -> :boolean
      t when t in ["json", "jsonb"] -> :json
      t when t in ["real", "double precision", "numeric"] -> :float
      _other -> :unknown
    end
  end
end

defmodule Scry.Engine.Postgrex.Conn do
  @moduledoc """
  Wraps an already-started `postgrex` connection pool -- opened once via
  `open/1` and meant to be reused across many `Scry.Engine.Relational.
  Postgrex.execute/3` calls, unlike an ad-hoc adapter that opens (and
  closes) a fresh connection on every single call. Matches the
  connection/config struct every real adapter exposes (impl_spec.md §2).

  Unlike `Scry.Engine.Exqlite.Conn`'s single raw SQLite handle, `pool`
  here is a `postgrex`/`DBConnection` pool reference (a PID or a
  registered name) -- `postgrex` is pool-based from the start, so
  "opened once, reused across every call" is, if anything, a more
  natural fit for this connection model than for a single-writer SQLite
  file handle.

  `schema_cache` is an ETS table `open/1` creates alongside the pool --
  `Scry.Engine.Postgrex`'s own per-query `NOT NULL` schema
  check, and `Scry.Engine.Postgrex.Schema.describe_source/2`,
  both use it to avoid re-querying `information_schema.columns` on every
  single call. Unlike SQLite's cheap, global `PRAGMA schema_version`
  read, Postgres has no equally cheap, equally global "has this table's
  shape changed" signal -- `Schema`'s own moduledoc has the full
  reasoning for why this cache, once populated, stays valid until
  explicitly busted (`Schema.invalidate/2`) or the pool restarts, rather
  than being freshness-checked automatically the way exqlite's is. A
  `%Conn{}` built by hand (`%Conn{pool: pool}`, common in tests) has
  `schema_cache: nil` and simply skips caching -- always correct, just
  not optimized.

  `close/1` stops the underlying pool *and* deletes the schema cache
  explicitly when the caller is done with it -- nothing about this
  struct closes either on its own (no finalizer, no linked process); the
  caller owns its own connection lifecycle, same as any other database
  client library.
  """

  @type t :: %__MODULE__{pool: GenServer.server(), schema_cache: :ets.table() | nil}

  defstruct pool: nil, schema_cache: nil

  @doc """
  Starts a `postgrex` connection pool and wraps it. `opts` is passed
  straight through to `Postgrex.start_link/1` (`hostname`/`port`/
  `username`/`password`/`database`/`pool_size`/...).

  Confirmed directly, not assumed: unlike `Scry.Engine.Exqlite.Conn.
  open/2`'s real, synchronous file-open, `Postgrex.start_link/1`
  connects asynchronously -- this returns `{:ok, t()}` immediately even
  against bad credentials or an unreachable host, with the real
  connection attempt (and any failure) happening in the pool's own
  background process. There is nothing synchronous for `open/1` itself
  to fail on in that case; a bad connection only ever surfaces once a
  real query is attempted against the returned pool.
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts) do
    with {:ok, pool} <- Postgrex.start_link(opts) do
      schema_cache = :ets.new(:scry_postgrex_schema_cache, [:set, :public])
      {:ok, %__MODULE__{pool: pool, schema_cache: schema_cache}}
    end
  end

  @doc "Stops the wrapped pool and deletes its schema cache."
  @spec close(t()) :: :ok
  def close(%__MODULE__{pool: pool, schema_cache: schema_cache}) do
    if schema_cache, do: :ets.delete(schema_cache)
    GenServer.stop(pool)
  end
end

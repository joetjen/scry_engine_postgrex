defmodule Scry.Engine.Relational.Postgrex.TestConn do
  @moduledoc """
  Shared test connection helper -- reads env-var-overridable connection
  options (defaulting to this package's own `docker-compose.yml`
  service) and starts one real `postgrex` pool per test run. Every test
  file that needs a real connection calls `start_pool/0` once (typically
  in its own `setup_all`) and builds its own `%Conn{}` around the
  returned pool -- `schema_cache: nil` by default (the uncached path,
  matching `scry_engine_exqlite`'s own test convention of exercising the
  uncached path by default and opting into caching explicitly in a
  dedicated describe block).

  Each test creates its **own uniquely-named table**
  (`unique_table_name/1`) rather than relying on transaction-rollback
  sandboxing -- a real, shared Postgres server persists between test
  runs unlike SQLite's free `:memory:`/tmp-file databases, so this is
  what keeps `async: true` safe with no new abstraction.

  `drop_table/1` (for `on_exit` cleanup) deliberately opens its own
  short-lived connection rather than reusing a test's own pool --
  confirmed directly, not assumed: a pool from `start_pool/0` is linked
  to (and dies with) the test process that started it, but an `on_exit`
  callback runs in a *separate* process *after* the test process itself
  has already exited, so by the time it runs, that pool is already gone
  (a real `DBConnection.Holder.checkout` `:shutdown` exit, seen directly
  while writing this suite, not guessed at).

  Requires a real Postgres reachable at the configured connection
  details -- `docker compose up -d` (this package's own root
  `docker-compose.yml`) before running this suite; see README.md.
  """

  @doc "Starts (and returns) a real postgrex pool against the configured test database."
  @spec start_pool() :: GenServer.server()
  def start_pool do
    {:ok, pool} = Postgrex.start_link(connection_opts())
    pool
  end

  @doc "Connection options for the test database, overridable via PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE."
  @spec connection_opts() :: keyword()
  def connection_opts do
    [
      hostname: System.get_env("PGHOST", "localhost"),
      port: String.to_integer(System.get_env("PGPORT", "5432")),
      username: System.get_env("PGUSER", "scry"),
      password: System.get_env("PGPASSWORD", "scry"),
      database: System.get_env("PGDATABASE", "scry_engine_relational_postgrex_test")
    ]
  end

  @doc "A table name unique to this test run, prefixed by `base` -- avoids cross-test pollution under `async: true` with no sandboxing needed."
  @spec unique_table_name(String.t()) :: String.t()
  def unique_table_name(base), do: "#{base}_#{System.unique_integer([:positive])}"

  @doc "Drops `table`, via its own short-lived connection -- see this module's own moduledoc for why `on_exit` can't just reuse a test's own pool."
  @spec drop_table(String.t()) :: :ok
  def drop_table(table) do
    {:ok, pool} = Postgrex.start_link(connection_opts())
    Postgrex.query(pool, "DROP TABLE IF EXISTS #{table}", [])
    GenServer.stop(pool)
    :ok
  end
end

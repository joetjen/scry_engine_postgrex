defmodule Scry.Engine.Relational.Postgrex.ConnTest do
  @moduledoc """
  `Scry.Engine.Relational.Postgrex.Conn` -- confirms `open/1` starts a
  real `postgrex` pool and `close/1` actually stops it.
  """

  use ExUnit.Case, async: true

  alias Scry.Engine.Relational.Postgrex.{Conn, TestConn}

  test "open/1 starts and wraps a real postgrex pool" do
    assert {:ok, %Conn{pool: pool} = conn} = Conn.open(TestConn.connection_opts())
    assert Process.alive?(pool)
    Conn.close(conn)
  end

  test "open/1 also creates a schema cache, used to avoid a fresh information_schema query on every call" do
    assert {:ok, %Conn{schema_cache: schema_cache} = conn} = Conn.open(TestConn.connection_opts())
    assert :ets.info(schema_cache) != :undefined
    Conn.close(conn)
  end

  test "open/1 starts the pool even against bad credentials -- postgrex connects asynchronously" do
    # Confirmed directly, not assumed: unlike `Exqlite.Sqlite3.open/2`
    # (a real, synchronous file-open that fails immediately for a bad
    # path/mode), `Postgrex.start_link/1` always returns `{:ok, pid}`
    # right away, regardless of whether the credentials are actually
    # valid -- the real connection attempt happens in the background,
    # only failing (repeatedly, logged, with backoff) once the pool
    # process itself tries to connect. `Conn.open/1` has nothing
    # synchronous to pass through here; a bad credential only ever
    # surfaces once a real query is attempted against the pool.
    bad_opts =
      TestConn.connection_opts()
      |> Keyword.put(:password, "definitely-wrong")
      |> Keyword.put(:backoff_type, :stop)

    assert {:ok, %Conn{pool: pool} = conn} = Conn.open(bad_opts)
    assert Process.alive?(pool)
    Conn.close(conn)
  end

  test "close/1 stops the pool and its schema cache" do
    {:ok, %Conn{pool: pool, schema_cache: schema_cache} = conn} =
      Conn.open(TestConn.connection_opts())

    assert Conn.close(conn) == :ok
    refute Process.alive?(pool)
    assert :ets.info(schema_cache) == :undefined
  end

  test "a hand-built %Conn{pool: pool} (no schema_cache) still closes fine" do
    {:ok, %Conn{pool: pool}} = Conn.open(TestConn.connection_opts())
    assert Conn.close(%Conn{pool: pool}) == :ok
  end
end

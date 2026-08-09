defmodule Scry.Engine.Relational.Postgrex.SchemaTest do
  @moduledoc """
  `Scry.Engine.Relational.Postgrex.Schema` -- `information_schema.
  columns`-based introspection, the direct Postgres counterpart to
  `Scry.Engine.Exqlite.Schema`. `verify/3` is the extracted internals
  `Scry.Engine.Relational.Postgrex`'s own per-query `NOT NULL` gate
  relies on; `describe_source/2` is `Scry.Core.EngineBehaviour`'s
  optional callback.

  Requires a real Postgres reachable via `Scry.Engine.Relational.
  Postgrex.TestConn` -- `docker compose up -d` first (see README.md).
  """

  use ExUnit.Case, async: true

  alias Scry.Engine.Relational.Postgrex.{Conn, Schema, TestConn}

  setup do
    pool = TestConn.start_pool()
    table = TestConn.unique_table_name("users")

    Postgrex.query!(
      pool,
      """
      CREATE TABLE #{table} (
        id SERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        age INTEGER,
        balance DOUBLE PRECISION,
        active BOOLEAN,
        metadata JSONB,
        created_at TIMESTAMP
      )
      """,
      []
    )

    on_exit(fn -> TestConn.drop_table(table) end)

    {:ok, conn: %Conn{pool: pool}, pool: pool, table: table}
  end

  describe "describe_source/2" do
    test "describes every real column, nullability and scalar included", %{
      conn: conn,
      table: table
    } do
      assert {:ok, fields} = Schema.describe_source(conn, table)
      by_name = Map.new(fields, &{&1.name, &1})

      assert by_name["id"] == %{name: "id", nullable: false, scalar: :integer}
      assert by_name["name"] == %{name: "name", nullable: false, scalar: :string}
      assert by_name["age"] == %{name: "age", nullable: true, scalar: :integer}
      assert by_name["balance"] == %{name: "balance", nullable: true, scalar: :float}
      assert by_name["active"] == %{name: "active", nullable: true, scalar: :boolean}
      assert by_name["metadata"] == %{name: "metadata", nullable: true, scalar: :json}
      assert by_name["created_at"] == %{name: "created_at", nullable: true, scalar: :unknown}
    end

    test "a SERIAL primary key is genuinely, explicitly NOT NULL in information_schema -- no ROWID-alias carve-out needed",
         %{conn: conn, table: table} do
      assert {:ok, fields} = Schema.describe_source(conn, table)
      id_field = Enum.find(fields, &(&1.name == "id"))
      assert id_field.nullable == false
    end

    test "a table that doesn't exist is {:error, :not_found}", %{conn: conn} do
      assert {:error, :not_found} = Schema.describe_source(conn, "ghost_table_does_not_exist")
    end

    test "uses the same per-Conn ETS cache the schema gate uses, when one exists", %{
      pool: pool,
      table: table
    } do
      cache = :ets.new(:test_cache, [:set, :public])
      conn = %Conn{pool: pool, schema_cache: cache}

      assert {:ok, _fields} = Schema.describe_source(conn, table)
      assert [{^table, _rows}] = :ets.lookup(cache, table)
    end

    test "a %Conn{} with no schema_cache still works, just uncached", %{pool: pool, table: table} do
      conn = %Conn{pool: pool, schema_cache: nil}
      assert {:ok, fields} = Schema.describe_source(conn, table)
      assert length(fields) == 7
    end

    test "invalidate/2 busts a cached entry so the next call re-queries", %{
      pool: pool,
      table: table
    } do
      cache = :ets.new(:test_cache, [:set, :public])
      conn = %Conn{pool: pool, schema_cache: cache}

      assert {:ok, _fields} = Schema.describe_source(conn, table)
      assert [{^table, _rows}] = :ets.lookup(cache, table)

      assert :ok = Schema.invalidate(conn, table)
      assert :ets.lookup(cache, table) == []

      assert {:ok, _fields} = Schema.describe_source(conn, table)
      assert [{^table, _rows}] = :ets.lookup(cache, table)
    end

    test "a stale cached entry is NOT automatically refreshed after a real schema change -- documented, accepted limitation",
         %{pool: pool, table: table} do
      cache = :ets.new(:test_cache, [:set, :public])
      conn = %Conn{pool: pool, schema_cache: cache}

      assert {:ok, fields_before} = Schema.describe_source(conn, table)
      refute Enum.any?(fields_before, &(&1.name == "nickname"))

      Postgrex.query!(pool, "ALTER TABLE #{table} ADD COLUMN nickname TEXT", [])

      assert {:ok, fields_still_stale} = Schema.describe_source(conn, table)
      refute Enum.any?(fields_still_stale, &(&1.name == "nickname"))

      :ok = Schema.invalidate(conn, table)
      assert {:ok, fields_fresh} = Schema.describe_source(conn, table)
      assert Enum.any?(fields_fresh, &(&1.name == "nickname"))
    end
  end

  describe "verify/3 (the per-query NOT NULL gate)" do
    test "passes when every not_null_columns entry is schema-guaranteed", %{
      conn: conn,
      table: table
    } do
      assert :ok = Schema.verify(conn, table, ["id", "name"])
    end

    test "declines a nullable column claimed not-null", %{conn: conn, table: table} do
      assert {:error, {:unsupported, {:nullable_column, ["age"]}}} =
               Schema.verify(conn, table, ["age"])
    end

    test "an unknown table proceeds (:ok) rather than reporting a misleading nullable_column error",
         %{conn: conn} do
      assert :ok = Schema.verify(conn, "ghost_table_does_not_exist", ["anything"])
    end
  end
end

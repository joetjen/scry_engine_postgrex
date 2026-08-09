defmodule Scry.Engine.PostgrexTest do
  @moduledoc """
  `Scry.Engine.Postgrex` -- confirms `execute/3` compiles a
  plain `WHERE`/`ORDER BY`/`DISTINCT`/`LIMIT`/`OFFSET` query into one
  real SQL statement, that an unknown or unsafe (would-be SQL-injecting)
  source is a clear, tagged error rather than a crash or an executed
  statement, that a `WHERE`/`select` shape this module can't translate
  is a clean `{:error, {:unsupported, ...}}`, that a `WHERE` predicate
  against a nullable column correctly declines while the same predicate
  against a schema-`NOT NULL` column pushes down fine, that a native
  `DateTime`/`boolean` literal binds and compares correctly with no
  workaround needed (unlike the SQLite port), that the schema cache's
  own real, accepted limitation (no automatic freshness re-check) holds
  exactly as documented, and that a nested/correlated `SELECT` or a
  `WITH`-bound source is delegated whole to `Scry.Core.QueryOps.
  run_document/4` rather than attempted natively -- all composing
  correctly end to end through a real `Scry.Core.Executor.run/4` call.

  Requires a real Postgres reachable via `Scry.Engine.Relational.
  Postgrex.TestConn` -- `docker compose up -d` first (see README.md).
  """

  use ExUnit.Case, async: true

  alias Scry.Core.{Cursor, Executor, Query, Row}
  alias Scry.Engine.Postgrex, as: Engine
  alias Scry.Engine.Postgrex.{Conn, Schema, TestConn}

  setup do
    pool = TestConn.start_pool()
    table = TestConn.unique_table_name("users")

    Postgrex.query!(
      pool,
      """
      CREATE TABLE #{table} (
        id SERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        age INTEGER NOT NULL,
        status TEXT,
        active BOOLEAN NOT NULL
      )
      """,
      []
    )

    Postgrex.query!(
      pool,
      "INSERT INTO #{table} (name, age, status, active) VALUES ($1, $2, $3, $4), ($5, $6, $7, $8)",
      ["Alice", 30, "active", true, "Bob", 17, nil, false]
    )

    on_exit(fn -> TestConn.drop_table(table) end)

    {:ok, conn: %Conn{pool: pool}, pool: pool, table: table}
  end

  defp materialize({:ok, rows}), do: {:ok, rows |> Enum.to_list() |> Enum.map(&to_plain/1)}
  defp materialize(other), do: other

  defp to_plain(%Row{} = row), do: Row.to_map(row)
  defp to_plain(row), do: row

  describe "execute/3 -- plain queries" do
    test "rows genuinely come back as Scry.Core.Row values, not plain maps, for this direct pushdown path",
         %{conn: conn, table: table} do
      query = %Query{
        source: [table],
        wheres: [{:cmp, :eq, ["id"], 1}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} = Engine.execute(conn, query, %{})
      assert [%Row{} = row] = Enum.to_list(rows)
      assert Row.fetch!(row, "name") == "Alice"
      assert Row.to_map(row) == %{"name" => "Alice"}
    end

    test "no wheres at all returns every row", %{conn: conn, table: table} do
      query = %Query{source: [table], select: [{:field, ["name"]}, {:field, ["age"]}]}

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))

      assert Enum.sort_by(rows, & &1["age"]) == [
               %{"name" => "Bob", "age" => 17},
               %{"name" => "Alice", "age" => 30}
             ]
    end

    test "a bare field under an explicit alias (as Scry.Core.Query.from/2's map select: always produces) still pushes down",
         %{conn: conn, table: table} do
      query = %Query{source: [table], select: [{:computed, "n", {:field, ["name"]}}]}

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.sort(rows) == Enum.sort([%{"n" => "Alice"}, %{"n" => "Bob"}])
    end

    test "a WHERE on a schema-NOT-NULL column pushes down and narrows correctly", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        wheres: [{:cmp, :gt, ["age"], 18}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Alice"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "a boolean WHERE binds and pushes down directly -- no SQLite-style refusal", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        wheres: [{:cmp, :eq, ["active"], true}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Alice"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "a WHERE on a nullable column declines -- the real correctness concern this compiler exists for",
         %{conn: conn, table: table} do
      query = %Query{
        source: [table],
        wheres: [{:cmp, :eq, ["status"], "active"}],
        select: [{:field, ["name"]}]
      }

      assert Engine.execute(conn, query, %{}) ==
               {:error, {:unsupported, {:nullable_column, ["status"]}}}
    end

    test "the explicit field = nil null-check idiom works fine even on a nullable column", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        wheres: [{:cmp, :eq, ["status"], nil}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Bob"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "ORDER BY + LIMIT + OFFSET compiles and executes correctly", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        order_bys: [{["age"], :asc}],
        limit: 1,
        offset: 1,
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Alice"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "DISTINCT compiles and executes correctly", %{conn: conn, table: table} do
      query = %Query{source: [table], distinct: true, select: [{:field, ["age"]}]}

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.sort_by(rows, & &1["age"]) == [%{"age" => 17}, %{"age" => 30}]
    end

    test "a computed (non-bare-field) select item declines -- no cast/arithmetic translation this increment",
         %{conn: conn, table: table} do
      query = %Query{
        source: [table],
        select: [{:computed, "n", {:call, "string", [{:field, ["age"]}]}}]
      }

      assert {:error, {:unsupported, {:select, _}}} = Engine.execute(conn, query, %{})
    end

    test "an unknown source is a clear, tagged query_error, never a crash", %{conn: conn} do
      query = %Query{source: ["definitely_missing_table"], select: [{:field, ["id"]}]}
      assert {:error, {:query_error, _}} = Engine.execute(conn, query, %{})
    end

    test "a source that isn't a safe SQL identifier is rejected before ever touching SQL", %{
      conn: conn,
      table: table
    } do
      malicious = ["#{table}; DROP TABLE #{table};--"]
      query = %Query{source: malicious, select: []}

      assert Engine.execute(conn, query, %{}) ==
               {:error, {:unsupported, {:source, hd(malicious)}}}

      # The table must still be there -- confirms the rejection
      # happened before any SQL was ever built from the source.
      still_there = %Query{source: [table], select: [{:field, ["id"]}]}
      assert {:ok, [_ | _]} = materialize(Engine.execute(conn, still_there, %{}))
    end
  end

  describe "execute/3 -- a DateTime literal WHERE, bound and compared natively" do
    test "pushes down and narrows correctly -- no epoch-encoding workaround needed", %{
      pool: pool
    } do
      table = TestConn.unique_table_name("events")

      Postgrex.query!(
        pool,
        "CREATE TABLE #{table} (id SERIAL PRIMARY KEY, logged_at TIMESTAMPTZ NOT NULL)",
        []
      )

      on_exit(fn -> TestConn.drop_table(table) end)

      base = ~U[2026-01-01 00:00:00Z]

      Postgrex.query!(pool, "INSERT INTO #{table} (logged_at) VALUES ($1), ($2)", [
        base,
        DateTime.add(base, 300, :second)
      ])

      query = %Query{
        source: [table],
        wheres: [{:cmp, :ge, ["logged_at"], DateTime.add(base, 60, :second)}],
        order_bys: [{["logged_at"], :asc}],
        select: [{:field, ["id"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(%Conn{pool: pool}, query, %{}))
      assert length(rows) == 1
    end
  end

  describe "the schema cache -- once populated, valid until explicitly busted (a real, documented limitation)" do
    test "repeated queries against the same table reuse one cache entry, not a fresh information_schema query per call",
         %{pool: pool, table: table} do
      cache = :ets.new(:cache_reuse_test, [:set, :public])
      conn = %Conn{pool: pool, schema_cache: cache}

      query = %Query{
        source: [table],
        wheres: [{:cmp, :gt, ["age"], 0}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, _rows} = materialize(Engine.execute(conn, query, %{}))
      assert :ets.info(cache, :size) == 1

      assert {:ok, _rows} = materialize(Engine.execute(conn, query, %{}))
      # Still exactly one entry -- the second call reused it rather
      # than inserting a duplicate or bypassing the cache.
      assert :ets.info(cache, :size) == 1
    end

    test "unlike scry_engine_exqlite, a real schema change is NOT automatically detected -- requires explicit invalidate/2",
         %{pool: pool, table: table} do
      cache = :ets.new(:stale_cache_test, [:set, :public])
      conn = %Conn{pool: pool, schema_cache: cache}

      query = %Query{
        source: [table],
        wheres: [{:cmp, :eq, ["status"], "active"}],
        select: [{:field, ["name"]}]
      }

      # `status` starts nullable -- declines, and populates the cache.
      assert Engine.execute(conn, query, %{}) ==
               {:error, {:unsupported, {:nullable_column, ["status"]}}}

      # A real schema change -- Postgres genuinely can do this in place,
      # unlike SQLite's own rebuild idiom.
      Postgrex.query!(pool, "UPDATE #{table} SET status = 'active' WHERE status IS NULL", [])
      Postgrex.query!(pool, "ALTER TABLE #{table} ALTER COLUMN status SET NOT NULL", [])

      # Same conn, same schema_cache -- still declines, because nothing
      # re-checks freshness automatically (a real, accepted limitation,
      # not a bug -- see `Scry.Engine.Postgrex.Schema`'s own
      # moduledoc).
      assert Engine.execute(conn, query, %{}) ==
               {:error, {:unsupported, {:nullable_column, ["status"]}}}

      # Explicitly busting the cache picks up the real, current schema.
      :ok = Schema.invalidate(conn, table)
      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert length(rows) == 2
    end
  end

  describe "execute/3 -- delegated to Scry.Core.QueryOps.run_document/4" do
    test "a correlated nested SELECT is delegated and produces correct results", %{
      conn: conn,
      pool: pool,
      table: table
    } do
      orders_table = TestConn.unique_table_name("orders")

      Postgrex.query!(
        pool,
        "CREATE TABLE #{orders_table} (id SERIAL PRIMARY KEY, user_id INTEGER NOT NULL, total INTEGER NOT NULL)",
        []
      )

      on_exit(fn -> TestConn.drop_table(orders_table) end)

      [{alice_id, _}, {bob_id, _}] =
        Enum.sort_by(
          [{fetch_id(pool, table, "Alice"), "Alice"}, {fetch_id(pool, table, "Bob"), "Bob"}],
          &elem(&1, 1)
        )

      Postgrex.query!(
        pool,
        "INSERT INTO #{orders_table} (user_id, total) VALUES ($1, $2), ($3, $4), ($5, $6)",
        [alice_id, 50, alice_id, 75, bob_id, 20]
      )

      query = %Query{
        source: [table],
        order_bys: [{["id"], :asc}],
        select: [
          {:field, ["name"]},
          %Query{
            source: [orders_table],
            wheres: [{:cmp, :eq, ["user_id"], {:field, [table, "id"]}}],
            select: [{:field, ["total"]}]
          }
        ]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)

      assert Cursor.to_list(cursor) == [
               %{"name" => "Alice", orders_table => [%{"total" => 50}, %{"total" => 75}]},
               %{"name" => "Bob", orders_table => [%{"total" => 20}]}
             ]
    end

    test "a WITH-bound source is delegated and produces correct results", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: ["adults"],
        select: [{:field, ["name"]}],
        with_bindings: %{
          "adults" => %Query{
            source: [table],
            wheres: [{:cmp, :gt, ["age"], 18}],
            select: [{:field, ["name"]}]
          }
        }
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)
      assert Cursor.to_list(cursor) == [%{"name" => "Alice"}]
    end
  end

  describe "describe_source/2 (Scry.Core.EngineBehaviour's optional callback)" do
    test "delegates to Scry.Engine.Postgrex.Schema.describe_source/2", %{
      conn: conn,
      table: table
    } do
      assert {:ok, fields} = Engine.describe_source(conn, table)
      names = fields |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["active", "age", "id", "name", "status"]
    end

    test "an unknown source is {:error, :not_found}", %{conn: conn} do
      assert {:error, :not_found} = Engine.describe_source(conn, "definitely_missing_table")
    end
  end

  describe "end to end through Scry.Core.Executor.run/4" do
    test "a key-equality filter executes correctly through the SQL pushdown path", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        wheres: [{:cmp, :eq, ["id"], 1}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)
      assert cursor |> Cursor.to_list() |> Enum.map(&to_plain/1) == [%{"name" => "Alice"}]
    end

    test "GROUP BY + count executes correctly via native SQL pushdown", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        group_bys: [["age"]],
        select: [
          {:field, ["age"]},
          {:computed, "n", {:call, "count", [{:field, ["id"]}]}}
        ]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)

      assert cursor |> Cursor.to_list() |> Enum.map(&to_plain/1) |> Enum.sort_by(& &1["age"]) == [
               %{"age" => 17, "n" => 1},
               %{"age" => 30, "n" => 1}
             ]
    end
  end

  defp fetch_id(pool, table, name) do
    %Postgrex.Result{rows: [[id]]} =
      Postgrex.query!(pool, "SELECT id FROM #{table} WHERE name = $1", [name])

    id
  end
end

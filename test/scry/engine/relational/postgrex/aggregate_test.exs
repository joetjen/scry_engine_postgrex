defmodule Scry.Engine.Relational.Postgrex.AggregateTest do
  @moduledoc """
  `Scry.Engine.Relational.Postgrex`'s `GROUP BY`/aggregate pushdown --
  confirms a fully-eligible `GROUP BY`/aggregate query genuinely pushes
  down to native SQL and produces correct results (`sum`/`avg`/`count`/
  `min`/`max`/`count(distinct ...)`, a flat aggregate, a flat aggregate
  over zero matching rows correctly reporting `nil`, a `{:param,
  name}`-bound `WHERE`), that the `NOT NULL` gate correctly declines
  the *entire* query for a nullable aggregated or `WHERE`-filtered
  column (a real schema-level `information_schema.columns` check,
  against a real Postgres database, not mocked) -- with **no
  fallback**.

  **A real, deliberate improvement over the SQLite port, confirmed
  here, not just asserted**: `avg`/`sum` over an `integer` column stays
  genuinely *exact* through this adapter (a plain integer or a `Scry.
  Core.Rational`), never a lossy native float -- Postgres's own `AVG()`/
  `SUM()` over an integer argument returns `numeric` (arbitrary-
  precision decimal), decoded by `postgrex` as `Decimal.t()` and
  converted here. Unlike `scry_engine_exqlite`'s SQLite port, which has
  no choice but to relax exactness for `avg` (SQLite's own `AVG()` is
  always an inexact float), this adapter needs no such relaxation for
  an integer/numeric column.

  Requires a real Postgres reachable via `Scry.Engine.Relational.
  Postgrex.TestConn` -- `docker compose up -d` first (see README.md).
  """

  use ExUnit.Case, async: true

  alias Scry.Core.{Cursor, Executor, Query, Rational, Row}
  alias Scry.Engine.Relational.Postgrex, as: Engine
  alias Scry.Engine.Relational.Postgrex.{Conn, TestConn}

  setup do
    pool = TestConn.start_pool()
    table = TestConn.unique_table_name("orders")

    Postgrex.query!(
      pool,
      """
      CREATE TABLE #{table} (
        id SERIAL PRIMARY KEY,
        user_id INTEGER NOT NULL,
        amount INTEGER NOT NULL,
        status TEXT NOT NULL,
        discount INTEGER
      )
      """,
      []
    )

    insert_orders(pool, table, [
      {1, 10, "a", nil},
      {1, 20, "a", nil},
      {2, 5, "b", 1},
      {2, 7, "c", 2}
    ])

    on_exit(fn -> TestConn.drop_table(table) end)

    {:ok, conn: %Conn{pool: pool}, pool: pool, table: table}
  end

  defp insert_orders(pool, table, rows) do
    Enum.each(rows, fn {user_id, amount, status, discount} ->
      Postgrex.query!(
        pool,
        "INSERT INTO #{table} (user_id, amount, status, discount) VALUES ($1, $2, $3, $4)",
        [user_id, amount, status, discount]
      )
    end)
  end

  defp materialize({:ok, cursor}), do: {:ok, cursor |> Cursor.to_list() |> Enum.map(&to_plain/1)}
  defp materialize({:error, _} = err), do: err

  defp to_plain(%Row{} = row), do: Row.to_map(row)
  defp to_plain(row), do: row

  defp run(query, conn), do: query |> Executor.run(Engine, conn) |> materialize()

  describe "GROUP BY + aggregate pushdown, over NOT NULL columns" do
    test "rows genuinely come back as Scry.Core.Row values, not plain maps", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
        ]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)
      rows = Cursor.to_list(cursor)
      assert Enum.all?(rows, &match?(%Row{}, &1))

      assert Enum.map(rows, &Row.to_map/1) |> Enum.sort_by(& &1["user_id"]) == [
               %{"user_id" => 1, "total" => 30},
               %{"user_id" => 2, "total" => 12}
             ]
    end

    test "sum/count/min/max all push down and produce correct results", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}},
          {:computed, "n", {:call, "count", [{:field, ["amount"]}]}},
          {:computed, "lo", {:call, "min", [{:field, ["amount"]}]}},
          {:computed, "hi", {:call, "max", [{:field, ["amount"]}]}}
        ]
      }

      assert {:ok, rows} = run(query, conn)

      assert Enum.sort_by(rows, & &1["user_id"]) == [
               %{"user_id" => 1, "total" => 30, "n" => 2, "lo" => 10, "hi" => 20},
               %{"user_id" => 2, "total" => 12, "n" => 2, "lo" => 5, "hi" => 7}
             ]
    end

    test "a GROUP BY column under an explicit alias (as Scry.Core.Query.from/2's map select: always produces) still pushes down",
         %{conn: conn, table: table} do
      query = %Query{
        source: [table],
        group_bys: [["user_id"]],
        select: [
          {:computed, "uid", {:field, ["user_id"]}},
          {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
        ]
      }

      assert {:ok, rows} = run(query, conn)

      assert Enum.sort_by(rows, & &1["uid"]) == [
               %{"uid" => 1, "total" => 30},
               %{"uid" => 2, "total" => 12}
             ]
    end

    test "avg over an integer column pushes down and stays genuinely EXACT -- a real improvement over the SQLite port",
         %{conn: conn, table: table} do
      query = %Query{
        source: [table],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "avg_amount", {:call, "avg", [{:field, ["amount"]}]}}
        ]
      }

      assert {:ok, rows} = run(query, conn)

      # user 1: avg(10, 20) = 15, a whole number -- decodes as a plain
      # integer, not 15.0. user 2: avg(5, 7) = 6, likewise whole.
      assert Enum.sort_by(rows, & &1["user_id"]) == [
               %{"user_id" => 1, "avg_amount" => 15},
               %{"user_id" => 2, "avg_amount" => 6}
             ]

      refute Enum.any?(rows, &is_float(&1["avg_amount"]))
    end

    test "avg producing a genuinely fractional result decodes as an exact Scry.Core.Rational, never a lossy float",
         %{pool: pool, table: table} do
      # avg(10, 7) = 8.5 exactly -- 17/2, not representable as a plain
      # integer, so this is the case that actually proves the Decimal
      # -> Rational conversion handles a real fraction, not just the
      # whole-number case above.
      Postgrex.query!(pool, "DELETE FROM #{table}", [])
      insert_orders(pool, table, [{1, 10, "a", nil}, {1, 7, "a", nil}])

      query = %Query{
        source: [table],
        select: [{:computed, "avg_amount", {:call, "avg", [{:field, ["amount"]}]}}]
      }

      assert {:ok, [%{"avg_amount" => avg}]} = run(query, %Conn{pool: pool})
      assert avg == Rational.new(17, 2)
    end

    test "count(distinct status) pushes down correctly", %{conn: conn, table: table} do
      query = %Query{
        source: [table],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "distinct_statuses", {:call, "count", [{:distinct, {:field, ["status"]}}]}}
        ]
      }

      assert {:ok, rows} = run(query, conn)

      assert Enum.sort_by(rows, & &1["user_id"]) == [
               %{"user_id" => 1, "distinct_statuses" => 1},
               %{"user_id" => 2, "distinct_statuses" => 2}
             ]
    end

    test "a flat (no GROUP BY) aggregate over every row", %{conn: conn, table: table} do
      query = %Query{
        source: [table],
        select: [{:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}]
      }

      assert {:ok, [%{"total" => 42}]} = run(query, conn)
    end

    test "a flat aggregate over zero matching rows reports nil, not a crash", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        wheres: [{:cmp, :eq, ["status"], "zzz"}],
        select: [{:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}]
      }

      assert {:ok, [%{"total" => nil}]} = run(query, conn)
    end

    test "a {:param, name}-bound WHERE resolves and pushes down", %{conn: conn, table: table} do
      query = %Query{
        source: [table],
        wheres: [{:cmp, :eq, ["user_id"], {:param, "uid"}}],
        select: [{:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}]
      }

      assert {:ok, [%{"total" => 30}]} =
               query |> Executor.run(Engine, conn, %{"uid" => 1}) |> materialize()
    end

    test "count(id) -- a SERIAL primary key -- pushes down; genuinely, explicitly NOT NULL, no carve-out needed",
         %{conn: conn, table: table} do
      query = %Query{
        source: [table],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "n", {:call, "count", [{:field, ["id"]}]}}
        ]
      }

      assert {:ok, result} = run(query, conn)

      assert Enum.sort_by(result, & &1["user_id"]) == [
               %{"user_id" => 1, "n" => 2},
               %{"user_id" => 2, "n" => 2}
             ]
    end
  end

  describe "no fallback exists any more -- a query the compiler declines is a clean error, not a slower correct answer" do
    test "an untranslatable (:match) WHERE predicate declines the whole query -- unlike :or/:and/:not, which now translate",
         %{pool: pool, table: table} do
      query = %Query{
        source: [table],
        wheres: [{:cmp, :match, ["status"], "^a"}],
        group_bys: [["status"]],
        select: [
          {:field, ["status"]},
          {:computed, "n", {:call, "count", [{:field, ["id"]}]}}
        ]
      }

      assert {:error, {:unsupported, _}} = run(query, %Conn{pool: pool})
    end

    test "aggregating over a nullable column declines the whole query", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        select: [{:computed, "total_discount", {:call, "sum", [{:field, ["discount"]}]}}]
      }

      assert run(query, conn) == {:error, {:unsupported, {:nullable_column, ["discount"]}}}
    end

    test "grouping on a NOT NULL column but aggregating a nullable one still declines", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "max_discount", {:call, "max", [{:field, ["discount"]}]}}
        ]
      }

      assert run(query, conn) == {:error, {:unsupported, {:nullable_column, ["discount"]}}}
    end

    test "filtering by a nullable column (not the null-check idiom) declines the whole query", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        wheres: [{:cmp, :not_eq, ["discount"], 0}],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "total_discount", {:call, "sum", [{:field, ["discount"]}]}}
        ]
      }

      assert run(query, conn) == {:error, {:unsupported, {:nullable_column, ["discount"]}}}
    end

    test "a real HAVING clause declines the whole query -- not attempted this increment", %{
      conn: conn,
      table: table
    } do
      query = %Query{
        source: [table],
        group_bys: [["user_id"]],
        havings: [{:cmp, :gt, {:call, "sum", [{:field, ["amount"]}]}, 15}],
        select: [
          {:field, ["user_id"]},
          {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
        ]
      }

      assert {:error, {:unsupported, {:construct, :having}}} = run(query, conn)
    end

    test "ROLLUP/CUBE decline the whole query -- not attempted this increment", %{
      conn: conn,
      table: table
    } do
      for group_mode <- [:rollup, :cube] do
        query = %Query{
          source: [table],
          group_bys: [["user_id"]],
          group_mode: group_mode,
          select: [
            {:field, ["user_id"]},
            {:computed, "total", {:call, "sum", [{:field, ["amount"]}]}}
          ]
        }

        assert {:error, {:unsupported, {:construct, ^group_mode}}} = run(query, conn)
      end
    end
  end

  describe "end to end through Scry.Core.Executor.run/4" do
    test "an unknown source is still a clear error, not a crash", %{pool: pool} do
      query = %Query{
        source: ["definitely_missing_table"],
        group_bys: [["user_id"]],
        select: [
          {:field, ["user_id"]},
          {:computed, "n", {:call, "count", [{:field, ["id"]}]}}
        ]
      }

      assert {:error, {:query_error, _}} = run(query, %Conn{pool: pool})
    end
  end
end

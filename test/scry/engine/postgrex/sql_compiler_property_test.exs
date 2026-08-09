defmodule Scry.Engine.Postgrex.SqlCompilerPropertyTest do
  @moduledoc """
  `Scry.Engine.Postgrex`'s plain `WHERE` pushdown -- proves,
  across randomly generated predicates and rows (all `NOT NULL`
  columns, so every generated predicate is pushdown-eligible and the
  property isolates translation correctness specifically, not the
  separate, already-covered `NOT NULL`-decline behavior), that
  `execute/3`'s compiled-SQL result is always identical to running
  `Scry.Core.QueryOps.run_flat/3` directly over the same rows -- the
  direct replacement for the automatic re-verification the old, lenient
  `fetch/3` contract used to provide for free, now this engine's own
  responsibility to prove. `execute/3`'s own rows come back as `Scry.
  Core.Row.t()` values for this direct pushdown path; normalized via
  `Row.to_map/1` before comparing against `run_flat/3`'s own plain-map
  output.

  Requires a real Postgres reachable via `Scry.Engine.Relational.
  Postgrex.TestConn` -- `docker compose up -d` first (see README.md).
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Scry.Core.{Query, QueryOps, Row}
  alias Scry.Engine.Postgrex, as: Engine
  alias Scry.Engine.Postgrex.{Conn, TestConn}

  setup do
    pool = TestConn.start_pool()
    table = TestConn.unique_table_name("items")

    Postgrex.query!(
      pool,
      "CREATE TABLE #{table} (id SERIAL PRIMARY KEY, a INTEGER NOT NULL, b TEXT NOT NULL)",
      []
    )

    on_exit(fn -> TestConn.drop_table(table) end)
    {:ok, conn: %Conn{pool: pool}, pool: pool, table: table}
  end

  defp comparison_generator do
    gen all(
          field <- member_of(["a", "b"]),
          op <- member_of([:eq, :not_eq, :lt, :gt, :le, :ge]),
          value <- one_of([integer(-5..5), string(:alphanumeric, max_length: 3)])
        ) do
      {:cmp, op, [field], value}
    end
  end

  defp predicate_generator(depth \\ 0)
  defp predicate_generator(depth) when depth >= 2, do: comparison_generator()

  defp predicate_generator(depth) do
    one_of([
      comparison_generator(),
      gen all(
            l <- predicate_generator(depth + 1),
            r <- predicate_generator(depth + 1),
            combinator <- member_of([:and, :or])
          ) do
        {combinator, l, r}
      end
    ])
  end

  defp insert_rows(pool, table, rows) do
    Enum.each(rows, fn row ->
      Postgrex.query!(pool, "INSERT INTO #{table} (a, b) VALUES ($1, $2)", [
        row["a"],
        row["b"]
      ])
    end)
  end

  defp row_generator do
    gen all(a <- integer(-5..5), b <- string(:alphanumeric, max_length: 3)) do
      %{"a" => a, "b" => b}
    end
  end

  property "execute/3's compiled SQL result always matches QueryOps.run_flat/3 over the same rows",
           %{conn: conn, pool: pool, table: table} do
    check all(
            rows <- list_of(row_generator(), max_length: 6),
            predicate <- predicate_generator(),
            max_runs: 100
          ) do
      Postgrex.query!(pool, "DELETE FROM #{table}", [])
      insert_rows(pool, table, rows)

      query = %Query{
        source: [table],
        wheres: [predicate],
        order_bys: [{["id"], :asc}],
        select: [{:field, ["a"]}, {:field, ["b"]}]
      }

      via_engine =
        case Engine.execute(conn, query, %{}) do
          {:ok, sql_rows} ->
            {:ok, sql_rows |> Enum.to_list() |> Enum.map(&Row.to_map/1)}

          {:error, {:unsupported, _}} ->
            :declined

          # A genuinely random literal (the generator mixes integers and
          # strings against both an INTEGER and a TEXT column) can
          # compare a mismatched-type value against a strictly-typed
          # Postgres column -- unlike SQLite's own weak typing, this
          # doesn't produce a silently wrong answer, it either fails the
          # bound parameter's own client-side type encoding
          # (`DBConnection.EncodeError`) or, for an ordering comparison
          # specifically (`WhereTranslator`'s own `COLLATE "C"` fix
          # forcing byte-wise string comparison), a Postgres-side
          # prepare error rejecting `COLLATE` against a non-collatable
          # column type (`Postgrex.Error`, pg_code `42804`) -- both
          # confirmed directly, not assumed, by real failures here while
          # building this suite, and both a clean `{:query_error, _}`
          # rather than a crash. Legitimate declines, same as
          # `:unsupported` -- narrowly matched on the *specific* known
          # causes, not every possible `:query_error`, so an unrelated
          # real bug still fails loudly.
          {:error, {:query_error, %DBConnection.EncodeError{}}} ->
            :declined

          {:error, {:query_error, %Postgrex.Error{postgres: %{code: :datatype_mismatch}}}} ->
            :declined
        end

      via_toolkit =
        rows
        |> Enum.with_index(1)
        |> Enum.map(fn {row, id} -> Map.put(row, "id", id) end)
        |> QueryOps.run_flat(query, %{})
        |> then(fn {:ok, toolkit_rows} -> {:ok, Enum.to_list(toolkit_rows)} end)

      case via_engine do
        :declined -> :ok
        {:ok, engine_rows} -> assert Enum.sort(engine_rows) == Enum.sort(elem(via_toolkit, 1))
      end
    end
  end
end

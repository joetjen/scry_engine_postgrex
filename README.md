# scry_engine_postgrex

A real [`Scry.Core.EngineBehaviour`](https://github.com/joetjen/scry_core)
implementation over [PostgreSQL](https://www.postgresql.org/) via
[`postgrex`](https://github.com/elixir-ecto/postgrex). A single
authoritative `execute/3` compiles the *entire* flat query — `WHERE`/
`GROUP BY`/aggregates/`ORDER BY`/`DISTINCT`/`LIMIT`/`OFFSET`/projection
— into one native SQL statement, all or nothing: either the whole query
is genuinely correct as native SQL, or `execute/3` declines it with a
clean `{:error, {:unsupported, detail}}` and no attempt is made. There
is no downstream fallback or re-verification anywhere in this pipeline
— an engine that accepts a query fully owns its correctness.

The direct Postgres counterpart to
[`scry_engine_exqlite`](https://github.com/joetjen/scry_engine_exqlite)
(SQLite), ported deliberately from that package — see `CHANGELOG.md`
for exactly what's generic between the two versus what needed real
redesign for Postgres's own strict typing, connection pooling, and
`information_schema`-based introspection.

Source: <https://github.com/joetjen/scry_engine_postgrex>. The behaviour
this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
{:ok, conn} = Scry.Engine.Postgrex.Conn.open(
  hostname: "localhost",
  username: "postgres",
  password: "postgres",
  database: "myapp"
)

{:ok, query} = Scry.Core.parse(~s(SELECT users WHERE id = 1 { name }))
{:ok, cursor} = Scry.Core.Executor.run(query, Scry.Engine.Postgrex, conn)
rows = Scry.Core.Cursor.to_list(cursor)
# rows == [%{"name" => "Alice"}]

Scry.Engine.Postgrex.Conn.close(conn)
```

`Conn.open/1` starts a real `postgrex` connection pool and is meant to
be called once, reused across many `execute/3` calls. Creating tables,
indexes, and schema is entirely the caller's own job; this package is
schema-agnostic and issues nothing but `SELECT`/`information_schema`
queries.

### What gets pushed down

`Scry.Engine.Postgrex.SqlCompiler` translates a flat query
into SQL only when it can do so *completely* — every `select` item is a
bare field (or, for a `GROUP BY` query, one of `sum`/`avg`/`count`/
`min`/`max`/`count(distinct ...)` over a bare field), `wheres`
translates fully (recursive `:cmp`/`:in`/`:and`/`:or`/`:not`, `Scry.Engine.Postgrex.WhereTranslator`), and there is no `HAVING`/
`ROLLUP`/`CUBE`/window function/nested `SELECT`/`WITH`-bound source
anywhere in the query. Anything that doesn't fully qualify is a clean
`{:error, {:unsupported, detail}}` — never a partial pushdown silently
finished off in Elixir.

A nested/correlated `SELECT` body item, or a `WITH`-bound source, is
delegated whole to `Scry.Core.QueryOps.run_document/4` instead —
recursing back into this same module's `execute/3` for each flat leaf
it resolves, so native pushdown still applies to those leaves.

### The one schema-level correctness check that still applies

SQL's own `WHERE`/aggregate semantics silently skip/exclude `NULL`
values with no way to raise — Scry's own language spec requires a hard
null-safety error instead, and this is just as true of Postgres as any
other SQL engine. Every column compared against a non-`nil` literal in
`wheres`, and every aggregated column, must be schema-level `NOT NULL`
(`information_schema.columns`) or the whole query is declined with
`{:error, {:unsupported, {:nullable_column, columns}}}`.

Unlike `scry_engine_exqlite`, there is **no separate type-affinity
check** — Postgres's own columns are strictly, disambiguated typed, so
there's no SQLite-style "a column's declared type is only advisory"
ambiguity to guard against. A genuinely mismatched comparison (a string
literal against an `integer` column) doesn't produce a silently wrong
answer either way; Postgres's own strict typing rejects it outright, and
`execute/3` reports that as an ordinary `{:error, {:query_error, _}}}`.

An ordering comparison (`<`/`>`/`<=`/`>=`) against a string value
forces `COLLATE "C"` (byte-wise comparison) — found directly, not
assumed: Postgres's *default* collation is locale-aware, not byte-order
(`"a" < "A"` is true under a typical default collation, false under
Erlang's own raw binary comparison), which could otherwise silently
disagree with `Scry.Core.QueryOps.eval_predicate/4`'s own term-order
semantics.

`avg`/`sum` over an `integer`/`bigint`/`numeric` column stay genuinely
**exact** through this adapter (a plain integer or a real `Scry.Core.
Rational`), not a lossy float — a real improvement over the SQLite
port, which has no choice but to relax exactness for `avg` (SQLite's
own `AVG()` is always an inexact float). A column declared `real`/
`double precision` still decodes as a native `float()` either way.

### Deliberately eager, not lazy, this version

Every query this adapter executes fully materializes its own result
rows before `execute/3` returns — genuine server-side-cursor streaming
(`Postgrex.stream/4`) needs a connection checked out and a transaction
held open across `execute/3`'s own return boundary, real, separate
machinery this version doesn't build yet. A well-motivated, natural
follow-on, not an oversight.

## Installation

```elixir
def deps do
  [
    {:scry_engine_postgrex, "~> 0.1"}
  ]
end
```

## Running the test suite

This package's own tests run against a real Postgres:

```sh
docker compose up -d
mix test
```

Connection details default to the `docker-compose.yml` service
(`localhost:5432`, user/password `scry`, database
`scry_engine_postgrex_test`) — override via `PGHOST`/
`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE` to point at a different
Postgres instead.

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_engine_postgrex>.

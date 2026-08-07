# scry_test_engine_core

A static, in-memory implementation of
[`scry_core`](https://github.com/joetjen/scry_core)'s
`ScryCore.EngineBehaviour` — for testing the composition/execution
pipeline (grammar → `ScryCore.Actions` → `%ScryCore.Query{}` →
`ScryCore.Executor`) end to end, without any real external data
source. Not for production use.

Named `scry_test_engine_core`, not `scry_engine_..._<driver>`, to keep
this class of package visually distinct from a real adapter at a
glance — the naming convention is `scry_test_engine_<kind>`; this one
is `core`'s own, since `scry_core` itself needs one before any real
kind library does. A future kind library (`scry_time_series`, ...)
gets its own `scry_test_engine_time_series` alongside it, once it
exists.

Source: <https://github.com/joetjen/scry_test_engine_core>. Specs live
in the separate [`scry`](https://github.com/joetjen/scry) repository;
the behaviour this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
conn =
  ScryTestEngineCore.Conn.new(%{
    ["users"] => [%{"name" => "Alice", "age" => 30}]
  })

{:ok, query} = ScryCore.parse(~s(SELECT users WHERE age > 18 { name }))
{:ok, cursor} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)
rows = ScryCore.Cursor.to_list(cursor)
# rows == [%{"name" => "Alice"}]
```

`ScryCore.Executor.run/3,4` returns a lazy `ScryCore.Cursor.t()`, not a
materialized list -- see `scry_core`'s own `ScryCore.Cursor` moduledoc
for the full pull-based API (`next/1`, `take/2`, `skip/1,2`, `close/1`).

### Prefilled seed data

`Conn.seed/0` gives you a realistic, multi-table dataset --
`users`/`products`/`orders`/`order_items`, related by real foreign-key-
shaped fields (`orders.user_id`, `order_items.order_id`/`product_id`)
-- instead of an empty connection, for exploring or testing against
something with real relationships to correlate across without hand-
authoring your own fixture rows first. `ScryTestEngineCore.Seed`'s own
moduledoc documents the exact shape of every table.

```elixir
conn = ScryTestEngineCore.Conn.seed()

{:ok, query} =
  ScryCore.parse(~s"""
  SELECT users { name, SELECT orders WHERE user_id = users.id AND status = "shipped" { id } }
  """)

{:ok, cursor} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)
rows = ScryCore.Cursor.to_list(cursor)
# rows == [%{"name" => "Alice", "orders" => [%{"id" => 1}]}, ...]
```

### `mix scry.query` -- try a query from the command line

Runs a query against `Conn.seed/0`'s own dataset and prints the
resulting rows, without writing any Elixir code first:

```console
$ mix scry.query 'SELECT users WHERE status = "active" { name }'
$ mix scry.query --file path/to/query.scry
```

`mix help scry.query` has the full usage.

### `mix scry.iex` -- an interactive, `iex`-like query prompt

```console
$ mix scry.iex
scry> SELECT users
...>   WHERE age > 18
...>   { name }
[%{"name" => "Alice"}, ...]
scry>
```

A query only runs once it parses -- pressing Enter mid-query keeps the
prompt open (`...>`) for the next line, rather than erroring
immediately. Ctrl+D exits.

For Up/Down arrow-key history (recalling and re-running a previous
query), run it as `iex -S mix scry.iex` instead -- plain `mix scry.iex`
prints a reminder of this at startup. `mix help scry.iex` has the full
usage, including why (OTP's own interactive-shell line editing, not
something this task implements itself).

### `mix scry.bench` -- measure `ScryCore.Executor`'s real memory behavior

Generates a real SQLite database and reports the actual process-memory
delta `ScryCore.Executor.run/4` incurs for a point lookup, a flat
aggregate over the whole table, and both a low- and a high-cardinality
`GROUP BY` -- the same measurement that originally motivated bounding
`Executor`'s own memory to what a query actually needs, kept here as a
repeatable regression tool rather than a one-off scratch script:

```console
$ mix scry.bench
$ mix scry.bench --users 1000000
```

`mix help scry.bench` has the full usage, including how to read the
two numbers each measurement reports (an *immediate* delta, and a
*settled* delta after an explicit GC -- the one that actually answers
"did this retain the whole source in memory").

## Installation

```elixir
def deps do
  [
    {:scry_test_engine_core, "~> 0.1.0", only: :test}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_test_engine_core>.
- Latest `main` is built and deployed automatically by
  [`.github/workflows/docs.yml`](.github/workflows/docs.yml) to
  [GitHub Pages](https://joetjen.github.io/scry_test_engine_core/) on every push to `main`.

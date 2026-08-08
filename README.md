# scry_test_core

Shared test/benchmark fixtures for
[`scry_core`](https://github.com/joetjen/scry_core): one seed dataset
(`Scry.Test.Core.Seed`), servable through three real `Scry.Core.
EngineBehaviour` backends via `Scry.Test.Core.Conn`:

- `Conn.in_memory/1` → [`scry_engine_inmemory`](https://github.com/joetjen/scry_engine_inmemory)'s `Scry.Engine.InMemory` (no pushdown at all)
- `Conn.ets/1` → [`scry_engine_ets`](https://github.com/joetjen/scry_engine_ets)'s `Scry.Engine.ETS` (real O(1) key-lookup pushdown)
- `Conn.sqlite/1` → [`scry_engine_exqlite`](https://github.com/joetjen/scry_engine_exqlite)'s `Scry.Engine.Exqlite` (real SQL `WHERE`-clause pushdown)

Plus `mix scry.query`/`mix scry.iex`/`mix scry.bench` for exercising
them. Not for production use.

Named `scry_test_core`, not `scry_engine_..._<driver>`, to keep this
class of package visually distinct from a real adapter at a glance --
the naming convention is `scry_test_<kind>`; this one is `core`'s own,
since `scry_core` itself needs one before any real kind library does.
A future kind library (`scry_time_series`, ...) gets its own
`scry_test_time_series` alongside it.

Source: <https://github.com/joetjen/scry_test_core>. Specs live in the
separate [`scry`](https://github.com/joetjen/scry) repository; the
behaviour every backend implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
{engine, conn} =
  Scry.Test.Core.Conn.in_memory(%{
    ["users"] => [%{"name" => "Alice", "age" => 30}]
  })

{:ok, query} = Scry.Core.parse(~s(SELECT users WHERE age > 18 { name }))
{:ok, cursor} = Scry.Core.Executor.run(query, engine, conn)
rows = Scry.Core.Cursor.to_list(cursor)
# rows == [%{"name" => "Alice"}]
```

Swap `in_memory/1` for `ets/1` or `sqlite/1` above to run the exact
same query against a different backend -- no other code changes.
`Scry.Core.Executor.run/3,4` returns a lazy `Scry.Core.Cursor.t()`, not
a materialized list -- see `scry_core`'s own `Scry.Core.Cursor`
moduledoc for the full pull-based API (`next/1`, `take/2`, `skip/1,2`,
`close/1`).

### Prefilled seed data

Every `Conn` constructor defaults to `Scry.Test.Core.Seed`'s own
realistic, multi-table dataset -- `users`/`products`/`orders`/
`order_items`, related by real foreign-key-shaped fields
(`orders.user_id`, `order_items.order_id`/`product_id`) -- instead of
an empty connection, for exploring or testing against something with
real relationships to correlate across without hand-authoring your own
fixture rows first. `Scry.Test.Core.Seed`'s own moduledoc documents the
exact shape of every table; the same dataset backs all three engines,
so a query run against each is directly comparable (see
`test/scry/test/core/parity_test.exs`'s own genuine 3-way parity
tests).

```elixir
{engine, conn} = Scry.Test.Core.Conn.in_memory()

{:ok, query} =
  Scry.Core.parse(~s"""
  SELECT users { name, SELECT orders WHERE user_id = users.id AND status = "shipped" { id } }
  """)

{:ok, cursor} = Scry.Core.Executor.run(query, engine, conn)
rows = Scry.Core.Cursor.to_list(cursor)
# rows == [%{"name" => "Alice", "orders" => [%{"id" => 1}]}, ...]
```

### `mix scry.query` -- try a query from the command line

Runs a query against the picked backend's own prefilled seed dataset
and prints the resulting rows, without writing any Elixir code first:

```console
$ mix scry.query 'SELECT users WHERE status = "active" { name }'
$ mix scry.query --file path/to/query.scry
$ mix scry.query --backend ets 'SELECT users WHERE id = 1 { name }'
```

`--backend` picks `in_memory` (the default), `ets`, or `sqlite` --
same seed data either way, only *how* the answer is produced changes.
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
immediately. Ctrl+D exits. `--backend` works the same way it does for
`mix scry.query`, for the whole session.

For Up/Down arrow-key history (recalling and re-running a previous
query), run it as `iex -S mix scry.iex` instead -- plain `mix scry.iex`
prints a reminder of this at startup. `mix help scry.iex` has the full
usage, including why (OTP's own interactive-shell line editing, not
something this task implements itself).

### `mix scry.bench` -- benchmark `Scry.Core.Executor`'s real speed and memory

Generates a real SQLite database and runs a point lookup, a flat
aggregate over the whole table, and both a low- and a high-cardinality
`GROUP BY` three ways side by side: `raw sql` (the equivalent query
issued directly against the connection via `Exqlite.Sqlite3`,
bypassing Scry entirely -- the baseline), `sqlite` (the same query as
Scry query text, through `Scry.Core.Executor.run/4` and `Scry.Engine.
Exqlite`, real `fetch/3` pushdown included -- answers "what does going
through Scry actually cost"), and, with `--compare-ets`, `ets` (the
same query again against a comparably-sized `Scry.Engine.ETS`
dataset). For each query/backend: rows returned, duration (avg/min/
median/max/stddev across several timed iterations, plus total), and
memory (an *immediate* delta and a *settled* delta after an explicit
GC -- the one that actually answers "did this retain the whole source
in memory"). The memory side of this is the same measurement that
originally motivated bounding `Executor`'s own memory to what a query
actually needs -- kept here as a repeatable benchmark/regression tool
rather than a one-off scratch script:

```console
$ mix scry.bench
$ mix scry.bench --users 1000000
$ mix scry.bench --users 1000000 --iterations 10
$ mix scry.bench --compare-ets
$ mix scry.bench --yes
```

At the default scale this can take several minutes and uses real
CPU/memory/disk, so the task asks for confirmation before doing any of
that work; `--yes` (or `-y`) skips the prompt for scripted use. Once
confirmed, it never goes silent: database generation prints its own
progress in place as rows are written, and every benchmarked query
prints a line as each warmup/timed run starts and finishes, with a
small ASCII spinner (`| / - \`) animating in place while that
individual run/memory-measurement/index-build is still in flight -- so
a slow run and a hung one are never impossible to tell apart. Results
print as
a boxed summary table, followed by a "Scry overhead" table converting
the raw `raw sql` vs. `sqlite` durations into a plain "N.NNx" reading
per query -- and, with `--compare-ets`, a second comparison table for
`sqlite` vs. `ets`.

`--compare-ets` additionally generates a comparably-sized `Scry.Engine.
ETS` dataset and runs every query against it too -- off by default (it
roughly doubles generation time and peak memory, and the concrete
problem this task exists to catch -- a point lookup degrading into a
full-table scan -- is already fully visible from the `raw sql`/`sqlite`
numbers alone). `mix help scry.bench` has the full usage, including
exactly what each reported number means and why `Scry.Test.Core.Conn.
in_memory/1` is deliberately never part of this comparison at
benchmark scale.

## Installation

```elixir
def deps do
  [
    {:scry_test_core, "~> 0.1.0", only: :test}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_test_core>.
- Latest `main` is built and deployed automatically by
  [`.github/workflows/docs.yml`](.github/workflows/docs.yml) to
  [GitHub Pages](https://joetjen.github.io/scry_test_core/) on every push to `main`.

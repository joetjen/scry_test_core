# scry_test_core

Shared test/benchmark fixtures for
[`scry_core`](https://github.com/joetjen/scry_core): one seed dataset
(`Scry.Test.Core.Seed`), servable through five real `Scry.Core.
EngineBehaviour` backends via `Scry.Test.Core.Conn`:

- `Conn.in_memory/1` → [`scry_engine_inmemory`](https://github.com/joetjen/scry_engine_inmemory)'s `Scry.Engine.InMemory` (no pushdown at all)
- `Conn.ets/1` → [`scry_engine_ets`](https://github.com/joetjen/scry_engine_ets)'s `Scry.Engine.ETS` (real O(1) key-lookup pushdown)
- `Conn.sqlite/1` → [`scry_engine_exqlite`](https://github.com/joetjen/scry_engine_exqlite)'s `Scry.Engine.Exqlite` (real SQL `WHERE`-clause pushdown)
- `Conn.postgres/1` → [`scry_engine_postgrex`](https://github.com/joetjen/scry_engine_postgrex)'s `Scry.Engine.Postgrex` (real SQL pushdown against a real, external Postgres -- needs `docker compose up -d` first; see below)
- `Conn.timescaledb/1` → the exact same `Scry.Engine.Postgrex`, unmodified, against a real, external TimescaleDB instead -- empirical proof that a dedicated `scry_engine_timescaledb` adapter has nothing unique to do today (see below)

Plus `scry_core`'s own `mix scry.query`/`mix scry.iex` (configured
here to use the constructors above) and this package's own `mix
scry.bench`, for exercising them. Not for production use.

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

Swap `in_memory/1` for `ets/1`, `sqlite/1`, or `postgres/1` above to run
the exact same query against a different backend -- no other code
changes (`postgres/1` additionally needs a real Postgres reachable,
see below).
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
exact shape of every table; the same dataset backs every engine,
so a query run against each is directly comparable (see
`test/scry/test/core/parity_test.exs`'s own genuine 3-way parity tests
for `in_memory`/`ets`/`sqlite`, `postgres_parity_test.exs` for
`postgres/1`'s own, and `timescaledb_parity_test.exs` for
`timescaledb/1`'s own, each kept separate -- see those files' own
moduledocs for why).

### `postgres/1`/`timescaledb/1` need a real, external Postgres/TimescaleDB

Unlike the other three (freely, automatically isolated per call),
`postgres/1`/`timescaledb/1` are each backed by a real, persistent,
external service -- `docker compose up -d` (this package's own root
`docker-compose.yml`, `localhost:5433`/`localhost:5434` by default)
before using either. `Conn.postgres/1`'s own moduledoc has the full
reasoning for the one real way both differ from the other three
(idempotent, not concurrency-safe with itself). Their own tests are
tagged `:postgres`/`:timescaledb` and excluded from the default
`mix test`/`mix precommit` for exactly this reason -- run
`mix test.postgres`/`mix test.timescaledb` (with Docker up) to include
them.

`timescaledb/1` runs through `Scry.Engine.Postgrex` -- the exact same
module `postgres/1` uses, entirely unmodified -- against a real
TimescaleDB container instead of plain Postgres. This isn't a second
adapter to maintain: it's the empirical answer to a question
`impl_spec.md`'s own roadmap left open, that a dedicated
`scry_engine_timescaledb` package would validate the `scry_reltime`
composite (relational + time-series) architecture. TimescaleDB speaks
the plain Postgres wire protocol, and the language has no
time-bucketing/hypertable construct yet to compile specially, so there
is nothing for a dedicated adapter to do differently today --
`Scry.TimeSeries.Executor.run/5` already lowers `LAST` into an ordinary
`WHERE` predicate before any engine ever sees it, recursively,
including inside a nested/correlated `SELECT` (Scry's own
`JOIN`-equivalent), so the composite's real value already exists with
zero new code against any plain `Scry.Core.EngineBehaviour` engine.
`timescaledb/1` proves that claim against a real container rather than
just asserting it.

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

### `mix scry.query`/`mix scry.iex` -- try a query from the command line

Both tasks live in `scry_core` itself now (a generic, config-driven
pair any project depending on `scry_core` gets for free -- see that
package's own README/`Scry.Core.QueryTool` moduledoc for the full
config shape). This package's own `config/config.exs` registers its
`Scry.Test.Core.Conn` constructors as named backends (`in_memory`, the
default, `ets`, `sqlite`, `postgres`, `timescaledb`), so from inside
this repo both tasks work exactly as before the move -- same names,
same flags, same output:

```console
$ mix scry.query 'SELECT users WHERE status = "active" { name }'
$ mix scry.query --file path/to/query.scry
$ mix scry.query --backend ets 'SELECT users WHERE id = 1 { name }'
```

```console
$ mix scry.iex
scry> SELECT users
...>   WHERE age > 18
...>   { name }
[%{"name" => "Alice"}, ...]
scry>
```

`--backend` picks `in_memory` (the default), `ets`, `sqlite`,
`postgres`, or `timescaledb` (the latter two need `docker compose up -d`
first) -- same seed data either way, only *how* the answer is produced
changes. For `mix scry.iex`: a query only runs once it parses --
pressing Enter mid-query keeps the prompt open (`...>`) for the next
line, rather
than erroring immediately; Ctrl+D exits; for Up/Down arrow-key history
(recalling and re-running a previous query), run it as `iex -S mix
scry.iex` instead -- plain `mix scry.iex` prints a reminder of this at
startup. `mix help scry.query`/`mix help scry.iex` have the full usage.

### `mix scry.bench` -- benchmark `Scry.Core.Executor`'s real speed and memory

Generates a real SQLite database and runs a point lookup, a flat
aggregate over the whole table, and both a low- and a high-cardinality
`GROUP BY` three ways side by side: `raw sql` (the equivalent query
issued directly against the connection via `Exqlite.Sqlite3`,
bypassing Scry entirely -- the baseline), `sqlite` (the same query as
Scry query text, through `Scry.Core.Executor.run/4` and `Scry.Engine.
Exqlite`, real `execute/3` SQL compilation included -- answers "what
does going through Scry actually cost"), and, with `--compare-ets`, `ets` (the
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

No `--compare-postgres` yet, deliberately -- this task generates its
benchmark dataset at millions of rows via SQLite's own low-level
prepared-statement NIF loop, and loading that same volume into a real,
network-attached Postgres row-by-row would be dramatically slower
without `COPY`-based bulk loading, a real, separate piece of work.
`Conn.postgres/1` itself only ever loads `Seed.data()`'s own small,
fixed fixture (a handful of rows per table) -- fine as ordinary
`INSERT`s, not a benchmark-scale concern.

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

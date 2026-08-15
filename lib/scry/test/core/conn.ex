defmodule Scry.Test.Core.Conn do
  @moduledoc """
  Five constructors, one shared dataset -- each returns a ready
  `{engine_module, conn}` pair, straight into `Scry.Core.Executor.run/3,4`'s
  own second and third arguments, backed by a real `Scry.Core.
  EngineBehaviour` implementation instead of this package rolling its
  own (that role now belongs to `scry_engine_inmemory`/`scry_engine_ets`/
  `scry_engine_exqlite`/`scry_engine_postgrex`, each a real,
  independent package):

    * `in_memory/1` -- `Scry.Engine.InMemory`, no pushdown at all.
    * `ets/1` -- `Scry.Engine.ETS`, real O(1) key-lookup pushdown (every
      seed table has a declared `id` key, `Scry.Test.Core.Seed.keys/0`).
    * `sqlite/1` -- `Scry.Engine.Exqlite`, a fresh `:memory:` SQLite
      database loaded with the same rows, real `WHERE`-clause pushdown.
    * `postgres/1` -- `Scry.Engine.Postgrex`, the same rows loaded into
      a real, external Postgres (see its own doc below for the one real
      way this constructor differs from the other three).
    * `timescaledb/1` -- `Scry.Engine.Postgrex` again, **entirely
      unmodified**, pointed at a real, external TimescaleDB instead of
      plain Postgres. This exists to answer a real question empirically
      rather than just assert it: the roadmap names
      `scry_engine_timescaledb` as a from-scratch adapter meant to
      validate the `scry_reltime` composite (relational + time-series)
      architecture. Investigation found nothing for a dedicated adapter
      to actually do differently -- TimescaleDB speaks the plain
      Postgres wire protocol, and the language has no time-bucketing/
      hypertable-specific construct yet to compile specially. `Scry.
      TimeSeries.Executor.run/5` already lowers `LAST` into an ordinary
      `WHERE` predicate before any engine ever sees it (recursively,
      including inside a nested/correlated `SELECT` -- Scry's own
      `JOIN`-equivalent), so the composite's real value already exists
      with zero new code, against any plain `Scry.Core.EngineBehaviour`
      engine. `timescaledb/1` is that empirical proof: the exact same
      `Scry.Engine.Postgrex` module `postgres/1` uses, unmodified,
      against a real TimescaleDB container -- not a rewrite, not a
      simulation.

  All five default to `Scry.Test.Core.Seed.data()` when called with no
  argument -- the same dataset, five different backends, so a query
  run against each is directly comparable (see `test/scry/test/core/
  parity_test.exs`'s own genuine 3-way parity tests, `test/scry/
  test/core/postgres_parity_test.exs` for `postgres/1`'s own, and
  `timescaledb_parity_test.exs` for `timescaledb/1`'s own, each kept
  separate -- see those files' own moduledocs for why). Passing a custom
  `data()` map still works on every constructor, same shape `Conn.new/1`
  used to accept on this package's own now-removed engine.

  ## Usage

      {engine, conn} = Scry.Test.Core.Conn.in_memory()
      {:ok, query} = Scry.Core.parse(~s(SELECT users WHERE age > 18 { name }))
      {:ok, cursor} = Scry.Core.Executor.run(query, engine, conn)
      rows = Scry.Core.Cursor.to_list(cursor)

  Swapping `in_memory()` for `ets()` or `sqlite()` above runs the exact
  same query against a different backend, no other code changed.

  `sqlite/1`'s own database lives entirely in memory (`":memory:"`, an
  ordinary SQLite feature -- no temp file, nothing to clean up, a fresh
  database on every call) and creates each table with a real column
  type (`INTEGER`/`REAL`/`TEXT`, inferred per column from the seed
  data's own consistent Elixir value type) and `NOT NULL` on every
  column -- both genuinely true of this fixed, hand-authored dataset,
  and required for `Scry.Engine.Exqlite`'s own `execute/3` to push a
  `WHERE`/aggregate/ordering comparison down at all (its own moduledoc
  has the full schema-level correctness reasoning; an untyped,
  nullable-by-default column would make it decline nearly every query
  in this package's own parity suite for no real reason). This is
  test-fixture generation from this package's own trusted `Seed` data
  (or a caller's own trusted test data), not a real adapter accepting
  arbitrary query input, so table/column names are interpolated
  directly rather than validated the way `Scry.Engine.Exqlite`'s own
  `execute/3` treats a `source` (untrusted, query-supplied) value.

  **`postgres/1`/`timescaledb/1` are genuinely different from the other
  three in one real way, not just further coats of paint**: `in_memory/1`/
  `ets/1` are plain in-process data, and `sqlite/1` opens a brand-new
  `:memory:` database per call -- all three are automatically,
  freshly isolated on every single call, safe under `async: true` with
  no extra thought. A real Postgres/TimescaleDB is a *persistent,
  shared, external* service instead -- calling either one twice hits
  the *same* physical tables. `postgres_connection_opts/0`/
  `timescaledb_connection_opts/0` each always point at the same fixed
  `public`-schema tables `sqlite/1` conceptually mirrors
  (`DROP TABLE IF EXISTS ... CASCADE` then recreate, on every call --
  idempotent and safe to call repeatedly, but genuinely **not** safe to
  call concurrently with itself). Deliberately not given per-call
  schema isolation (a `search_path` set to a fresh schema per call):
  `Scry.Engine.Postgrex.Schema.column_info/2` hardcodes
  `WHERE table_schema = 'public'` (that package's own accepted scope
  decision), so a non-`public` schema would make its own introspection
  -- and therefore the `NOT NULL` gate every pushed-down query needs --
  silently find nothing. Every test exercising `postgres/1`/`timescaledb/1`
  runs `async: false` for exactly this reason (`test/scry/test/core/
  postgres_parity_test.exs`/`postgres_conn_test.exs`/`timescaledb_parity_test.exs`/
  `timescaledb_conn_test.exs`'s own moduledocs). Also unlike the other
  three: these tables persist in whatever Postgres/TimescaleDB either
  constructor was pointed at until the next call recreates them (or the
  database is torn down) -- there is no `:memory:`-style automatic
  cleanup, the same way none of `in_memory/1`/`ets/1`/`sqlite/1` has an
  explicit `close/1` call site anywhere in this package either.
  """

  alias Scry.Engine.ETS
  alias Scry.Engine.Exqlite, as: SqliteEngine
  alias Scry.Engine.InMemory
  alias Scry.Engine.Postgrex, as: Postgres
  alias Scry.Test.Core.Seed

  @typedoc "Keyed by source path (e.g. `[\"orders\"]`), matching `Scry.Core.Query.source`."
  @type data :: %{optional([String.t()]) => [Scry.Core.EngineBehaviour.row()]}

  @doc "`{Scry.Engine.InMemory, conn}`, prefilled with `data` (`Scry.Test.Core.Seed.data/0` by default)."
  @spec in_memory(data()) :: {module(), InMemory.Conn.t()}
  def in_memory(data \\ Seed.data()) when is_map(data) do
    {InMemory, InMemory.Conn.new(data)}
  end

  @doc """
  `{Scry.Engine.ETS, conn}`, the same dataset loaded into one ETS table
  per source, keyed by `Scry.Test.Core.Seed.keys/0` -- so a query
  filtering on a table's own `id` genuinely exercises `Scry.Engine.
  ETS`'s own `execute/3` O(1) lookup path, not just its full-scan
  fallback.
  """
  @spec ets(data()) :: {module(), ETS.Conn.t()}
  def ets(data \\ Seed.data()) when is_map(data) do
    {ETS, ETS.Conn.new(data, keys: Seed.keys())}
  end

  @doc """
  `{Scry.Engine.Exqlite, conn}`, the same dataset loaded into a fresh
  in-memory SQLite database -- a real `Scry.Engine.Exqlite.Conn`, so a
  query filtering on a plain field genuinely exercises `Scry.Engine.
  Exqlite`'s own `execute/3` `WHERE`-clause pushdown, not just its
  full-scan fallback.
  """
  @spec sqlite(data()) :: {module(), SqliteEngine.Conn.t()}
  def sqlite(data \\ Seed.data()) when is_map(data) do
    {:ok, conn} = SqliteEngine.Conn.open(":memory:")
    Enum.each(data, fn {[table], rows} -> load_table(conn, table, rows) end)
    {SqliteEngine, conn}
  end

  @doc """
  `{Scry.Engine.Postgrex, conn}`, the same dataset loaded into a real,
  external Postgres -- a real `Scry.Engine.Postgrex.Conn`, so a query
  filtering on a plain field genuinely exercises `Scry.Engine.Postgrex`'s
  own `execute/3` `WHERE`-clause pushdown, not just its full-scan
  fallback. See this module's own moduledoc for the one real way this
  constructor differs from the other three (a real, persistent,
  external service, not a fresh in-process structure per call).

  Connection options come from `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/
  `PGDATABASE`, defaulting to this package's own `docker-compose.yml`
  service (`localhost:5433`, user/password `scry`, database
  `scry_test_core`) -- a deliberately different host port and database
  name than `scry_engine_postgrex`'s own compose service/test suite
  uses, so both containers can run at once and the two packages' test
  data never collide even if pointed at the same physical Postgres.
  """
  @spec postgres(data()) :: {module(), Postgres.Conn.t()}
  def postgres(data \\ Seed.data()) when is_map(data) do
    {:ok, conn} = Postgres.Conn.open(postgres_connection_opts())
    Enum.each(data, fn {[table], rows} -> load_postgres_table(conn, table, rows) end)
    {Postgres, conn}
  end

  @doc """
  `{Scry.Engine.Postgrex, conn}` again -- the exact same module
  `postgres/1` uses, unmodified, pointed at a real, external
  TimescaleDB instead of plain Postgres. This module's own moduledoc
  has the full reasoning for why this constructor exists at all (empirical
  proof that the `scry_reltime` composite architecture's real value
  already exists with zero TimescaleDB-specific code, not a dedicated
  adapter).

  Connection options come from `TSDB_HOST`/`TSDB_PORT`/`TSDB_USER`/
  `TSDB_PASSWORD`/`TSDB_DATABASE`, defaulting to this package's own
  `docker-compose.yml` service (`localhost:5434`, user/password `scry`,
  database `scry_test_core_timescaledb`) -- a deliberately different
  host port and database name than `postgres/1`'s own service, so both
  containers can run at once with no collision.
  """
  @spec timescaledb(data()) :: {module(), Postgres.Conn.t()}
  def timescaledb(data \\ Seed.data()) when is_map(data) do
    {:ok, conn} = Postgres.Conn.open(timescaledb_connection_opts())
    Enum.each(data, fn {[table], rows} -> load_postgres_table(conn, table, rows) end)
    {Postgres, conn}
  end

  defp timescaledb_connection_opts do
    [
      hostname: System.get_env("TSDB_HOST", "localhost"),
      port: String.to_integer(System.get_env("TSDB_PORT", "5434")),
      username: System.get_env("TSDB_USER", "scry"),
      password: System.get_env("TSDB_PASSWORD", "scry"),
      database: System.get_env("TSDB_DATABASE", "scry_test_core_timescaledb")
    ]
  end

  defp postgres_connection_opts do
    [
      hostname: System.get_env("PGHOST", "localhost"),
      port: String.to_integer(System.get_env("PGPORT", "5433")),
      username: System.get_env("PGUSER", "scry"),
      password: System.get_env("PGPASSWORD", "scry"),
      database: System.get_env("PGDATABASE", "scry_test_core")
    ]
  end

  defp load_postgres_table(_conn, _table, []), do: :ok

  # Mirrors `load_table/3` (the `sqlite/1` internal below) in structure
  # -- same alphabetical-column-order inference from the first row,
  # same blanket `NOT NULL` -- but issues real `Postgrex.query!/3`
  # calls instead of low-level `Exqlite.Sqlite3` NIF calls. `DROP TABLE
  # IF EXISTS ... CASCADE` before every `CREATE TABLE` is what makes
  # this constructor idempotent (safe to call repeatedly against the
  # same real, persistent database) -- this module's own moduledoc has
  # the full reasoning for why that's *not* the same as safe to call
  # concurrently with itself.
  defp load_postgres_table(%Postgres.Conn{pool: pool}, table, [first_row | _] = rows) do
    columns = first_row |> Map.keys() |> Enum.sort()
    column_list = Enum.join(columns, ", ")

    column_defs =
      columns
      |> Enum.map(&"#{&1} #{postgres_sql_type(Map.fetch!(first_row, &1))} NOT NULL")
      |> Enum.join(", ")

    Postgrex.query!(pool, "DROP TABLE IF EXISTS #{table} CASCADE", [])
    Postgrex.query!(pool, "CREATE TABLE #{table} (#{column_defs})", [])

    placeholders =
      columns |> Enum.with_index(1) |> Enum.map(fn {_column, i} -> "$#{i}" end) |> Enum.join(", ")

    Enum.each(rows, fn row ->
      Postgrex.query!(
        pool,
        "INSERT INTO #{table} (#{column_list}) VALUES (#{placeholders})",
        Enum.map(columns, &Map.get(row, &1))
      )
    end)
  end

  # Elixir floats are 64-bit -- `DOUBLE PRECISION`/`float8` is the
  # faithful Postgres match, not `REAL`/`float4` (SQLite's own `REAL`
  # has no such distinction to get wrong, since it stores every
  # non-integer number as a native 8-byte IEEE float regardless of the
  # declared type name).
  defp postgres_sql_type(value) when is_integer(value), do: "INTEGER"
  defp postgres_sql_type(value) when is_float(value), do: "DOUBLE PRECISION"
  defp postgres_sql_type(value) when is_binary(value), do: "TEXT"

  defp load_table(_conn, _table, []), do: :ok

  # Every column in `Scry.Test.Core.Seed`'s own fixed dataset is
  # genuinely never `nil`, and each has one consistent Elixir type
  # across every row -- declaring a real column type plus `NOT NULL`
  # here states both guarantees to SQLite's own schema, rather than
  # leaving every column untyped and nullable by default.
  # `Scry.Engine.Exqlite`'s `execute/3` now requires a schema-level
  # `NOT NULL` guarantee before pushing a `WHERE`/aggregate down at
  # all, and an ordering comparison's (`<`/`>`/`<=`/`>=`) own column
  # type affinity to genuinely match the compared literal's type (its
  # own moduledoc has the full correctness reasoning) -- an untyped,
  # nullable-by-default column here would make it decline nearly every
  # query in this package's own parity suite, not because the data is
  # actually unsafe, just because the schema never said so.
  defp load_table(%SqliteEngine.Conn{db: db}, table, [first_row | _] = rows) do
    columns = first_row |> Map.keys() |> Enum.sort()
    column_list = Enum.join(columns, ", ")

    column_defs =
      columns
      |> Enum.map(&"#{&1} #{sql_type(Map.fetch!(first_row, &1))} NOT NULL")
      |> Enum.join(", ")

    :ok = Exqlite.Sqlite3.execute(db, "CREATE TABLE #{table} (#{column_defs})")

    placeholders = columns |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        db,
        "INSERT INTO #{table} (#{column_list}) VALUES (#{placeholders})"
      )

    Enum.each(rows, fn row ->
      :ok = Exqlite.Sqlite3.bind(stmt, Enum.map(columns, &Map.get(row, &1)))
      :done = Exqlite.Sqlite3.step(db, stmt)
    end)

    Exqlite.Sqlite3.release(db, stmt)
  end

  # Maps an Elixir value to a SQL type declaration whose own SQLite
  # type affinity (`Scry.Engine.Exqlite`'s own 5-rule algorithm) genuinely
  # matches how this dataset's own values compare -- an integer or float
  # both need `:numeric` affinity, a string needs `:text`.
  defp sql_type(value) when is_integer(value), do: "INTEGER"
  defp sql_type(value) when is_float(value), do: "REAL"
  defp sql_type(value) when is_binary(value), do: "TEXT"
end

defmodule Scry.Test.Core.Conn do
  @moduledoc """
  Three constructors, one shared dataset -- each returns a ready
  `{engine_module, conn}` pair, straight into `Scry.Core.Executor.run/3,4`'s
  own second and third arguments, backed by a real `Scry.Core.
  EngineBehaviour` implementation instead of this package rolling its
  own (that role now belongs to `scry_engine_inmemory`/`scry_engine_ets`/
  `scry_engine_exqlite`, each a real, independent package):

    * `in_memory/1` -- `Scry.Engine.InMemory`, no pushdown at all.
    * `ets/1` -- `Scry.Engine.ETS`, real O(1) key-lookup pushdown (every
      seed table has a declared `id` key, `Scry.Test.Core.Seed.keys/0`).
    * `sqlite/1` -- `Scry.Engine.Exqlite`, a fresh `:memory:` SQLite
      database loaded with the same rows, real `WHERE`-clause pushdown.

  All three default to `Scry.Test.Core.Seed.data()` when called with no
  argument -- the same dataset, three different backends, so a query
  run against each is directly comparable (see `test/scry/test/core/
  parity_test.exs`'s own genuine 3-way parity tests). Passing a custom
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
  """

  alias Scry.Engine.ETS
  alias Scry.Engine.Exqlite, as: SqliteEngine
  alias Scry.Engine.InMemory
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

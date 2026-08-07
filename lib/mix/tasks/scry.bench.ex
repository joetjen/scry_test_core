defmodule Mix.Tasks.Scry.Bench do
  @shortdoc "Measures ScryCore.Executor's memory behavior against a real, embedded SQLite database"

  @moduledoc """
  Generates a real SQLite database (`users`/`orders`, via `exqlite`'s
  own low-level `Exqlite.Sqlite3` NIF API -- not `DBConnection.stream/4`,
  whose own cursor is scoped to the transaction that created it and
  therefore unusable across a `fetch/2` call boundary) and reports the
  actual process-memory delta `ScryCore.Executor.run/4` incurs for a
  handful of representative queries -- a point lookup, a flat aggregate
  over the whole table, a low-cardinality `GROUP BY`, and a genuinely
  high-cardinality one. This is the same measurement technique (and the
  same finding) that originally motivated bounding `Executor`'s own
  memory to what a query actually needs (see `scry_core`'s own
  `CHANGELOG.md`) -- kept here, against a real embedded database rather
  than a scratch script, as a repeatable regression tool for future
  work, not a one-off proof.

      $ mix scry.bench
      $ mix scry.bench --users 1000000

  `--users` (default 100,000) controls the generated scale; `orders`
  is always twice that. The database is generated fresh into a tmp
  file on every run (deleted again once the run completes) --
  regeneration at the default scale takes a few seconds; a much larger
  `--users` trades that for a more realistic (and slower) run.

  Each measurement reports two numbers: the *immediate* delta (right
  after the operation returns -- includes not-yet-reclaimed garbage
  the operation churned through) and the *settled* delta (after an
  explicit `:erlang.garbage_collect/0` -- what's actually still
  retained). `:erlang.memory(:total)` reports allocator-held memory,
  not strictly live data, so even a genuinely O(1)-memory streaming
  pass over a huge table can show a large *immediate* number purely
  from allocator churn; the settled number is the one that actually
  answers "did this retain the whole source in memory."
  """

  use Mix.Task

  @default_users 100_000

  defmodule Engine do
    @moduledoc false
    @behaviour ScryCore.EngineBehaviour

    @impl true
    def fetch(db_path, [table]) when table in ["users", "orders"] do
      {:ok, conn} = Exqlite.Sqlite3.open(db_path, mode: :readonly)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT * FROM #{table}")
      {:ok, columns} = Exqlite.Sqlite3.columns(conn, stmt)
      columns = Enum.map(columns, &to_string/1)

      stream =
        Stream.resource(
          fn -> {conn, stmt} end,
          fn {conn, stmt} = state ->
            case Exqlite.Sqlite3.step(conn, stmt) do
              {:row, values} -> {[Enum.zip(columns, values) |> Map.new()], state}
              :done -> {:halt, state}
            end
          end,
          fn {conn, stmt} ->
            Exqlite.Sqlite3.release(conn, stmt)
            Exqlite.Sqlite3.close(conn)
          end
        )

      {:ok, stream}
    end

    def fetch(_conn, source), do: {:error, {:no_such_source, source}}
  end

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {switches, _args} = OptionParser.parse!(argv, strict: [users: :integer])
    user_count = switches[:users] || @default_users
    order_count = user_count * 2
    mid_id = div(user_count, 2)

    db_path = Path.join(System.tmp_dir!(), "scry_test_engine_core_bench.db")
    File.rm(db_path)

    try do
      generate(db_path, user_count, order_count)

      IO.puts(
        "\n#{user_count} users / #{order_count} orders -- memory delta through " <>
          "ScryCore.Executor.run/4\n"
      )

      measure("WHERE id = <mid> LIMIT 1 (a real, non-adversarial point lookup)", fn ->
        run_to_list(~s[SELECT users WHERE id = #{mid_id} LIMIT 1 { name }], db_path)
      end)

      measure("no LIMIT, flat avg(age) over the whole users table (O(1) groups)", fn ->
        run_to_list("SELECT users { a: avg(age) }", db_path)
      end)

      measure("GROUP BY status (3 distinct groups) -- count + avg(age)", fn ->
        run_to_list(
          "SELECT users GROUP BY status { status, n: count(id), a: avg(age) }",
          db_path
        )
      end)

      measure(
        "GROUP BY user_id on orders (~#{user_count} distinct groups -- adversarial: " <>
          "memory scales with group count, not row count)",
        fn ->
          run_to_list(
            "SELECT orders GROUP BY user_id { user_id, total: sum(total) }",
            db_path
          )
        end
      )
    after
      File.rm(db_path)
    end
  end

  defp run_to_list(query_text, db_path) do
    {:ok, query} = ScryCore.parse(query_text)
    {:ok, cursor} = ScryCore.Executor.run(query, Engine, db_path)
    ScryCore.Cursor.to_list(cursor)
  end

  defp measure(label, fun) do
    :erlang.garbage_collect()
    Process.sleep(50)
    before_mem = :erlang.memory(:total)

    fun.()

    immediate = :erlang.memory(:total)
    :erlang.garbage_collect()
    Process.sleep(50)
    settled = :erlang.memory(:total)

    immediate_mb = Float.round((immediate - before_mem) / 1_048_576, 1)
    settled_mb = Float.round((settled - before_mem) / 1_048_576, 1)

    IO.puts(
      "  #{String.pad_trailing(label, 78)}\n" <>
        "    immediate: +#{immediate_mb} MB, settled after GC: +#{settled_mb} MB"
    )
  end

  defp generate(db_path, user_count, order_count) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, status TEXT)
      """)

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER, total INTEGER)
      """)

    IO.write("Generating #{user_count} users / #{order_count} orders...")
    gen_users(conn, user_count)
    gen_orders(conn, order_count, user_count)
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE INDEX idx_orders_user_id ON orders(user_id)")
    Exqlite.Sqlite3.close(conn)
    IO.puts(" done.")
  end

  defp gen_users(conn, count) do
    statuses = ["active", "inactive", "pending"]

    :ok = Exqlite.Sqlite3.execute(conn, "BEGIN")
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO users VALUES (?, ?, ?, ?)")

    Enum.each(1..count, fn i ->
      :ok =
        Exqlite.Sqlite3.bind(stmt, [
          i,
          "user_#{i}",
          18 + rem(i, 65),
          Enum.at(statuses, rem(i, 3))
        ])

      :done = Exqlite.Sqlite3.step(conn, stmt)
    end)

    :ok = Exqlite.Sqlite3.execute(conn, "COMMIT")
    Exqlite.Sqlite3.release(conn, stmt)
  end

  defp gen_orders(conn, count, user_count) do
    :ok = Exqlite.Sqlite3.execute(conn, "BEGIN")
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO orders VALUES (?, ?, ?)")

    Enum.each(1..count, fn i ->
      :ok = Exqlite.Sqlite3.bind(stmt, [i, 1 + rem(i, user_count), 10 + rem(i, 490)])
      :done = Exqlite.Sqlite3.step(conn, stmt)
    end)

    :ok = Exqlite.Sqlite3.execute(conn, "COMMIT")
    Exqlite.Sqlite3.release(conn, stmt)
  end
end

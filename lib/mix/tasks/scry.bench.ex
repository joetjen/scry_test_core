defmodule Mix.Tasks.Scry.Bench do
  @shortdoc "Benchmarks ScryCore.Executor's speed and memory against a real, embedded SQLite database"

  @moduledoc """
  Generates a real SQLite database (`users`/`orders`, via `exqlite`'s
  own low-level `Exqlite.Sqlite3` NIF API -- not `DBConnection.stream/4`,
  whose own cursor is scoped to the transaction that created it and
  therefore unusable across a `fetch/2` call boundary) and reports real
  timing and memory numbers for `ScryCore.Executor.run/4` against a
  handful of representative queries -- a point lookup, a flat aggregate
  over the whole table, a low-cardinality `GROUP BY`, and a genuinely
  high-cardinality one. The memory side of this is the same measurement
  technique (and the same finding) that originally motivated bounding
  `Executor`'s own memory to what a query actually needs (see
  `scry_core`'s own `CHANGELOG.md`) -- kept here, against a real
  embedded database rather than a scratch script, as a repeatable
  regression tool for future work, not a one-off proof.

      $ mix scry.bench
      $ mix scry.bench --users 1000000
      $ mix scry.bench --users 1000000 --iterations 10

  `--users` (default 10,000,000) controls the generated scale; `orders`
  is always twice that. `--iterations` (default 3) controls how many
  *timed* runs each query gets, on top of one untimed warmup run
  (primes the OS-level file-page cache so the first timed iteration
  isn't penalized for a cold-cache disk read the rest won't pay). The
  database is generated fresh into a tmp file on every run (deleted
  again once the run completes) -- regeneration at the default scale
  takes a while; a smaller `--users` trades that for a quicker, less
  realistic run.

  ## What's reported, per query

  - **Rows scanned** -- the real number of rows `ScryCore.Executor`
    actually pulled from the source (a genuine per-row `:counters`
    tally inside `fetch/2`, not inferred from the query or the result),
    and **rows returned** -- the output row count. These can differ a
    lot (a `GROUP BY` scans every matching row but returns one per
    group; a `LIMIT`-bound point lookup may scan far fewer rows than
    the source has).
  - **Duration** -- average, min, median, max, and standard deviation
    across the timed iterations, plus the total across all of them.
  - **Throughput** -- rows scanned per second, and microseconds per
    scanned row (both derived from the *average* duration).
  - **Memory** -- the same *immediate* (right after the call returns,
    including not-yet-reclaimed garbage) vs. *settled* (after an
    explicit `:erlang.garbage_collect/0` -- what's actually still
    retained) distinction the memory-only version of this task always
    reported, plus settled bytes retained per scanned row.

  A summary table across every query runs at the end for an at-a-glance
  comparison, followed by the benchmark's own total wall-clock time
  (database generation included).
  """

  use Mix.Task

  @default_users 10_000_000
  @default_iterations 3

  defmodule Engine do
    @moduledoc false
    @behaviour ScryCore.EngineBehaviour

    # `conn` is `{db_path, counter}` -- `counter` (`:counters`, size 1)
    # is bumped once per row actually pulled through the stream, giving
    # a real, per-call "rows scanned" tally, not a number inferred from
    # the query or the result. A fresh counter per call (`run_query/2`
    # below) keeps each timed iteration's own tally independent.
    @impl true
    def fetch({db_path, counter}, [table]) when table in ["users", "orders"] do
      {:ok, conn} = Exqlite.Sqlite3.open(db_path, mode: :readonly)
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT * FROM #{table}")
      {:ok, columns} = Exqlite.Sqlite3.columns(conn, stmt)
      columns = Enum.map(columns, &to_string/1)

      stream =
        Stream.resource(
          fn -> {conn, stmt} end,
          fn {conn, stmt} = state ->
            case Exqlite.Sqlite3.step(conn, stmt) do
              {:row, values} ->
                :counters.add(counter, 1, 1)
                {[Enum.zip(columns, values) |> Map.new()], state}

              :done ->
                {:halt, state}
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

    {switches, _args} =
      OptionParser.parse!(argv, strict: [users: :integer, iterations: :integer])

    user_count = switches[:users] || @default_users
    iterations = switches[:iterations] || @default_iterations
    order_count = user_count * 2
    mid_id = div(user_count, 2)

    db_path = Path.join(System.tmp_dir!(), "scry_test_engine_core_bench.db")
    File.rm(db_path)

    try do
      {run_us, _} =
        :timer.tc(fn ->
          {gen_us, :ok} = :timer.tc(fn -> generate(db_path, user_count, order_count) end)
          IO.puts(" done in #{format_duration(gen_us)}.")

          IO.puts(
            "\n#{format_int(user_count)} users / #{format_int(order_count)} orders -- " <>
              "#{iterations} timed iterations (+1 untimed warmup) per query, through " <>
              "ScryCore.Executor.run/4\n"
          )

          results = [
            benchmark(
              "WHERE id = <mid> LIMIT 1 (a real, non-adversarial point lookup)",
              iterations,
              fn -> run_query(~s[SELECT users WHERE id = #{mid_id} LIMIT 1 { name }], db_path) end
            ),
            benchmark(
              "no LIMIT, flat avg(age) over the whole users table (O(1) groups)",
              iterations,
              fn -> run_query("SELECT users { a: avg(age) }", db_path) end
            ),
            benchmark(
              "GROUP BY status (3 distinct groups) -- count + avg(age)",
              iterations,
              fn ->
                run_query(
                  "SELECT users GROUP BY status { status, n: count(id), a: avg(age) }",
                  db_path
                )
              end
            ),
            benchmark(
              "GROUP BY user_id on orders (~#{format_int(user_count)} distinct groups -- " <>
                "adversarial: memory scales with group count, not row count)",
              iterations,
              fn ->
                run_query(
                  "SELECT orders GROUP BY user_id { user_id, total: sum(total) }",
                  db_path
                )
              end
            )
          ]

          print_summary_table(results)
        end)

      IO.puts("Total benchmark wall-clock time (generation included): #{format_duration(run_us)}")
    after
      File.rm(db_path)
    end
  end

  defp run_query(query_text, db_path) do
    {:ok, query} = ScryCore.parse(query_text)
    counter = :counters.new(1, [])
    {:ok, cursor} = ScryCore.Executor.run(query, Engine, {db_path, counter})
    rows = ScryCore.Cursor.to_list(cursor)
    {rows, :counters.get(counter, 1)}
  end

  # ---- Benchmark runner ----------------------------------------------------

  defp benchmark(label, iterations, fun) do
    # Untimed -- primes the OS-level file-page cache so the first
    # *timed* iteration isn't penalized for a cold-cache disk read none
    # of the others will pay either.
    fun.()

    timings = for _ <- 1..iterations, do: :timer.tc(fun)
    durations_us = Enum.map(timings, &elem(&1, 0))
    {rows, rows_scanned} = timings |> List.first() |> elem(1)

    result = %{
      label: label,
      iterations: iterations,
      rows_returned: length(rows),
      rows_scanned: rows_scanned,
      stats: duration_stats(durations_us),
      mem: measure_memory(fun)
    }

    print_result(result)
    result
  end

  defp duration_stats(durations_us) do
    n = length(durations_us)
    total = Enum.sum(durations_us)
    avg = total / n
    sorted = Enum.sort(durations_us)

    median =
      if rem(n, 2) == 1 do
        Enum.at(sorted, div(n, 2)) * 1.0
      else
        (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
      end

    variance =
      Enum.reduce(durations_us, 0.0, fn x, acc -> acc + :math.pow(x - avg, 2) end) / n

    %{
      total_us: total,
      avg_us: avg,
      min_us: Enum.min(durations_us) * 1.0,
      max_us: Enum.max(durations_us) * 1.0,
      median_us: median,
      stddev_us: :math.sqrt(variance)
    }
  end

  # Bracketed by an explicit GC + settle before *and* after `fun.()`,
  # separately from the timing loop above -- interleaving `:erlang.
  # garbage_collect/0` and `Process.sleep/1` into the timed iterations
  # would inflate every duration by a fixed, irrelevant amount.
  defp measure_memory(fun) do
    :erlang.garbage_collect()
    Process.sleep(50)
    before_mem = :erlang.memory(:total)

    fun.()

    immediate = :erlang.memory(:total)
    :erlang.garbage_collect()
    Process.sleep(50)
    settled = :erlang.memory(:total)

    %{immediate_bytes: immediate - before_mem, settled_bytes: settled - before_mem}
  end

  defp print_result(%{
         label: label,
         iterations: iterations,
         rows_returned: rows_returned,
         rows_scanned: rows_scanned,
         stats: s,
         mem: m
       }) do
    rows_per_sec = safe_rate(rows_scanned, s.avg_us)
    us_per_row = safe_div(s.avg_us, rows_scanned)
    settled_bytes_per_row = safe_div(m.settled_bytes, rows_scanned)

    IO.puts("""

    #{label}
      rows:        #{format_int(rows_scanned)} scanned, #{format_int(rows_returned)} returned (#{iterations} timed iterations, +1 untimed warmup)
      duration:    avg #{format_duration(s.avg_us)} (min #{format_duration(s.min_us)}, median #{format_duration(s.median_us)}, max #{format_duration(s.max_us)}, stddev #{format_duration(s.stddev_us)})
                   total #{format_duration(s.total_us)} across all #{iterations} timed iterations
      throughput:  #{format_int(round(rows_per_sec))} rows/sec, #{format_float(us_per_row)} µs/row scanned
      memory:      immediate #{format_mb(m.immediate_bytes)}, settled after GC #{format_mb(m.settled_bytes)} (#{format_float(settled_bytes_per_row)} bytes/row settled)\
    """)
  end

  defp print_summary_table(results) do
    columns = [
      {"query", 50, :left},
      {"rows scanned", 13, :right},
      {"avg duration", 12, :right},
      {"rows/sec", 12, :right},
      {"µs/row", 10, :right},
      {"settled mem", 12, :right}
    ]

    IO.puts("\nSummary")
    IO.puts(render_row(Enum.map(columns, fn {name, width, align} -> {name, width, align} end)))
    IO.puts(String.duplicate("-", Enum.sum(Enum.map(columns, fn {_, w, _} -> w + 3 end))))

    Enum.each(results, fn r ->
      rows_per_sec = safe_rate(r.rows_scanned, r.stats.avg_us)
      us_per_row = safe_div(r.stats.avg_us, r.rows_scanned)

      cells = [
        {String.slice(r.label, 0, 50), 50, :left},
        {format_int(r.rows_scanned), 13, :right},
        {format_duration(r.stats.avg_us), 12, :right},
        {format_int(round(rows_per_sec)), 12, :right},
        {format_float(us_per_row), 10, :right},
        {format_mb(r.mem.settled_bytes), 12, :right}
      ]

      IO.puts(render_row(cells))
    end)
  end

  defp render_row(cells) do
    cells
    |> Enum.map(fn
      {text, width, :left} -> String.pad_trailing(to_string(text), width)
      {text, width, :right} -> String.pad_leading(to_string(text), width)
    end)
    |> Enum.join(" | ")
  end

  defp safe_rate(_count, avg_us) when avg_us <= 0, do: 0.0
  defp safe_rate(count, avg_us), do: count / (avg_us / 1_000_000)

  defp safe_div(_numerator, 0), do: 0.0
  defp safe_div(numerator, denominator), do: numerator / denominator

  defp format_duration(us) when us >= 1_000_000, do: "#{Float.round(us / 1_000_000, 3)} s"
  defp format_duration(us) when us >= 1_000, do: "#{Float.round(us / 1_000, 2)} ms"
  defp format_duration(us), do: "#{Float.round(us * 1.0, 1)} µs"

  defp format_mb(bytes) do
    mb = bytes / 1_048_576
    sign = if mb >= 0, do: "+", else: ""
    "#{sign}#{Float.round(mb, 2)} MB"
  end

  defp format_float(f), do: to_string(Float.round(f * 1.0, 2))

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
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

    IO.write("Generating #{format_int(user_count)} users / #{format_int(order_count)} orders...")
    gen_users(conn, user_count)
    gen_orders(conn, order_count, user_count)
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE INDEX idx_orders_user_id ON orders(user_id)")
    Exqlite.Sqlite3.close(conn)
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

defmodule Mix.Tasks.Scry.Bench do
  @shortdoc "Benchmarks Scry.Core.Executor's speed and memory against real engines at scale"

  @moduledoc """
  Generates a real SQLite database (`users`/`orders`) and reports real
  timing and memory numbers for a handful of representative queries --
  a point lookup, a flat aggregate over the whole table, a low-
  cardinality `GROUP BY`, and a genuinely high-cardinality one -- run
  three ways side by side:

    * **`raw sql`** -- the equivalent query issued directly against the
      open SQLite connection via `Exqlite.Sqlite3`, bypassing Scry
      entirely. The baseline: however fast SQLite itself can answer
      this, with none of Scry's own parsing/execution overhead.
    * **`sqlite`** -- the same query, as Scry query text, through
      `Scry.Core.Executor.run/4` and `Scry.Engine.Exqlite` (real
      `fetch/3` `WHERE`-clause pushdown, batched `multi_step/3`
      fetching, a connection opened once and reused across every
      query) -- answers "how much does going through Scry actually
      cost, on top of the same database".
    * **`ets`** (only with `--compare-ets`) -- the same query again,
      against a comparably-sized `Scry.Engine.ETS` dataset instead.

  The memory side of this is the same measurement technique (and the
  same finding) that originally motivated bounding `Executor`'s own
  memory to what a query actually needs (see `scry_core`'s own
  `CHANGELOG.md`) -- kept here, against a real embedded database rather
  than a scratch script, as a repeatable regression tool for future
  work, not a one-off proof.

      $ mix scry.bench
      $ mix scry.bench --users 1000000
      $ mix scry.bench --users 1000000 --iterations 10
      $ mix scry.bench --compare-ets
      $ mix scry.bench --yes

  `--users` (default 10,000,000) controls the generated scale; `orders`
  is always twice that. `--iterations` (default 3) controls how many
  *timed* runs each query gets, on top of one untimed warmup run
  (primes the OS-level file-page cache so the first timed iteration
  isn't penalized for a cold-cache disk read the rest won't pay). The
  database is generated fresh into a tmp file on every run (deleted
  again once the run completes) -- regeneration at the default scale
  takes a while; a smaller `--users` trades that for a quicker, less
  realistic run.

  `--compare-ets` additionally generates a comparably-sized `Scry.
  Engine.ETS` dataset (the same rows, loaded into real ETS tables
  during the same generation pass) and runs every query against it
  too. Off by default: it roughly doubles both generation time and
  peak memory (a real ETS-backed copy of the whole dataset, on top of
  the SQLite file), and the concrete problem this task exists to catch
  (a point lookup degrading into a full-table scan) is already fully
  visible from the `raw sql`/`sqlite` numbers alone.

  `Scry.Test.Core.Conn.in_memory/1` is deliberately never part of this
  comparison at benchmark scale -- loading `--users` rows into a plain
  Elixir list is exactly the "read everything into memory and scan it
  by hand" behavior this whole engine-pushdown architecture exists to
  get away from; running it here would just reproduce the original,
  already-diagnosed problem instead of measuring the fix.

  ## Before it runs

  At the default scale this can take several minutes (mostly database
  generation) and uses real CPU/memory/disk while it runs, so this task
  asks for confirmation before doing any of that work -- `--yes` (or
  `-y`) skips the prompt, for scripted/non-interactive use. Once
  confirmed, generation prints its own running progress (rows written
  so far, updated in place) rather than going silent until done, and
  every benchmarked query prints a line as each of its warmup/timed
  runs starts and finishes -- the concrete fix for this task's own
  original failure mode, a run that looked hung with no way to tell it
  apart from one that was just slow. A single call with no count of its
  own to report (a query still running mid-iteration, measuring memory,
  building an index) instead gets a small ASCII spinner (`| / - \`,
  updated in place the same way) -- the same "still alive, not hung"
  signal, for the case `report_progress/2` itself doesn't cover.

  ## What's reported, per query

  - **Rows returned** -- the output row count. A `GROUP BY` query
    returns far fewer rows than it reads; a `LIMIT`-bound point lookup
    returns at most one. Unlike the very first version of this task,
    "rows scanned" is no longer reported: it depended on a
    `:counters`-instrumented ad-hoc engine, an instrumentation hook
    real adapter packages (`Scry.Engine.Exqlite`/`Scry.Engine.ETS`)
    deliberately don't expose (it's benchmark-only surface, not
    something a production adapter should carry) -- duration and
    memory already answer "did the pushdown help" without it.
  - **Duration** -- average, min, median, max, and standard deviation
    across the timed iterations, plus the total across all of them.
  - **Memory** -- the same *immediate* (right after the call returns,
    including not-yet-reclaimed garbage) vs. *settled* (after an
    explicit `:erlang.garbage_collect/0` -- what's actually still
    retained) distinction the memory-only version of this task always
    reported.

  A boxed summary table across every query/backend runs at the end,
  followed by a "Scry overhead" table converting the raw `raw sql` vs.
  `sqlite` durations into a plain "N.NNx" reading per query -- and,
  with `--compare-ets`, a second comparison table for `sqlite` vs.
  `ets` -- then the benchmark's own total wall-clock time (database/
  table generation included).
  """

  use Mix.Task

  @default_users 10_000_000
  @default_iterations 3
  @batch_size 10_000
  @progress_interval 250_000
  @spinner_frames ~w(| / - \\)
  @spinner_interval_ms 120

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {switches, _args} =
      OptionParser.parse!(argv,
        strict: [users: :integer, iterations: :integer, compare_ets: :boolean, yes: :boolean],
        aliases: [y: :yes]
      )

    user_count = switches[:users] || @default_users
    iterations = switches[:iterations] || @default_iterations
    compare_ets? = switches[:compare_ets] || false
    order_count = user_count * 2

    if switches[:yes] || confirm?(user_count, order_count, compare_ets?) do
      run_benchmark(user_count, order_count, iterations, compare_ets?)
    else
      IO.puts("Aborted -- nothing was generated or run.")
    end
  end

  defp confirm?(user_count, order_count, compare_ets?) do
    scale_note = if compare_ets?, do: " (roughly doubled again by --compare-ets)", else: ""

    IO.puts("""

    This will generate #{format_int(user_count)} users / #{format_int(order_count)} orders#{scale_note} \
    in a temporary SQLite database and run several queries against them. At the default scale \
    this can take several minutes and uses real CPU/memory/disk while it runs.
    """)

    case IO.gets("Continue? [y/N] ") do
      answer when is_binary(answer) ->
        String.downcase(String.trim(answer)) in ["y", "yes"]

      _eof_or_error ->
        false
    end
  end

  defp run_benchmark(user_count, order_count, iterations, compare_ets?) do
    mid_id = div(user_count, 2)
    db_path = Path.join(System.tmp_dir!(), "scry_test_core_bench.db")
    File.rm(db_path)

    {run_us, _} =
      :timer.tc(fn ->
        {gen_us, {sqlite_conn, ets_conn}} =
          :timer.tc(fn -> generate(db_path, user_count, order_count, compare_ets?) end)

        IO.puts("\nDatabase ready in #{format_duration(gen_us)}.")

        try do
          IO.puts(
            "\n#{format_int(user_count)} users / #{format_int(order_count)} orders -- " <>
              "#{iterations} timed iterations (+1 untimed warmup) per query/backend, through " <>
              "Scry.Core.Executor.run/4 (or raw SQL, for the \"raw sql\" backend)"
          )

          queries = [
            {"point lookup", "WHERE id = <mid> LIMIT 1 (a real, non-adversarial point lookup)",
             ~s[SELECT users WHERE id = #{mid_id} LIMIT 1 { name }],
             "SELECT name FROM users WHERE id = #{mid_id} LIMIT 1"},
            {"avg(age), no GROUP BY",
             "no LIMIT, flat avg(age) over the whole users table (O(1) groups)",
             "SELECT users { a: avg(age) }", "SELECT AVG(age) FROM users"},
            {"GROUP BY status", "GROUP BY status (3 distinct groups) -- count + avg(age)",
             "SELECT users GROUP BY status { status, n: count(id), a: avg(age) }",
             "SELECT status, COUNT(id), AVG(age) FROM users GROUP BY status"},
            {"GROUP BY user_id",
             "GROUP BY user_id on orders (~#{format_int(user_count)} distinct groups -- " <>
               "adversarial: memory scales with group count, not row count)",
             "SELECT orders GROUP BY user_id { user_id, total: sum(total) }",
             "SELECT user_id, SUM(total) FROM orders GROUP BY user_id"}
          ]

          backends =
            [
              {"raw sql", :raw, sqlite_conn.db},
              {"sqlite", :scry, {Scry.Engine.Exqlite, sqlite_conn}}
            ] ++
              if(compare_ets?, do: [{"ets", :scry, {Scry.Engine.ETS, ets_conn}}], else: [])

          results =
            for {short_label, label, query_text, raw_sql} <- queries,
                {backend_name, kind, target} <- backends do
              fun = query_fun(kind, target, query_text, raw_sql)
              benchmark(label, short_label, backend_name, iterations, fun)
            end

          print_summary_table(results)
          print_comparison_table(results, "raw sql", "sqlite", "Scry overhead (raw SQL vs. Scry)")

          if compare_ets? do
            print_comparison_table(results, "sqlite", "ets", "ETS vs. SQLite (both via Scry)")
          end
        after
          Scry.Engine.Exqlite.Conn.close(sqlite_conn)
        end
      end)

    IO.puts("\nDone in #{format_duration(run_us)} (generation included).")
    File.rm(db_path)
  end

  defp query_fun(:scry, {engine, conn}, query_text, _raw_sql) do
    fn -> run_query(query_text, engine, conn) end
  end

  defp query_fun(:raw, db, _query_text, raw_sql) do
    fn -> run_query_raw(db, raw_sql) end
  end

  defp run_query(query_text, engine, conn) do
    {:ok, query} = Scry.Core.parse(query_text)
    {:ok, cursor} = Scry.Core.Executor.run(query, engine, conn)
    Scry.Core.Cursor.to_list(cursor)
  end

  # Bypasses Scry entirely -- the raw-SQL baseline `sqlite`'s own
  # duration gets compared against, to answer "how much does Scry
  # itself cost on top of the same database". Uses `multi_step/3`
  # (batched), the same primitive `Scry.Engine.Exqlite` itself is
  # built on, so the comparison isolates Scry's own overhead rather
  # than also comparing two different fetching strategies.
  defp run_query_raw(db, sql) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)

    try do
      fetch_all_raw(db, stmt)
    after
      Exqlite.Sqlite3.release(db, stmt)
    end
  end

  defp fetch_all_raw(db, stmt) do
    case Exqlite.Sqlite3.multi_step(db, stmt, 2_000) do
      {:rows, rows} -> rows ++ fetch_all_raw(db, stmt)
      {:done, rows} -> rows
    end
  end

  # ---- Benchmark runner ----------------------------------------------------

  defp benchmark(label, short_label, backend_name, iterations, fun) do
    IO.puts("\nRunning: #{label} [#{backend_name}]")

    {warmup_us, _} = tc_with_spinner("  warmup...", fun)
    IO.puts("\r  warmup... #{format_duration(warmup_us)}")

    timings =
      for i <- 1..iterations do
        {us, rows} = tc_with_spinner("  iteration #{i}/#{iterations}...", fun)
        IO.puts("\r  iteration #{i}/#{iterations}... #{format_duration(us)}")
        {us, rows}
      end

    durations_us = Enum.map(timings, &elem(&1, 0))
    rows = timings |> List.first() |> elem(1)

    mem = measure_memory(fun)
    IO.puts("\r  measuring memory... done")

    result = %{
      query: short_label,
      backend: backend_name,
      label: label,
      iterations: iterations,
      rows_returned: length(rows),
      stats: duration_stats(durations_us),
      mem: mem
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

    run_with_spinner("  measuring memory...", fun)

    immediate = :erlang.memory(:total)
    :erlang.garbage_collect()
    Process.sleep(50)
    settled = :erlang.memory(:total)

    %{immediate_bytes: immediate - before_mem, settled_bytes: settled - before_mem}
  end

  defp print_result(%{
         iterations: iterations,
         rows_returned: rows_returned,
         stats: s,
         mem: m
       }) do
    IO.puts("""
      rows returned: #{format_int(rows_returned)} (#{iterations} timed iterations, +1 untimed warmup)
      duration:      avg #{format_duration(s.avg_us)} (min #{format_duration(s.min_us)}, median #{format_duration(s.median_us)}, max #{format_duration(s.max_us)}, stddev #{format_duration(s.stddev_us)})
                     total #{format_duration(s.total_us)} across all #{iterations} timed iterations
      memory:        immediate #{format_mb(m.immediate_bytes)}, settled after GC #{format_mb(m.settled_bytes)}\
    """)
  end

  # ---- Summary tables (box-drawn) -------------------------------------

  defp print_summary_table(results) do
    columns = [
      {"query", 20, :left},
      {"backend", 8, :left},
      {"rows returned", 13, :right},
      {"avg duration", 12, :right},
      {"settled mem", 12, :right}
    ]

    rows =
      Enum.map(results, fn r ->
        [
          {r.query, 20, :left},
          {r.backend, 8, :left},
          {format_int(r.rows_returned), 13, :right},
          {format_duration(r.stats.avg_us), 12, :right},
          {format_mb(r.mem.settled_bytes), 12, :right}
        ]
      end)

    IO.puts("\nSummary")
    print_box(columns, rows)
  end

  defp print_comparison_table(results, baseline, candidate, title) do
    columns = [
      {"query", 22, :left},
      {baseline, 12, :right},
      {candidate, 12, :right},
      {"result", 20, :right}
    ]

    rows =
      results
      |> Enum.group_by(& &1.query)
      |> Enum.map(fn {query, entries} -> comparison_row(query, entries, baseline, candidate) end)
      |> Enum.reject(&is_nil/1)

    if rows != [] do
      IO.puts("\n#{title}")
      print_box(columns, rows)
    end
  end

  defp comparison_row(query, entries, baseline, candidate) do
    with %{stats: %{avg_us: baseline_us}} <- Enum.find(entries, &(&1.backend == baseline)),
         %{stats: %{avg_us: candidate_us}} <- Enum.find(entries, &(&1.backend == candidate)) do
      {faster, ratio} =
        if baseline_us >= candidate_us,
          do: {candidate, safe_ratio(baseline_us, candidate_us)},
          else: {baseline, safe_ratio(candidate_us, baseline_us)}

      [
        {query, 22, :left},
        {format_duration(baseline_us), 12, :right},
        {format_duration(candidate_us), 12, :right},
        {"#{Float.round(ratio, 2)}x (#{faster})", 20, :right}
      ]
    else
      _ -> nil
    end
  end

  defp safe_ratio(_numerator, 0), do: 0.0
  defp safe_ratio(numerator, denominator), do: numerator / denominator

  defp print_box(columns, rows) do
    IO.puts(box_border(columns, "┌", "┬", "┐"))
    IO.puts(box_row(Enum.map(columns, fn {name, w, align} -> {name, w, align} end)))
    IO.puts(box_border(columns, "├", "┼", "┤"))
    Enum.each(rows, &IO.puts(box_row(&1)))
    IO.puts(box_border(columns, "└", "┴", "┘"))
  end

  defp box_border(columns, left, mid, right) do
    columns
    |> Enum.map(fn {_, w, _} -> String.duplicate("─", w + 2) end)
    |> Enum.join(mid)
    |> then(&(left <> &1 <> right))
  end

  defp box_row(cells) do
    cells
    |> Enum.map(fn
      {text, w, :left} ->
        " " <> (text |> to_string() |> String.slice(0, w) |> String.pad_trailing(w)) <> " "

      {text, w, :right} ->
        " " <> (text |> to_string() |> String.slice(0, w) |> String.pad_leading(w)) <> " "
    end)
    |> Enum.join("│")
    |> then(&("│" <> &1 <> "│"))
  end

  defp format_duration(us) when us >= 1_000_000, do: "#{Float.round(us / 1_000_000, 3)} s"
  defp format_duration(us) when us >= 1_000, do: "#{Float.round(us / 1_000, 2)} ms"
  defp format_duration(us), do: "#{Float.round(us * 1.0, 1)} µs"

  defp format_mb(bytes) do
    mb = bytes / 1_048_576
    sign = if mb >= 0, do: "+", else: ""
    "#{sign}#{Float.round(mb, 2)} MB"
  end

  defp format_int(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  # ---- Generation ------------------------------------------------------

  # Builds the SQLite database (always) and, when `compare_ets?` is
  # true, a comparably-sized `Scry.Engine.ETS.Conn` from the exact same
  # generated rows, in one pass -- batched (`@batch_size` rows at a
  # time via `Stream.chunk_every/2`, never the whole `user_count`/
  # `order_count` materialized as a single Elixir list) so peak memory
  # during generation itself doesn't scale with `--users`. Prints
  # progress as it goes (`report_progress/2`) rather than going silent
  # until done -- this task's own original failure mode.
  defp generate(db_path, user_count, order_count, compare_ets?) do
    {:ok, sqlite_conn} = Scry.Engine.Exqlite.Conn.open(db_path)
    db = sqlite_conn.db

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, status TEXT)
      """)

    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER, total INTEGER)
      """)

    ets_conn =
      if compare_ets? do
        Scry.Engine.ETS.Conn.new(%{}, keys: [{["users"], "id"}, {["orders"], "id"}])
      end

    IO.puts("Generating #{format_int(user_count)} users...")
    ets_conn = gen_users(db, ets_conn, user_count)

    IO.puts("Generating #{format_int(order_count)} orders...")
    ets_conn = gen_orders(db, ets_conn, order_count, user_count)

    :ok =
      run_with_spinner("Creating indexes...", fn ->
        Exqlite.Sqlite3.execute(db, "CREATE INDEX idx_orders_user_id ON orders(user_id)")
      end)

    IO.puts("\rCreating indexes... done.")

    {sqlite_conn, ets_conn}
  end

  defp gen_users(db, ets_conn, count) do
    statuses = ["active", "inactive", "pending"]

    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "INSERT INTO users VALUES (?, ?, ?, ?)")

    ets_conn =
      1..count
      |> Stream.chunk_every(@batch_size)
      |> Enum.reduce(ets_conn, fn chunk, ets_conn ->
        rows =
          Enum.map(chunk, fn i ->
            %{
              "id" => i,
              "name" => "user_#{i}",
              "age" => 18 + rem(i, 65),
              "status" => Enum.at(statuses, rem(i, 3))
            }
          end)

        Enum.each(rows, fn row ->
          :ok = Exqlite.Sqlite3.bind(stmt, [row["id"], row["name"], row["age"], row["status"]])
          :done = Exqlite.Sqlite3.step(db, stmt)
        end)

        report_progress(List.last(chunk), count)
        put_batch(ets_conn, ["users"], rows)
      end)

    IO.write("\n")
    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    Exqlite.Sqlite3.release(db, stmt)
    ets_conn
  end

  defp gen_orders(db, ets_conn, count, user_count) do
    :ok = Exqlite.Sqlite3.execute(db, "BEGIN")
    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "INSERT INTO orders VALUES (?, ?, ?)")

    ets_conn =
      1..count
      |> Stream.chunk_every(@batch_size)
      |> Enum.reduce(ets_conn, fn chunk, ets_conn ->
        rows =
          Enum.map(chunk, fn i ->
            %{"id" => i, "user_id" => 1 + rem(i, user_count), "total" => 10 + rem(i, 490)}
          end)

        Enum.each(rows, fn row ->
          :ok = Exqlite.Sqlite3.bind(stmt, [row["id"], row["user_id"], row["total"]])
          :done = Exqlite.Sqlite3.step(db, stmt)
        end)

        report_progress(List.last(chunk), count)
        put_batch(ets_conn, ["orders"], rows)
      end)

    IO.write("\n")
    :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    Exqlite.Sqlite3.release(db, stmt)
    ets_conn
  end

  # `\r` (carriage return, no newline) repaints the same terminal line
  # instead of scrolling once per batch -- an ordinary progress-bar
  # technique. Always reports the final `done == total` batch
  # regardless of `@progress_interval`, so a table smaller than one
  # interval still shows 100% rather than nothing at all.
  defp report_progress(done, total) do
    if rem(done, @progress_interval) < @batch_size or done == total do
      percent = Float.round(done / total * 100, 1)
      IO.write("\r  #{format_int(done)} / #{format_int(total)} (#{percent}%)")
    end
  end

  defp put_batch(nil, _source, _rows), do: nil
  defp put_batch(ets_conn, source, rows), do: Scry.Engine.ETS.Conn.put(ets_conn, source, rows)

  # `report_progress/2` above is the right tool whenever there's a real
  # count to show (rows generated so far); a single call with no
  # internal progress of its own (running one query, measuring memory,
  # building an index) has nothing to count, so the only honest signal
  # left is "still alive, not hung" -- an ASCII spinner via the same
  # `\r`-repaint technique. Runs `fun` in a separate `Task` purely so
  # this process is free to keep printing while `fun` itself blocks;
  # `fun`'s own result and any crash both propagate normally (a crash
  # re-raises with its original kind/stacktrace via `Task.yield/2`'s
  # own `{:exit, reason}` shape, never silently swallowed).
  defp run_with_spinner(prefix, fun) do
    fun |> Task.async() |> spin(prefix, 0)
  end

  defp spin(task, prefix, frame_index) do
    case Task.yield(task, @spinner_interval_ms) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        exit(reason)

      nil ->
        frame = Enum.at(@spinner_frames, rem(frame_index, length(@spinner_frames)))
        IO.write("\r#{prefix} #{frame}")
        spin(task, prefix, frame_index + 1)
    end
  end

  # Same spinner, `:timer.tc/1`-shaped -- for the two call sites
  # (`benchmark/5`'s own warmup/timed iterations) that need the elapsed
  # time, not just the liveness indicator.
  defp tc_with_spinner(prefix, fun) do
    start = System.monotonic_time()
    result = run_with_spinner(prefix, fun)
    elapsed_us = System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)
    {elapsed_us, result}
  end
end

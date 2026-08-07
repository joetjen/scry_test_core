defmodule Mix.Tasks.Scry.Bench do
  @shortdoc "Benchmarks Scry.Core.Executor's speed and memory against real engines at scale"

  @moduledoc """
  Generates a real SQLite database (`users`/`orders`) and reports real
  timing and memory numbers for `Scry.Core.Executor.run/4` against a
  handful of representative queries -- a point lookup, a flat aggregate
  over the whole table, a low-cardinality `GROUP BY`, and a genuinely
  high-cardinality one -- served through `Scry.Engine.Exqlite`, the
  real adapter package (`fetch/3` `WHERE`-clause pushdown, batched
  `multi_step/3` fetching, a connection opened once and reused across
  every query) rather than an ad-hoc engine module duplicated inside
  this task. The memory side of this is the same measurement technique
  (and the same finding) that originally motivated bounding `Executor`'s
  own memory to what a query actually needs (see `scry_core`'s own
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
  too, printed side by side with the SQLite numbers -- a direct,
  measured comparison between the two real pushdown-capable engines at
  the same scale, not just against each other in the abstract. Off by
  default: it roughly doubles both generation time and peak memory
  (a real ETS-backed copy of the whole dataset, on top of the SQLite
  file), and the concrete problem this task exists to catch (a point
  lookup degrading into a full-table scan) is already fully visible
  from the SQLite numbers alone.

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
  apart from one that was just slow.

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

  A boxed summary table across every query (and backend, with
  `--compare-ets`) runs at the end for an at-a-glance comparison --
  plus, with `--compare-ets`, a second table converting the raw numbers
  into a plain "N.NNx faster" reading per query -- followed by the
  benchmark's own total wall-clock time (database/table generation
  included).
  """

  use Mix.Task

  @default_users 10_000_000
  @default_iterations 3
  @batch_size 10_000
  @progress_interval 250_000

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
          backend_label = if compare_ets?, do: " per query/backend", else: " per query"

          IO.puts(
            "\n#{format_int(user_count)} users / #{format_int(order_count)} orders -- " <>
              "#{iterations} timed iterations (+1 untimed warmup)#{backend_label}, through " <>
              "Scry.Core.Executor.run/4"
          )

          queries = [
            {"point lookup", "WHERE id = <mid> LIMIT 1 (a real, non-adversarial point lookup)",
             ~s[SELECT users WHERE id = #{mid_id} LIMIT 1 { name }]},
            {"avg(age), no GROUP BY",
             "no LIMIT, flat avg(age) over the whole users table (O(1) groups)",
             "SELECT users { a: avg(age) }"},
            {"GROUP BY status", "GROUP BY status (3 distinct groups) -- count + avg(age)",
             "SELECT users GROUP BY status { status, n: count(id), a: avg(age) }"},
            {"GROUP BY user_id",
             "GROUP BY user_id on orders (~#{format_int(user_count)} distinct groups -- " <>
               "adversarial: memory scales with group count, not row count)",
             "SELECT orders GROUP BY user_id { user_id, total: sum(total) }"}
          ]

          backends =
            [{"sqlite", Scry.Engine.Exqlite, sqlite_conn}] ++
              if(compare_ets?, do: [{"ets", Scry.Engine.ETS, ets_conn}], else: [])

          results =
            for {short_label, label, query_text} <- queries,
                {backend_name, engine, conn} <- backends do
              benchmark(label, short_label, backend_name, compare_ets?, iterations, fn ->
                run_query(query_text, engine, conn)
              end)
            end

          print_summary_table(results, compare_ets?)
          if compare_ets?, do: print_speedup_table(results)
        after
          Scry.Engine.Exqlite.Conn.close(sqlite_conn)
        end
      end)

    IO.puts("\nDone in #{format_duration(run_us)} (generation included).")
    File.rm(db_path)
  end

  defp run_query(query_text, engine, conn) do
    {:ok, query} = Scry.Core.parse(query_text)
    {:ok, cursor} = Scry.Core.Executor.run(query, engine, conn)
    Scry.Core.Cursor.to_list(cursor)
  end

  # ---- Benchmark runner ----------------------------------------------------

  defp benchmark(label, short_label, backend_name, compare_ets?, iterations, fun) do
    header = if compare_ets?, do: "#{label} [#{backend_name}]", else: label
    IO.puts("\nRunning: #{header}")

    IO.write("  warmup...")
    {warmup_us, _} = :timer.tc(fun)
    IO.puts(" #{format_duration(warmup_us)}")

    timings =
      for i <- 1..iterations do
        IO.write("  iteration #{i}/#{iterations}...")
        {us, rows} = :timer.tc(fun)
        IO.puts(" #{format_duration(us)}")
        {us, rows}
      end

    durations_us = Enum.map(timings, &elem(&1, 0))
    rows = timings |> List.first() |> elem(1)

    IO.write("  measuring memory...")
    mem = measure_memory(fun)
    IO.puts(" done")

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

    fun.()

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

  defp print_summary_table(results, compare_ets?) do
    columns =
      if compare_ets? do
        [
          {"query", 20, :left},
          {"backend", 8, :left},
          {"rows returned", 13, :right},
          {"avg duration", 12, :right},
          {"settled mem", 12, :right}
        ]
      else
        [
          {"query", 30, :left},
          {"rows returned", 13, :right},
          {"avg duration", 12, :right},
          {"settled mem", 12, :right}
        ]
      end

    rows =
      Enum.map(results, fn r ->
        base = [{r.query, elem(hd(columns), 1), :left}]

        base ++
          if(compare_ets?, do: [{r.backend, 8, :left}], else: []) ++
          [
            {format_int(r.rows_returned), 13, :right},
            {format_duration(r.stats.avg_us), 12, :right},
            {format_mb(r.mem.settled_bytes), 12, :right}
          ]
      end)

    IO.puts("\nSummary")
    print_box(columns, rows)
  end

  defp print_speedup_table(results) do
    columns = [
      {"query", 22, :left},
      {"sqlite avg", 12, :right},
      {"ets avg", 12, :right},
      {"result", 20, :right}
    ]

    rows =
      results
      |> Enum.group_by(& &1.query)
      |> Enum.map(fn {query, entries} -> {query, speedup_row(query, entries, columns)} end)
      |> Enum.reject(fn {_query, row} -> is_nil(row) end)
      |> Enum.map(fn {_query, row} -> row end)

    IO.puts("\nETS vs. SQLite")
    print_box(columns, rows)
  end

  defp speedup_row(query, entries, columns) do
    with %{stats: %{avg_us: sqlite_us}} <- Enum.find(entries, &(&1.backend == "sqlite")),
         %{stats: %{avg_us: ets_us}} <- Enum.find(entries, &(&1.backend == "ets")) do
      {faster, ratio} =
        if sqlite_us >= ets_us,
          do: {"ets", safe_ratio(sqlite_us, ets_us)},
          else: {"sqlite", safe_ratio(ets_us, sqlite_us)}

      [
        {query, elem(Enum.at(columns, 0), 1), :left},
        {format_duration(sqlite_us), 12, :right},
        {format_duration(ets_us), 12, :right},
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
  # progress as it goes (`report_progress/3`) rather than going silent
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

    IO.write("Creating indexes...")
    :ok = Exqlite.Sqlite3.execute(db, "CREATE INDEX idx_orders_user_id ON orders(user_id)")
    IO.puts(" done.")

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
end

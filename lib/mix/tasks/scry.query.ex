defmodule Mix.Tasks.Scry.Query do
  @shortdoc "Runs a Scry query against this package's own seed data"

  @moduledoc """
  Runs a query against `Scry.Test.Core.Conn`'s own prefilled dataset
  (`users`/`products`/`orders`/`order_items`) and prints the resulting
  rows -- for trying the query language out, or spot-checking a
  specific query's own behavior, without writing any Elixir code
  first.

      $ mix scry.query "SELECT users WHERE age > 18 { name }"
      $ mix scry.query --file path/to/query.scry
      $ mix scry.query --backend ets "SELECT users WHERE id = 1 { name }"

  Exactly one of a query-text argument or `--file` is required; giving
  both, or neither, is a usage error. Several positional arguments
  (unquoted query text, split by the shell) are joined back together
  with a single space -- quoting the whole query is still the more
  reliable habit (`{`/`}` and other punctuation can confuse some
  shells when left unquoted), but this covers the simple case too.

  `--backend` picks which `Scry.Test.Core.Conn` constructor serves the
  query -- `in_memory` (the default, `Scry.Engine.InMemory`, no
  pushdown), `ets` (`Scry.Engine.ETS`, real key-lookup pushdown),
  `sqlite` (`Scry.Engine.Exqlite`, real SQL pushdown), or `postgres`
  (`Scry.Engine.Postgrex`, real SQL pushdown against a real, externally
  running Postgres -- `docker compose up -d` first, this package's own
  root `docker-compose.yml`). All four share the exact same seed data
  (`Scry.Test.Core.Seed`), so the same query returns the same rows
  regardless of which one is picked -- this flag changes *how* the
  answer is produced, never *what* it is.

  Always runs against the picked backend's own default seed data --
  there's no flag for supplying different data here; write a short
  `.exs` script (`Scry.Test.Core.Conn.in_memory/1` + `Scry.Core.
  Executor.run/3`, this package's own `README.md` has the shape) for
  anything needing a different dataset.
  """

  use Mix.Task

  @backends %{
    "in_memory" => &Scry.Test.Core.Conn.in_memory/0,
    "ets" => &Scry.Test.Core.Conn.ets/0,
    "sqlite" => &Scry.Test.Core.Conn.sqlite/0,
    "postgres" => &Scry.Test.Core.Conn.postgres/0
  }

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {switches, args} = OptionParser.parse!(argv, strict: [file: :string, backend: :string])

    with {:ok, source} <- fetch_query_source(switches, args),
         {:ok, {engine, conn}} <- fetch_backend(switches),
         {:ok, query} <- Scry.Core.parse(source),
         {:ok, cursor} <- Scry.Core.Executor.run(query, engine, conn),
         {:ok, rows} <- materialize(cursor) do
      IO.inspect(rows, pretty: true, limit: :infinity)
    else
      {:error, reason} -> Mix.raise("scry.query failed: #{format_error(reason)}")
    end
  end

  defp fetch_backend(switches) do
    name = switches[:backend] || "in_memory"

    case Map.fetch(@backends, name) do
      {:ok, constructor} ->
        {:ok, constructor.()}

      :error ->
        {:error, "unknown --backend #{name} (expected in_memory, ets, sqlite, or postgres)"}
    end
  end

  # `Scry.Core.Executor.run/3` returns a lazy `Scry.Core.Cursor.t()` now --
  # this task always wants the full result set, and a lazily-raised
  # `Scry.Core.Executor.QueryError` needs to fold back into the same
  # `{:error, reason}` shape `fetch_query_source/2`/`Scry.Core.parse/1`
  # already use, for one shared error-formatting path below.
  defp materialize(cursor) do
    {:ok, cursor |> Scry.Core.Cursor.to_list() |> Enum.map(&to_plain_row/1)}
  rescue
    e in Scry.Core.Executor.QueryError -> {:error, e.reason}
  end

  # The `sqlite` backend's own direct pushdown path returns `Scry.
  # Core.Row` values now (real, measured cost avoided for a caller
  # that doesn't need every field of every row -- `Scry.Engine.
  # Exqlite`'s own CHANGELOG.md has the full reasoning) -- this task
  # always wants a human-readable result printed, so it converts back
  # to an ordinary map first, exactly the use `Row.to_map/1`'s own
  # moduledoc names ("for tests/debugging, or wherever a real map is
  # genuinely needed").
  defp to_plain_row(%Scry.Core.Row{} = row), do: Scry.Core.Row.to_map(row)
  defp to_plain_row(row), do: row

  # A parse failure is one (or a list of) %Ichor.Error{} -- formatted
  # via its own format/1 (ichor_runtime, a real runtime dependency
  # already) the same way `mix ichor.gen`'s own error path does, rather
  # than dumping the raw struct. Anything else (an execution-time
  # error, e.g. `{:no_such_source, ...}`) falls back to `inspect/1`.
  defp format_error(%Ichor.Error{} = error), do: Ichor.Error.format(error)

  defp format_error(errors) when is_list(errors) do
    Enum.map_join(errors, "\n", fn
      %Ichor.Error{} = error -> Ichor.Error.format(error)
      other -> inspect(other)
    end)
  end

  defp format_error(other), do: inspect(other)

  defp fetch_query_source(switches, args) do
    case {switches[:file], args} do
      {nil, []} ->
        {:error, "give either a query as an argument or --file PATH"}

      {nil, args} ->
        {:ok, Enum.join(args, " ")}

      {path, []} ->
        read_file(path)

      {_path, _args} ->
        {:error, "give either a query as an argument or --file PATH, not both"}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end
end

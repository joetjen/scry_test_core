defmodule Mix.Tasks.Scry.Query do
  @shortdoc "Runs a Scry query against this package's own seed data"

  @moduledoc """
  Runs a query against `ScryTestEngineCore.Conn.seed/0`'s own
  prefilled dataset (`users`/`products`/`orders`/`order_items`) and
  prints the resulting rows -- for trying the query language out, or
  spot-checking a specific query's own behavior, without writing any
  Elixir code first.

      $ mix scry.query "SELECT users WHERE age > 18 { name }"
      $ mix scry.query --file path/to/query.scry

  Exactly one of a query-text argument or `--file` is required; giving
  both, or neither, is a usage error. Several positional arguments
  (unquoted query text, split by the shell) are joined back together
  with a single space -- quoting the whole query is still the more
  reliable habit (`{`/`}` and other punctuation can confuse some
  shells when left unquoted), but this covers the simple case too.

  Always runs against `Conn.seed/0` -- there's no flag for supplying
  different data here; write a short `.exs` script (`Conn.new/1` +
  `ScryCore.Executor.run/3`, this package's own `README.md` has the
  shape) for anything needing a different dataset.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    {switches, args} = OptionParser.parse!(argv, strict: [file: :string])

    with {:ok, source} <- fetch_query_source(switches, args),
         {:ok, query} <- ScryCore.parse(source),
         {:ok, rows} <-
           ScryCore.Executor.run(query, ScryTestEngineCore, ScryTestEngineCore.Conn.seed()) do
      IO.inspect(rows, pretty: true, limit: :infinity)
    else
      {:error, reason} -> Mix.raise("scry.query failed: #{format_error(reason)}")
    end
  end

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

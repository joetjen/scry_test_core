defmodule Mix.Tasks.Scry.Iex do
  @shortdoc "Starts an interactive Scry query prompt against this package's own seed data"

  @moduledoc """
  An interactive, `iex`-like prompt for trying Scry queries against
  `ScryTestEngineCore.Conn.seed/0`'s own prefilled dataset
  (`users`/`products`/`orders`/`order_items`) -- no need to write out
  a full `mix scry.query "..."` invocation per query, or a `.exs`
  script.

      $ mix scry.iex
      scry> SELECT users
      ...>   WHERE age > 18
      ...>   { name }
      [%{"name" => "Alice"}, ...]
      scry>

  A query is only run once it parses -- pressing Enter mid-query (a
  still-incomplete `SELECT ... { ... }`, say) switches the prompt to
  `...>` and keeps accumulating lines rather than erroring immediately,
  the same "don't judge it until it's whole" posture `iex` itself has
  for an unfinished expression.

  One real limitation, worth stating rather than papering over:
  `ScryCore`'s own grammar is a plain backtracking PEG parser (`Ichor`),
  with no incremental/error-recovery parse mode to explain *why* a
  parse failed -- unlike `Code.string_to_quoted/2`'s own dedicated
  `TokenMissingError`, which is exactly how `iex` itself tells "needs
  one more line" apart from "wrong, full stop" (confirmed empirically:
  `ScryCore.parse("SELECT users")` and `ScryCore.parse("NOT A REAL
  QUERY")` return the *identical* positionless `%Ichor.Error{message:
  "input does not match :document"}`, nothing to tell them apart by).
  So this prompt doesn't try to guess -- it never shows a parse error
  while the buffer might still be added to; a blank line forces the
  buffer through as it stands and prints whatever comes back, a real
  result or the real error, then starts over at `scry>`. Ctrl+D (EOF
  on stdin) exits.
  """

  use Mix.Task

  @primary_prompt "scry> "
  @continuation_prompt "...> "

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    loop("")
  end

  defp loop(buffer) do
    prompt = if buffer == "", do: @primary_prompt, else: @continuation_prompt

    case IO.gets(prompt) do
      :eof -> IO.puts("")
      {:error, reason} -> Mix.raise("scry.iex: #{inspect(reason)}")
      line -> handle_line(buffer, String.trim_trailing(line, "\n"))
    end
  end

  defp handle_line(buffer, line) do
    blank? = String.trim(line) == ""

    cond do
      buffer == "" and blank? -> loop("")
      blank? -> attempt(buffer, force: true)
      buffer == "" -> attempt(line, force: false)
      true -> attempt(buffer <> "\n" <> line, force: false)
    end
  end

  defp attempt(buffer, force: force?) do
    case ScryCore.parse(buffer) do
      {:ok, query} ->
        execute(query)
        loop("")

      {:error, reason} when force? ->
        IO.puts(format_error(reason))
        loop("")

      {:error, _reason} ->
        loop(buffer)
    end
  end

  defp execute(query) do
    case ScryCore.Executor.run(query, ScryTestEngineCore, ScryTestEngineCore.Conn.seed()) do
      {:ok, rows} -> IO.inspect(rows, pretty: true, limit: :infinity)
      {:error, reason} -> IO.puts(format_error(reason))
    end
  end

  # Same formatting `mix scry.query` uses -- a parse failure is one (or
  # a list of) %Ichor.Error{}, formatted via its own format/1 rather
  # than a raw struct dump; anything else (an execution-time error)
  # falls back to inspect/1.
  defp format_error(%Ichor.Error{} = error), do: Ichor.Error.format(error)

  defp format_error(errors) when is_list(errors) do
    Enum.map_join(errors, "\n", fn
      %Ichor.Error{} = error -> Ichor.Error.format(error)
      other -> inspect(other)
    end)
  end

  defp format_error(other), do: inspect(other)
end

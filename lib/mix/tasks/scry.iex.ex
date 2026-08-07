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

  **Up/Down arrow history, for real**: run it as `iex -S mix scry.iex`
  instead of plain `mix scry.iex`. Verified directly (a real pty, not
  assumed): the Up/Down/Left/Right line editing and history recall
  every terminal user expects isn't something this task implements --
  it's OTP's own interactive-shell group leader (`group`/`edlin`, the
  exact machinery `iex`'s own expression history already runs on),
  which is only attached to stdin under an actual interactive Erlang
  shell. Plain `mix scry.iex` boots the VM with `-noshell` (no group
  leader, no editing at all -- an arrow key lands as a literal `^[[A`
  escape sequence, confirmed empirically, not guessed), while `iex -S
  mix scry.iex` boots a real `iex` session first (full editing/history
  active) and then runs this task's own loop *inside* it -- an ordinary
  process under that same group leader gets the exact same treatment
  `iex`'s own prompt does, with zero code of this module's own
  involved. Plain `mix scry.iex` prints a one-line note about this at
  startup (gated on `IEx.started?/0` being `false`, so the note itself
  disappears once run the `iex -S mix scry.iex` way); everything else
  about this task works identically either way.

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
    maybe_hint_about_history()
    loop("")
  end

  defp maybe_hint_about_history do
    unless IEx.started?() do
      IO.puts(
        "(no arrow-key history here -- run `iex -S mix scry.iex` instead of `mix scry.iex` for that)"
      )
    end
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
    with {:ok, cursor} <-
           ScryCore.Executor.run(query, ScryTestEngineCore, ScryTestEngineCore.Conn.seed()),
         {:ok, rows} <- materialize(cursor) do
      IO.inspect(rows, pretty: true, limit: :infinity)
    else
      {:error, reason} -> IO.puts(format_error(reason))
    end
  end

  # `ScryCore.Executor.run/3` returns a lazy `ScryCore.Cursor.t()` now --
  # this REPL always wants the full result set printed at once, and a
  # lazily-raised `ScryCore.Executor.QueryError` needs to fold back into
  # the same `{:error, reason}` shape the `with` above already handles.
  defp materialize(cursor) do
    {:ok, ScryCore.Cursor.to_list(cursor)}
  rescue
    e in ScryCore.Executor.QueryError -> {:error, e.reason}
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

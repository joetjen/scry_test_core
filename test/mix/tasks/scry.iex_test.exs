defmodule Mix.Tasks.Scry.IexTest do
  @moduledoc """
  `mix scry.iex` -- a query only runs once it parses, a leading blank
  line at the primary prompt is a no-op, a blank line mid-buffer forces
  a stuck (never-going-to-parse) query through and shows the real
  error instead of hanging forever, the prompt returns to normal
  afterward for the next query, and the `iex -S mix scry.iex` startup
  hint shows under plain `mix test` (no real `iex` session here
  either). `ExUnit.CaptureIO.capture_io/2`'s own `input` argument feeds
  simulated stdin -- `IO.gets/1` sees it exactly as if it were typed,
  `:eof` once it's exhausted. What this suite can't reach at all: real
  Up/Down arrow-key history recall, which needs a genuine pty and
  OTP's own interactive-shell group leader attached to it -- verified
  separately, by hand, against a real pty (not here; `ExUnit.CaptureIO`
  redirects through a `StringIO`, not a tty, so there's no group leader
  for it to attach to regardless of what's fed as input).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "a single-line query executes immediately, no continuation prompt shown" do
    output =
      capture_io(~s(SELECT users WHERE status = "active" { name }\n), fn ->
        Mix.Tasks.Scry.Iex.run([])
      end)

    assert output =~ ~s("name" => "Alice")
    refute output =~ "...> "
  end

  test "a query split across multiple lines only executes once complete" do
    input = "SELECT users\nWHERE age > 18\n{ name }\n"

    output = capture_io(input, fn -> Mix.Tasks.Scry.Iex.run([]) end)

    assert output =~ "...> "
    assert output =~ ~s("name" => "Alice")
  end

  test "a leading blank line at the primary prompt is a no-op, not an error" do
    input = "\n\nSELECT users { name }\n"

    output = capture_io(input, fn -> Mix.Tasks.Scry.Iex.run([]) end)

    assert output =~ ~s("name" => "Alice")
  end

  test "a query that will never parse sits accumulating until a blank line forces it, then shows the real error and resets" do
    input = "NOT A REAL QUERY\n\nSELECT users { name }\n"

    output = capture_io(input, fn -> Mix.Tasks.Scry.Iex.run([]) end)

    assert output =~ "does not match"
    refute output =~ "%Ichor.Error{"
    assert output =~ ~s("name" => "Alice")
  end

  test "EOF on stdin (Ctrl+D) exits cleanly, no crash" do
    output = capture_io("", fn -> Mix.Tasks.Scry.Iex.run([]) end)

    assert output =~ "scry> "
  end

  test "outside a real iex session, a startup note points at `iex -S mix scry.iex` for history" do
    refute IEx.started?()
    output = capture_io("", fn -> Mix.Tasks.Scry.Iex.run([]) end)

    assert output =~ "iex -S mix scry.iex"
  end

  test "--backend ets serves the same seed data as the default in_memory backend" do
    output =
      capture_io(~s(SELECT users WHERE id = 1 { name }\n), fn ->
        Mix.Tasks.Scry.Iex.run(["--backend", "ets"])
      end)

    assert output =~ ~s("name" => "Alice")
  end

  test "an unknown --backend is a clear usage error, before the prompt ever starts" do
    assert_raise Mix.Error, ~r/unknown --backend bogus/, fn ->
      capture_io(fn -> Mix.Tasks.Scry.Iex.run(["--backend", "bogus"]) end)
    end
  end
end

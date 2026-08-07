defmodule Mix.Tasks.Scry.IexTest do
  @moduledoc """
  `mix scry.iex` -- a query only runs once it parses, a leading blank
  line at the primary prompt is a no-op, a blank line mid-buffer forces
  a stuck (never-going-to-parse) query through and shows the real
  error instead of hanging forever, and the prompt returns to normal
  afterward for the next query. `ExUnit.CaptureIO.capture_io/2`'s own
  `input` argument feeds simulated stdin -- `IO.gets/1` sees it exactly
  as if it were typed, `:eof` once it's exhausted.
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
end

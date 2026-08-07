defmodule Mix.Tasks.Scry.QueryTest do
  @moduledoc """
  `mix scry.query` -- both ways of supplying a query (an argument, a
  `--file`), both usage errors (neither given, both given), and a
  parse error's own formatting (`Ichor.Error.format/1`, not a raw
  struct dump).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "a query argument, run against Conn.seed/0, prints the resulting rows" do
    output =
      capture_io(fn ->
        Mix.Tasks.Scry.Query.run([~s(SELECT users WHERE status = "active" { name })])
      end)

    assert output =~ ~s("name" => "Alice")
    assert output =~ ~s("name" => "Bob")
    assert output =~ ~s("name" => "Dave")
    refute output =~ ~s("name" => "Carol")
  end

  test "several unquoted positional args are joined back into one query" do
    output =
      capture_io(fn ->
        Mix.Tasks.Scry.Query.run(["SELECT", "users", "{", "name", "}"])
      end)

    assert output =~ ~s("name" => "Alice")
  end

  test "--file reads the query from disk" do
    path =
      Path.join(System.tmp_dir!(), "scry_query_test_#{System.unique_integer([:positive])}.scry")

    File.write!(path, ~s(SELECT products WHERE category = "electronics" { name }))

    try do
      output = capture_io(fn -> Mix.Tasks.Scry.Query.run(["--file", path]) end)

      assert output =~ ~s("name" => "Gizmo")
      assert output =~ ~s("name" => "Thingamajig")
    after
      File.rm(path)
    end
  end

  test "neither a query nor --file is a clear usage error" do
    assert_raise Mix.Error, ~r/give either a query as an argument or --file PATH/, fn ->
      capture_io(fn -> Mix.Tasks.Scry.Query.run([]) end)
    end
  end

  test "both a query and --file is a clear usage error" do
    assert_raise Mix.Error, ~r/not both/, fn ->
      capture_io(fn -> Mix.Tasks.Scry.Query.run(["SELECT users { name }", "--file", "x"]) end)
    end
  end

  test "a parse error is formatted via Ichor.Error.format/1, not a raw struct dump" do
    assert_raise Mix.Error, ~r/^scry\.query failed: (?!%Ichor\.Error)/, fn ->
      capture_io(fn -> Mix.Tasks.Scry.Query.run(["NOT A REAL QUERY"]) end)
    end
  end
end

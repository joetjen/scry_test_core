defmodule Scry.Test.Core.ConnTest do
  @moduledoc """
  `Scry.Test.Core.Conn` -- confirms each of the three constructors
  (`in_memory/1`, `ets/1`, `sqlite/1`) returns a real, working
  `{engine_module, conn}` pair: prefilled with `Scry.Test.Core.Seed`'s
  own dataset by default, still accepting custom data the same way the
  old single-engine `Conn.new/1` used to, and actually executing a
  query correctly through `Scry.Core.Executor.run/4` -- not just
  returning a plausible-looking struct. Cross-backend agreement (the
  same query, the same result, across all three) is `parity_test.exs`'s
  own job, not this file's.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.{Cursor, Executor}
  alias Scry.Test.Core.{Conn, Seed}

  defp materialize({:ok, cursor}), do: {:ok, Cursor.to_list(cursor)}
  defp materialize({:error, _} = err), do: err

  @custom_data %{
    ["users"] => [
      %{"id" => 1, "name" => "Alice", "age" => 30},
      %{"id" => 2, "name" => "Bob", "age" => 17}
    ]
  }

  for {constructor, label} <- [
        in_memory: "Scry.Engine.InMemory",
        ets: "Scry.Engine.ETS",
        sqlite: "Scry.Engine.Exqlite"
      ] do
    describe "#{constructor}/1 (#{label})" do
      test "defaults to Scry.Test.Core.Seed's own dataset" do
        {engine, conn} = apply(Conn, unquote(constructor), [])

        {:ok, query} = Scry.Core.parse(~s(SELECT users { name }))
        assert {:ok, rows} = Executor.run(query, engine, conn) |> materialize()
        assert length(rows) == length(Seed.users())
      end

      test "accepts custom data instead of the default seed" do
        {engine, conn} = apply(Conn, unquote(constructor), [@custom_data])

        {:ok, query} = Scry.Core.parse(~s(SELECT users WHERE age > 18 { name }))
        assert {:ok, rows} = Executor.run(query, engine, conn) |> materialize()
        assert rows == [%{"name" => "Alice"}]
      end

      test "an unknown source is a clear error, not a crash" do
        {engine, conn} = apply(Conn, unquote(constructor), [@custom_data])

        {:ok, query} = Scry.Core.parse(~s(SELECT nonexistent { name }))

        # Every engine reports a genuine failure as {:query_error, detail}
        # (Scry.Core.EngineBehaviour's own two-constructor error() shape) --
        # `detail` itself isn't part of that contract, so it varies: a
        # synthesized {:no_such_source, source} tuple for in_memory/ets,
        # SQLite's own raw driver error string for sqlite.
        assert {:error, {:query_error, _detail}} = Executor.run(query, engine, conn)
      end
    end
  end
end

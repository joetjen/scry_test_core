defmodule Scry.Test.Core.TimescaledbConnTest do
  @moduledoc """
  `Scry.Test.Core.Conn.timescaledb/1` -- confirms it returns a real,
  working `{Scry.Engine.Postgrex, conn}` pair (prefilled with `Scry.
  Test.Core.Seed`'s own dataset by default, still accepting custom
  data, actually executing a query correctly through `Scry.Core.
  Executor.run/4`), the same shape `postgres_conn_test.exs` already
  proves for `postgres/1` -- against a real TimescaleDB instead of
  plain Postgres, with `Scry.Engine.Postgrex` itself entirely
  unmodified. Kept in a **separate**, `@moduletag :timescaledb` file
  for the same reasons `postgres_conn_test.exs`'s own moduledoc
  explains (a real, externally-running TimescaleDB requirement excluded
  by default; `async: false` since `timescaledb/1` targets the same
  fixed tables on every call).

  Plus the same idempotency case `postgres_conn_test.exs` proves for
  `postgres/1`: calling `timescaledb/1` twice in a row produces
  identical, correct results.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.{Cursor, Executor, Row}
  alias Scry.Test.Core.{Conn, Seed}

  @moduletag :timescaledb

  defp materialize({:ok, cursor}), do: {:ok, cursor |> Cursor.to_list() |> Enum.map(&to_plain/1)}
  defp materialize({:error, _} = err), do: err

  defp to_plain(%Row{} = row), do: Row.to_map(row)
  defp to_plain(row), do: row

  @custom_data %{
    ["users"] => [
      %{"id" => 1, "name" => "Alice", "age" => 30},
      %{"id" => 2, "name" => "Bob", "age" => 17}
    ]
  }

  describe "timescaledb/1 (Scry.Engine.Postgrex against real TimescaleDB)" do
    test "defaults to Scry.Test.Core.Seed's own dataset" do
      {engine, conn} = Conn.timescaledb()

      {:ok, query} = Scry.Core.parse(~s(SELECT users { name }))
      assert {:ok, rows} = Executor.run(query, engine, conn) |> materialize()
      assert length(rows) == length(Seed.users())
    end

    test "accepts custom data instead of the default seed" do
      {engine, conn} = Conn.timescaledb(@custom_data)

      {:ok, query} = Scry.Core.parse(~s(SELECT users WHERE age > 18 { name }))
      assert {:ok, rows} = Executor.run(query, engine, conn) |> materialize()
      assert rows == [%{"name" => "Alice"}]
    end

    test "an unknown source is a clear error, not a crash" do
      {engine, conn} = Conn.timescaledb(@custom_data)

      {:ok, query} = Scry.Core.parse(~s(SELECT nonexistent { name }))
      assert {:error, {:query_error, _detail}} = Executor.run(query, engine, conn)
    end

    test "rows genuinely come back as Scry.Core.Row values for a flat query" do
      {engine, conn} = Conn.timescaledb(@custom_data)

      {:ok, query} = Scry.Core.parse(~s(SELECT users WHERE age > 18 { name }))
      assert {:ok, cursor} = Executor.run(query, engine, conn)
      assert [%Row{} = row] = Cursor.to_list(cursor)
      assert Row.to_map(row) == %{"name" => "Alice"}
    end

    test "calling it twice in a row is idempotent -- produces identical, correct results" do
      {engine1, conn1} = Conn.timescaledb(@custom_data)
      {engine2, conn2} = Conn.timescaledb(@custom_data)

      {:ok, query} = Scry.Core.parse(~s(SELECT users { name, age }))

      assert {:ok, rows1} = Executor.run(query, engine1, conn1) |> materialize()
      assert {:ok, rows2} = Executor.run(query, engine2, conn2) |> materialize()

      assert Enum.sort_by(rows1, & &1["name"]) == Enum.sort_by(rows2, & &1["name"])

      assert Enum.sort_by(rows1, & &1["name"]) == [
               %{"name" => "Alice", "age" => 30},
               %{"name" => "Bob", "age" => 17}
             ]
    end
  end
end

defmodule Scry.Test.Core.TimescaledbParityTest do
  @moduledoc """
  `Scry.Test.Core.Conn.timescaledb/1`'s own cross-engine parity
  coverage, kept **separate** from `parity_test.exs`'s existing 3-way
  comparison for the same two reasons `postgres_parity_test.exs`
  already documents (`@moduletag :timescaledb`, excluded by default,
  needing a real, externally-running TimescaleDB; `async: false`,
  since `timescaledb/1` targets the same fixed, `public`-schema tables
  on every call).

  This file's own real point isn't a third pushdown implementation to
  verify -- `timescaledb/1` runs through `Scry.Engine.Postgrex`, the
  exact same module `postgres/1` uses, entirely unmodified. It's the
  empirical proof of `Scry.Test.Core.Conn`'s own moduledoc claim: that
  a dedicated `scry_engine_timescaledb` adapter has nothing unique to
  do today, because TimescaleDB speaks the plain Postgres wire protocol
  and the language has no time-bucketing/hypertable construct yet to
  compile specially. The same four representative queries `parity_test.exs`/
  `postgres_parity_test.exs` already cover, each asserting `Conn.
  timescaledb()`'s own result matches `Conn.in_memory()`'s (the implicit
  oracle -- no pushdown at all, correct by construction) after sorting.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.{Cursor, Executor, Row}
  alias Scry.Test.Core.Conn

  import Scry.Core.Query

  @moduletag :timescaledb

  defp materialize({:ok, cursor}), do: {:ok, cursor |> Cursor.to_list() |> Enum.map(&to_plain/1)}

  defp to_plain(%Row{} = row), do: Row.to_map(row)
  defp to_plain(row), do: row

  defp assert_timescaledb_parity(query, sort_key) do
    {in_memory_engine, in_memory_conn} = Conn.in_memory()
    {timescaledb_engine, timescaledb_conn} = Conn.timescaledb()

    assert {:ok, reference_rows} =
             Executor.run(query, in_memory_engine, in_memory_conn) |> materialize()

    assert {:ok, timescaledb_rows} =
             Executor.run(query, timescaledb_engine, timescaledb_conn) |> materialize()

    sorted_reference = Enum.sort_by(reference_rows, sort_key)
    sorted_timescaledb = Enum.sort_by(timescaledb_rows, sort_key)
    assert sorted_timescaledb == sorted_reference
    sorted_timescaledb
  end

  test "a key-equality filter -- the shape Scry.Engine.ETS's own fetch/3 optimizes" do
    {:ok, query} = Scry.Core.parse(~s(SELECT users WHERE id = 2 { name, age }))

    assert assert_timescaledb_parity(query, & &1["name"]) == [%{"name" => "Bob", "age" => 24}]
  end

  test "a non-key filter -- both pushdown engines fall back to a full scan here" do
    {:ok, query} = Scry.Core.parse(~s(SELECT users WHERE status = "active" { name }))

    assert assert_timescaledb_parity(query, & &1["name"]) == [
             %{"name" => "Alice"},
             %{"name" => "Bob"},
             %{"name" => "Dave"}
           ]
  end

  test "GROUP BY + an aggregate over order_items" do
    query =
      from(oi in "order_items",
        group_by: [oi.product_id],
        select: %{product_id: oi.product_id, total_qty: sum(oi.quantity)}
      )

    assert assert_timescaledb_parity(query, & &1["product_id"]) == [
             %{"product_id" => 1, "total_qty" => 10},
             %{"product_id" => 2, "total_qty" => 3},
             %{"product_id" => 3, "total_qty" => 3},
             %{"product_id" => 4, "total_qty" => 14},
             %{"product_id" => 5, "total_qty" => 3}
           ]
  end

  test "a nested SELECT correlating users to their own shipped orders" do
    {:ok, query} =
      Scry.Core.parse(~s"""
      SELECT users { name, SELECT orders WHERE user_id = users.id AND status = "shipped" { id } }
      """)

    assert assert_timescaledb_parity(query, & &1["name"]) == [
             %{"name" => "Alice", "orders" => [%{"id" => 1}]},
             %{"name" => "Bob", "orders" => [%{"id" => 3}]},
             %{"name" => "Carol", "orders" => []},
             %{"name" => "Dave", "orders" => [%{"id" => 5}]},
             %{"name" => "Erin", "orders" => [%{"id" => 7}]}
           ]
  end
end

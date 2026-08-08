defmodule Scry.Test.Core.ParityTest do
  @moduledoc """
  The genuine, automated proof the whole pushdown design rests on: the
  same query, run against all three `Scry.Test.Core.Conn` backends
  (`in_memory/0` -- no pushdown at all, always correct by construction;
  `ets/0` -- real O(1) key-lookup pushdown; `sqlite/0` -- real SQL
  `WHERE`-clause pushdown), produces *exactly* the same rows. Not "the
  same shape" or "the same count" -- byte-identical result lists,
  confirming `Scry.Core.Executor`'s own re-verification is what
  actually guarantees correctness regardless of how much (or how
  little) an engine optimized, exactly `Scry.Core.EngineBehaviour`'s
  own safety-invariant reasoning, checked here empirically rather than
  just asserted in prose.

  Covers a key-equality filter (the one shape `Scry.Engine.ETS`'s own
  `fetch/3` actually optimizes), a non-key filter (both pushdown
  engines fall back to a full scan here), `GROUP BY` + an aggregate,
  and a nested/correlated `SELECT` -- the same representative spread
  `seed_test.exs` already covers for the in-memory backend alone, now
  cross-checked against the other two.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.{Cursor, Executor, Row}
  alias Scry.Test.Core.Conn

  import Scry.Core.Query

  defp materialize({:ok, cursor}), do: {:ok, cursor |> Cursor.to_list() |> Enum.map(&to_plain/1)}

  defp to_plain(%Row{} = row), do: Row.to_map(row)
  defp to_plain(row), do: row

  # `sort_key` puts every backend's own rows into the same deterministic
  # order before comparing -- necessary, not cosmetic: none of these
  # queries has a real `ORDER BY`, and `:ets.tab2list/1`'s own row order
  # for a `:set` table is not guaranteed to match either a plain list's
  # or SQLite's own row order. Sorting by a stable field the rows
  # actually carry (never by `inspect/1`, whose own map-key ordering
  # isn't a documented guarantee either) is what makes "same rows,
  # different engine" a meaningful, order-independent comparison.
  defp assert_parity(query, sort_key) do
    results =
      for {engine, conn} <- [Conn.in_memory(), Conn.ets(), Conn.sqlite()] do
        assert {:ok, rows} = Executor.run(query, engine, conn) |> materialize()
        Enum.sort_by(rows, sort_key)
      end

    [first | rest] = results
    Enum.each(rest, &assert(&1 == first))
    first
  end

  test "a key-equality filter -- the shape Scry.Engine.ETS's own fetch/3 optimizes" do
    {:ok, query} = Scry.Core.parse(~s(SELECT users WHERE id = 2 { name, age }))

    assert assert_parity(query, & &1["name"]) == [%{"name" => "Bob", "age" => 24}]
  end

  test "a non-key filter -- both pushdown engines fall back to a full scan here" do
    {:ok, query} = Scry.Core.parse(~s(SELECT users WHERE status = "active" { name }))

    assert assert_parity(query, & &1["name"]) == [
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

    assert assert_parity(query, & &1["product_id"]) == [
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

    assert assert_parity(query, & &1["name"]) == [
             %{"name" => "Alice", "orders" => [%{"id" => 1}]},
             %{"name" => "Bob", "orders" => [%{"id" => 3}]},
             %{"name" => "Carol", "orders" => []},
             %{"name" => "Dave", "orders" => [%{"id" => 5}]},
             %{"name" => "Erin", "orders" => [%{"id" => 7}]}
           ]
  end
end

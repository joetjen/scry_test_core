defmodule ScryTestEngineCore.SeedTest do
  @moduledoc """
  `ScryTestEngineCore.Conn.seed/0` -- confirms the prefilled dataset
  (`ScryTestEngineCore.Seed`) is real, queryable data with real
  relationships to correlate across, not just present-but-inert fixture
  rows. Covers a plain filter, `GROUP BY`/an aggregate, and,
  specifically, a nested `SELECT` correlating across two of the
  dataset's own foreign-key-related tables -- both through query text
  and through the native builder (`ScryCore.Query.from/2`), confirming
  both front ends see the same relationships in the same data.
  """

  use ExUnit.Case, async: true

  alias ScryTestEngineCore.{Conn, Seed}

  import ScryCore.Query

  setup do
    %{conn: Conn.seed()}
  end

  test "seed/0 is prefilled -- no data has to be supplied to get real rows back", %{conn: conn} do
    assert {:ok, query} = ScryCore.parse(~s(SELECT users { name }))
    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)
    assert length(rows) == length(Seed.users())
  end

  test "a plain WHERE filter over the seed users", %{conn: conn} do
    assert {:ok, query} = ScryCore.parse(~s(SELECT users WHERE status = "active" { name }))
    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)
    assert rows == [%{"name" => "Alice"}, %{"name" => "Bob"}, %{"name" => "Dave"}]
  end

  test "GROUP BY + an aggregate over order_items, real quantities summed per product", %{
    conn: conn
  } do
    query =
      from(oi in "order_items",
        group_by: [oi.product_id],
        select: %{product_id: oi.product_id, total_qty: sum(oi.quantity)}
      )

    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)

    assert Enum.sort_by(rows, & &1["product_id"]) == [
             %{"product_id" => 1, "total_qty" => 10},
             %{"product_id" => 2, "total_qty" => 3},
             %{"product_id" => 3, "total_qty" => 3},
             %{"product_id" => 4, "total_qty" => 14},
             %{"product_id" => 5, "total_qty" => 3}
           ]
  end

  test "a nested SELECT correlating users to their own shipped orders, via query text", %{
    conn: conn
  } do
    assert {:ok, query} =
             ScryCore.parse(~s"""
             SELECT users { name, SELECT orders WHERE user_id = users.id AND status = "shipped" { id } }
             """)

    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)

    assert rows == [
             %{"name" => "Alice", "orders" => [%{"id" => 1}]},
             %{"name" => "Bob", "orders" => [%{"id" => 3}]},
             %{"name" => "Carol", "orders" => []},
             %{"name" => "Dave", "orders" => [%{"id" => 5}]},
             %{"name" => "Erin", "orders" => [%{"id" => 7}]}
           ]
  end

  test "the same nested correlation via the native builder (ScryCore.Query.from/2)", %{
    conn: conn
  } do
    query =
      from(u in "users",
        select: %{
          name: u.name,
          orders:
            from(o in "orders",
              where: o.user_id == u.id and o.status == "shipped",
              select: %{id: o.id}
            )
        }
      )

    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)

    assert rows == [
             %{"name" => "Alice", "orders" => [%{"id" => 1}]},
             %{"name" => "Bob", "orders" => [%{"id" => 3}]},
             %{"name" => "Carol", "orders" => []},
             %{"name" => "Dave", "orders" => [%{"id" => 5}]},
             %{"name" => "Erin", "orders" => [%{"id" => 7}]}
           ]
  end

  test "two levels of nesting -- orders, and each order's own items", %{conn: conn} do
    query =
      from(o in "orders",
        where: o.id == 1,
        select: %{
          id: o.id,
          order_items:
            from(oi in "order_items",
              where: oi.order_id == o.id,
              select: %{product_id: oi.product_id, quantity: oi.quantity}
            )
        }
      )

    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)

    assert rows == [
             %{
               "id" => 1,
               "order_items" => [
                 %{"product_id" => 1, "quantity" => 3},
                 %{"product_id" => 3, "quantity" => 1}
               ]
             }
           ]
  end

  test "new/1 is unaffected -- still empty by default, custom data still works exactly as before" do
    assert Conn.new().data == %{}
    assert Conn.new(%{["x"] => [%{"a" => 1}]}).data == %{["x"] => [%{"a" => 1}]}
  end
end

defmodule Scry.Test.Core.Seed do
  @moduledoc """
  A reasonably large, realistic, multi-table relational dataset --
  `users`/`products`/`orders`/`order_items`, with real foreign-key-
  shaped references between them (`orders.user_id` → a `users.id`,
  `order_items.order_id`/`order_items.product_id` → an `orders.id`/
  `products.id`) -- for exercising `WHERE`/`GROUP BY`/aggregates and,
  especially, nested `SELECT`/correlation (lang_spec.md §6) against
  something with real relationships to correlate across, not just a
  handful of flat rows. `Scry.Test.Core.Conn`'s own `in_memory/1`,
  `ets/1`, and `sqlite/1` all load this same dataset by default -- one
  shared seed across all three backends, so a query run against each
  is a genuine apples-to-apples comparison, not three different
  fixtures that happen to look similar. This module exists on its own
  so the raw data is independently reusable (a test wanting only
  `users`, say, without the rest) without needing a whole `Conn` for
  it.

  Not randomly generated and not trying to be exhaustive -- a fixed,
  hand-authored dataset, small enough to reason about in a test's own
  assertions (7 orders, 12 order items) while still being large enough
  that `WHERE`/`GROUP BY` filtering actually filters something and a
  correlated nested `SELECT` has more than one row to find on each
  side.
  """

  alias Scry.Core.EngineBehaviour

  @users [
    %{
      "id" => 1,
      "name" => "Alice",
      "email" => "alice@example.com",
      "age" => 30,
      "status" => "active"
    },
    %{
      "id" => 2,
      "name" => "Bob",
      "email" => "bob@example.com",
      "age" => 24,
      "status" => "active"
    },
    %{
      "id" => 3,
      "name" => "Carol",
      "email" => "carol@example.com",
      "age" => 45,
      "status" => "inactive"
    },
    %{
      "id" => 4,
      "name" => "Dave",
      "email" => "dave@example.com",
      "age" => 19,
      "status" => "active"
    },
    %{
      "id" => 5,
      "name" => "Erin",
      "email" => "erin@example.com",
      "age" => 52,
      "status" => "inactive"
    }
  ]

  @products [
    %{"id" => 1, "name" => "Widget", "price" => 9.99, "category" => "hardware"},
    %{"id" => 2, "name" => "Gadget", "price" => 19.99, "category" => "hardware"},
    %{"id" => 3, "name" => "Gizmo", "price" => 29.99, "category" => "electronics"},
    %{"id" => 4, "name" => "Doohickey", "price" => 4.99, "category" => "hardware"},
    %{"id" => 5, "name" => "Thingamajig", "price" => 49.99, "category" => "electronics"}
  ]

  @orders [
    %{"id" => 1, "user_id" => 1, "status" => "shipped", "placed_at" => "2026-01-05"},
    %{"id" => 2, "user_id" => 1, "status" => "pending", "placed_at" => "2026-02-10"},
    %{"id" => 3, "user_id" => 2, "status" => "shipped", "placed_at" => "2026-01-20"},
    %{"id" => 4, "user_id" => 3, "status" => "cancelled", "placed_at" => "2026-01-15"},
    %{"id" => 5, "user_id" => 4, "status" => "shipped", "placed_at" => "2026-02-01"},
    %{"id" => 6, "user_id" => 4, "status" => "pending", "placed_at" => "2026-02-20"},
    %{"id" => 7, "user_id" => 5, "status" => "shipped", "placed_at" => "2026-01-30"}
  ]

  @order_items [
    %{"id" => 1, "order_id" => 1, "product_id" => 1, "quantity" => 3},
    %{"id" => 2, "order_id" => 1, "product_id" => 3, "quantity" => 1},
    %{"id" => 3, "order_id" => 2, "product_id" => 2, "quantity" => 2},
    %{"id" => 4, "order_id" => 3, "product_id" => 1, "quantity" => 5},
    %{"id" => 5, "order_id" => 3, "product_id" => 4, "quantity" => 10},
    %{"id" => 6, "order_id" => 4, "product_id" => 5, "quantity" => 1},
    %{"id" => 7, "order_id" => 5, "product_id" => 2, "quantity" => 1},
    %{"id" => 8, "order_id" => 5, "product_id" => 3, "quantity" => 2},
    %{"id" => 9, "order_id" => 6, "product_id" => 1, "quantity" => 1},
    %{"id" => 10, "order_id" => 6, "product_id" => 4, "quantity" => 4},
    %{"id" => 11, "order_id" => 7, "product_id" => 5, "quantity" => 2},
    %{"id" => 12, "order_id" => 7, "product_id" => 1, "quantity" => 1}
  ]

  @doc "The full seed dataset, in `Scry.Test.Core.Conn.data()`'s own `%{source_path => rows}` shape."
  @spec data() :: %{optional([String.t()]) => [EngineBehaviour.row()]}
  def data do
    %{
      ["users"] => @users,
      ["products"] => @products,
      ["orders"] => @orders,
      ["order_items"] => @order_items
    }
  end

  @doc "Just the `users` rows -- for a test that wants a single table without the rest."
  @spec users() :: [EngineBehaviour.row()]
  def users, do: @users

  @doc "Just the `products` rows."
  @spec products() :: [EngineBehaviour.row()]
  def products, do: @products

  @doc "Just the `orders` rows -- each one's own `user_id` references a real `users` row above."
  @spec orders() :: [EngineBehaviour.row()]
  def orders, do: @orders

  @doc """
  Just the `order_items` rows -- each one's own `order_id`/`product_id`
  reference a real `orders`/`products` row above.
  """
  @spec order_items() :: [EngineBehaviour.row()]
  def order_items, do: @order_items

  @doc """
  One `{source, key_field}` pair per table -- every table here happens
  to have a real, unique `id` column, so this is what `Scry.Test.Core.
  Conn.ets/1` passes straight through to `Scry.Engine.ETS.Conn.new/2`'s
  own `keys:` option.
  """
  @spec keys() :: [{[String.t()], String.t()}]
  def keys do
    [
      {["users"], "id"},
      {["products"], "id"},
      {["orders"], "id"},
      {["order_items"], "id"}
    ]
  end
end

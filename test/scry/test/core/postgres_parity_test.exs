defmodule Scry.Test.Core.PostgresParityTest do
  @moduledoc """
  `Scry.Test.Core.Conn.postgres/1`'s own cross-engine parity coverage,
  kept **separate** from `parity_test.exs`'s existing 3-way comparison
  (`in_memory`/`ets`/`sqlite`) rather than folding a fourth backend
  into that file's own `assert_parity/2` loop, for two real reasons:

  1. **`@moduletag :postgres`, excluded by default** (`test/
     test_helper.exs`) -- `postgres/1` is the first `Scry.Test.Core.Conn`
     constructor needing a real, externally-running Postgres (`docker
     compose up -d`, this package's own root `docker-compose.yml`, then
     `mix test.postgres`). Retrofitting it into `parity_test.exs`'s own
     untagged `for {engine, conn} <- [...]` loop would make the *entire*
     existing suite require Docker by default -- a real regression for
     anyone who merely depends on this package for the other three
     backends. This file alone carries that requirement.
  2. **`async: false`** -- `postgres/1` targets the same fixed,
     `public`-schema tables on every call (idempotent via `DROP TABLE
     IF EXISTS ... CASCADE` + recreate, not per-call-isolated the way
     the other three constructors are automatically -- `Scry.Test.Core.
     Conn`'s own moduledoc has the full reasoning). Running these tests
     concurrently with each other would race the same physical tables.

  The same four representative queries `parity_test.exs` already covers
  (key-equality filter, non-key filter, `GROUP BY` + aggregate, a
  correlated nested `SELECT`), each asserting `Conn.postgres()`'s own
  result matches `Conn.in_memory()`'s (that file's own implicit
  oracle -- no pushdown at all, correct by construction) after sorting.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.{Cursor, Executor, Row}
  alias Scry.Test.Core.Conn

  import Scry.Core.Query

  @moduletag :postgres

  defp materialize({:ok, cursor}), do: {:ok, cursor |> Cursor.to_list() |> Enum.map(&to_plain/1)}

  defp to_plain(%Row{} = row), do: Row.to_map(row)
  defp to_plain(row), do: row

  defp assert_postgres_parity(query, sort_key) do
    {in_memory_engine, in_memory_conn} = Conn.in_memory()
    {postgres_engine, postgres_conn} = Conn.postgres()

    assert {:ok, reference_rows} =
             Executor.run(query, in_memory_engine, in_memory_conn) |> materialize()

    assert {:ok, postgres_rows} =
             Executor.run(query, postgres_engine, postgres_conn) |> materialize()

    sorted_reference = Enum.sort_by(reference_rows, sort_key)
    sorted_postgres = Enum.sort_by(postgres_rows, sort_key)
    assert sorted_postgres == sorted_reference
    sorted_postgres
  end

  test "a key-equality filter -- the shape Scry.Engine.ETS's own fetch/3 optimizes" do
    {:ok, query} = Scry.Core.parse(~s(SELECT users WHERE id = 2 { name, age }))

    assert assert_postgres_parity(query, & &1["name"]) == [%{"name" => "Bob", "age" => 24}]
  end

  test "a non-key filter -- both pushdown engines fall back to a full scan here" do
    {:ok, query} = Scry.Core.parse(~s(SELECT users WHERE status = "active" { name }))

    assert assert_postgres_parity(query, & &1["name"]) == [
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

    assert assert_postgres_parity(query, & &1["product_id"]) == [
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

    assert assert_postgres_parity(query, & &1["name"]) == [
             %{"name" => "Alice", "orders" => [%{"id" => 1}]},
             %{"name" => "Bob", "orders" => [%{"id" => 3}]},
             %{"name" => "Carol", "orders" => []},
             %{"name" => "Dave", "orders" => [%{"id" => 5}]},
             %{"name" => "Erin", "orders" => [%{"id" => 7}]}
           ]
  end
end

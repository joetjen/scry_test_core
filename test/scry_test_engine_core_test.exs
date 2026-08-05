defmodule ScryTestEngineCoreTest do
  use ExUnit.Case, async: true

  alias ScryTestEngineCore.Conn

  @users [
    %{"name" => "Alice", "age" => 30, "status" => "active"},
    %{"name" => "Bob", "age" => 17, "status" => "active"},
    %{"name" => "Carol", "age" => 65, "status" => "inactive"}
  ]

  @orders [
    %{"id" => 1, "total" => 80},
    %{"id" => 2, "total" => 20}
  ]

  setup do
    conn = Conn.new(%{["users"] => @users, ["orders"] => @orders})
    %{conn: conn}
  end

  test "a full pipeline run: query text -> parse -> execute -> real static rows", %{conn: conn} do
    assert {:ok, query} = ScryCore.parse(~s(SELECT users WHERE age > 18 { name }))
    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)

    assert rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "boolean logic and multiple projected fields, end to end", %{conn: conn} do
    assert {:ok, query} =
             ScryCore.parse(~s(SELECT users WHERE status = "active" AND age < 18 { name, age }))

    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)

    assert rows == [%{"name" => "Bob", "age" => 17}]
  end

  test "a nested SELECT body item, end to end", %{conn: conn} do
    assert {:ok, query} =
             ScryCore.parse(~s(SELECT users { name, SELECT orders WHERE total > 50 { id } }))

    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)

    assert rows == [
             %{"name" => "Alice", "orders" => [%{"id" => 1}]},
             %{"name" => "Bob", "orders" => [%{"id" => 1}]},
             %{"name" => "Carol", "orders" => [%{"id" => 1}]}
           ]
  end

  test "fetch/2 surfaces an unknown source as an error instead of raising", %{conn: conn} do
    assert {:ok, query} = ScryCore.parse(~s(SELECT nonexistent { name }))

    assert {:error, {:no_such_source, ["nonexistent"]}} =
             ScryCore.Executor.run(query, ScryTestEngineCore, conn)
  end
end

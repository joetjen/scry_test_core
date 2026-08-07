defmodule ScryTestEngineCore.NativeBuilderTest do
  @moduledoc """
  The first proof, from a genuinely separate downstream package rather
  than `scry_core`'s own test suite, that impl_spec.md §7's Elixir-
  native front end (`ScryCore.Query`'s Layer 1 functional API and
  Layer 2's `from/2` macro) works end to end against a real
  `ScryCore.EngineBehaviour` implementation -- `scry_test_engine_core`'s
  own existing suite (`scry_test_engine_core_test.exs`) only ever
  exercises the *text* front end (`ScryCore.parse/1`); this is the
  analogous proof for the native one, the same "prove it against a
  real downstream consumer, not just core's own tests" discipline that
  motivated building this package in the first place.
  """

  use ExUnit.Case, async: true

  alias ScryTestEngineCore.Conn

  import ScryCore.Query

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

  test "Layer 1 (the functional API): built by hand, executed end to end", %{conn: conn} do
    query =
      ScryCore.Query.new(["users"])
      |> ScryCore.Query.where({:cmp, :gt, ["age"], 18})
      |> ScryCore.Query.select([{:field, ["name"]}])

    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)
    assert rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "Layer 2 (from/2): the exact same query, written as the macro DSL", %{conn: conn} do
    query = from(u in "users", where: u.age > 18, select: %{name: u.name})

    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)
    assert rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "from/2 with a pinned parameter, resolved through run/4's own params argument", %{
    conn: conn
  } do
    min_age = 18
    query = from(u in "users", where: u.age > ^min_age, select: %{name: u.name})

    assert {:ok, rows} =
             ScryCore.Executor.run(query, ScryTestEngineCore, conn, %{"min_age" => min_age})

    assert rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "from/2, group_by + having + an aggregate, executed end to end", %{conn: conn} do
    query =
      from(u in "users",
        group_by: [u.status],
        having: count(u.name) > 1,
        select: %{status: u.status, total: count(u.name)}
      )

    assert {:ok, rows} = ScryCore.Executor.run(query, ScryTestEngineCore, conn)
    assert rows == [%{"status" => "active", "total" => 2}]
  end

  test "from/2 and the equivalent query text produce the exact same rows", %{conn: conn} do
    built =
      from(u in "users",
        where: u.status == "active" and u.age < 18,
        select: %{name: u.name, age: u.age}
      )

    assert {:ok, parsed} =
             ScryCore.parse(~s(SELECT users WHERE status = "active" AND age < 18 { name, age }))

    assert {:ok, built_rows} = ScryCore.Executor.run(built, ScryTestEngineCore, conn)
    assert {:ok, parsed_rows} = ScryCore.Executor.run(parsed, ScryTestEngineCore, conn)
    assert built_rows == parsed_rows
    assert built_rows == [%{"name" => "Bob", "age" => 17}]
  end

  test "fetch/2 surfaces an unknown source as an error instead of raising, via the native builder",
       %{conn: conn} do
    query = from(x in "nonexistent", select: %{name: x.name})

    assert {:error, {:no_such_source, ["nonexistent"]}} =
             ScryCore.Executor.run(query, ScryTestEngineCore, conn)
  end
end

defmodule Scry.Test.Core.NativeBuilderTest do
  @moduledoc """
  The first proof, from a genuinely separate downstream package rather
  than `scry_core`'s own test suite, that the Elixir-
  native front end (`Scry.Core.Query`'s Layer 1 functional API and
  Layer 2's `from/2` macro) works end to end against a real
  `Scry.Core.EngineBehaviour` implementation -- `conn_test.exs`'s own
  suite only ever exercises the *text* front end (`Scry.Core.parse/1`);
  this is the analogous proof for the native one, against
  `Scry.Test.Core.Conn.in_memory/1` (the same "prove it against a real
  downstream consumer, not just core's own tests" discipline that
  motivated building this package in the first place).
  """

  use ExUnit.Case, async: true

  alias Scry.Core.{Cursor, Executor}
  alias Scry.Test.Core.Conn

  import Scry.Core.Query

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
    {engine, conn} = Conn.in_memory(%{["users"] => @users, ["orders"] => @orders})
    %{engine: engine, conn: conn}
  end

  # `Scry.Core.Executor.run/3,4` returns a lazy `Scry.Core.Cursor.t()` now,
  # not `{:ok, [row()]}` -- drains it back to this suite's own
  # long-established shape.
  defp materialize({:ok, cursor}), do: {:ok, Cursor.to_list(cursor)}
  defp materialize({:error, _} = err), do: err

  test "Layer 1 (the functional API): built by hand, executed end to end", %{
    engine: engine,
    conn: conn
  } do
    query =
      Scry.Core.Query.new(["users"])
      |> Scry.Core.Query.where({:cmp, :gt, ["age"], 18})
      |> Scry.Core.Query.select([{:field, ["name"]}])

    assert {:ok, rows} = Executor.run(query, engine, conn) |> materialize()
    assert rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "Layer 2 (from/2): the exact same query, written as the macro DSL", %{
    engine: engine,
    conn: conn
  } do
    query = from(u in "users", where: u.age > 18, select: %{name: u.name})

    assert {:ok, rows} = Executor.run(query, engine, conn) |> materialize()
    assert rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "from/2 with a pinned parameter, resolved through run/4's own params argument", %{
    engine: engine,
    conn: conn
  } do
    min_age = 18
    query = from(u in "users", where: u.age > ^min_age, select: %{name: u.name})

    assert {:ok, rows} =
             Executor.run(query, engine, conn, %{"min_age" => min_age}) |> materialize()

    assert rows == [%{"name" => "Alice"}, %{"name" => "Carol"}]
  end

  test "from/2, group_by + having + an aggregate, executed end to end", %{
    engine: engine,
    conn: conn
  } do
    query =
      from(u in "users",
        group_by: [u.status],
        having: count(u.name) > 1,
        select: %{status: u.status, total: count(u.name)}
      )

    assert {:ok, rows} = Executor.run(query, engine, conn) |> materialize()
    assert rows == [%{"status" => "active", "total" => 2}]
  end

  test "from/2 and the equivalent query text produce the exact same rows", %{
    engine: engine,
    conn: conn
  } do
    built =
      from(u in "users",
        where: u.status == "active" and u.age < 18,
        select: %{name: u.name, age: u.age}
      )

    assert {:ok, parsed} =
             Scry.Core.parse(~s(SELECT users WHERE status = "active" AND age < 18 { name, age }))

    assert {:ok, built_rows} = Executor.run(built, engine, conn) |> materialize()
    assert {:ok, parsed_rows} = Executor.run(parsed, engine, conn) |> materialize()

    assert built_rows == parsed_rows
    assert built_rows == [%{"name" => "Bob", "age" => 17}]
  end

  test "execute/3 surfaces an unknown source as an error instead of raising, via the native builder",
       %{engine: engine, conn: conn} do
    query = from(x in "nonexistent", select: %{name: x.name})

    assert {:error, {:query_error, {:no_such_source, ["nonexistent"]}}} =
             Executor.run(query, engine, conn) |> materialize()
  end
end

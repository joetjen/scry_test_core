defmodule ScryTestEngineCore do
  @moduledoc """
  A static, in-memory implementation of `ScryCore.EngineBehaviour` --
  for testing the composition/execution pipeline
  (`ScryCore`'s grammar → `ScryCore.Actions` → `%ScryCore.Query{}` →
  `ScryCore.Executor`) end to end, against real data that never leaves
  the test process, instead of a real external store. Not for
  production use — see `scry_core`'s own `ScryCore.EngineBehaviour` for
  why a real adapter needs more than this (pushdown, a genuine
  connection, ...).

  ## Usage

      conn = ScryTestEngineCore.Conn.new(%{
        ["users"] => [%{"name" => "Alice", "age" => 30}]
      })

      {:ok, query} = # ... parse + build a %ScryCore.Query{}
      ScryCore.Executor.run(query, ScryTestEngineCore, conn)
  """

  @behaviour ScryCore.EngineBehaviour

  alias ScryTestEngineCore.Conn

  @impl true
  def fetch(%Conn{data: data}, source) do
    case Map.fetch(data, source) do
      {:ok, rows} -> {:ok, rows}
      :error -> {:error, {:no_such_source, source}}
    end
  end
end

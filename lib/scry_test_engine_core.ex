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

  `fetch/2` returns a genuine `Stream`, not the raw stored list
  directly -- `EngineBehaviour.fetch/2`'s own contract accepts any
  `Enumerable.t()` now, and this package exists specifically to
  validate real behavior end to end against a real, separate consumer
  (`ScryCore.Executor`'s own test suite already proves the contract
  works in isolation; this is the same proof against a genuinely
  different package). `ScryCore.Executor.fetch_rows/6` still
  materializes immediately through `ScryCore.Cursor`, so callers see
  no behavior difference at all -- only that this engine is no longer
  handing back its own internal list by reference.

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
      {:ok, rows} -> {:ok, Stream.map(rows, & &1)}
      :error -> {:error, {:no_such_source, source}}
    end
  end
end

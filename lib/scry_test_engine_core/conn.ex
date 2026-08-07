defmodule ScryTestEngineCore.Conn do
  @moduledoc """
  The "connection" `ScryTestEngineCore.fetch/2` reads from -- not a
  real connection at all, just the static dataset a test supplies.
  Named `Conn` anyway, matching the connection/config struct every real
  adapter exposes (impl_spec.md §2), so test code and a real adapter's
  own tests read the same way.

  `new/1` starts from whatever you hand it (empty by default); `seed/0`
  starts from `ScryTestEngineCore.Seed`'s own realistic, multi-table,
  foreign-key-related dataset instead -- for exploring or testing
  against something with real relationships to correlate across,
  without every caller having to hand-author its own fixture rows.
  Both return an ordinary `t()`; `seed/0` is not a different kind of
  connection, just a different starting dataset.
  """

  alias ScryTestEngineCore.Seed

  @typedoc "Keyed by source path (e.g. `[\"orders\"]`), matching `ScryCore.Query.source`."
  @type data :: %{optional([String.t()]) => [ScryCore.EngineBehaviour.row()]}

  @type t :: %__MODULE__{data: data()}

  defstruct data: %{}

  @doc "Builds a `Conn` from a plain `%{source_path => rows}` map -- empty by default."
  @spec new(data()) :: t()
  def new(data \\ %{}) when is_map(data), do: %__MODULE__{data: data}

  @doc """
  Builds a `Conn` prefilled with `ScryTestEngineCore.Seed`'s own
  dataset -- `users`/`products`/`orders`/`order_items`, related by
  real foreign-key-shaped fields (see that module's own moduledoc).
  """
  @spec seed() :: t()
  def seed, do: new(Seed.data())
end

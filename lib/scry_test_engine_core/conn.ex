defmodule ScryTestEngineCore.Conn do
  @moduledoc """
  The "connection" `ScryTestEngineCore.fetch/2` reads from -- not a
  real connection at all, just the static dataset a test supplies.
  Named `Conn` anyway, matching the connection/config struct every real
  adapter exposes (impl_spec.md §2), so test code and a real adapter's
  own tests read the same way.
  """

  @typedoc "Keyed by source path (e.g. `[\"orders\"]`), matching `ScryCore.Query.source`."
  @type data :: %{optional([String.t()]) => [ScryCore.EngineBehaviour.row()]}

  @type t :: %__MODULE__{data: data()}

  defstruct data: %{}

  @doc "Builds a `Conn` from a plain `%{source_path => rows}` map."
  @spec new(data()) :: t()
  def new(data \\ %{}) when is_map(data), do: %__MODULE__{data: data}
end

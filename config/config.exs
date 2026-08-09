import Config

# Wires this package's own four `Scry.Test.Core.Conn` constructors
# into `scry_core`'s generic `mix scry.query`/`mix scry.iex` -- see
# `Scry.Core.QueryTool`'s own moduledoc for the full config shape.
# No `parser:` override needed -- this package exercises `scry_core`'s
# own degenerate kind, so the default `Scry.Core` parser is exactly
# right.
config :scry_core, :query_tool,
  default: "in_memory",
  backends: %{
    "in_memory" => {Scry.Test.Core.Conn, :in_memory},
    "ets" => {Scry.Test.Core.Conn, :ets},
    "sqlite" => {Scry.Test.Core.Conn, :sqlite},
    "postgres" => {Scry.Test.Core.Conn, :postgres}
  }

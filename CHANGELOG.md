# Changelog

## [Unreleased]

### Added

- Initial project scaffold: `mix.exs` (app `:scry_test_engine_core`, `{:scry_core, path: "../scry_core"}` local path dependency until scry_core is published to Hex), `.credo.exs`/`.formatter.exs`/`.tool-versions`.
- `ScryTestEngineCore.Conn`: the static, in-memory "connection" this engine reads from — a plain `%{source_path => rows}` map, named `Conn` to match the shape a real adapter's own connection/config struct will have (impl_spec.md §2).
- `ScryTestEngineCore`: a full `ScryCore.EngineBehaviour` implementation (`fetch/2`) backed entirely by `Conn`'s static data, returning `{:error, {:no_such_source, source}}` for an unknown source rather than raising.
- `test/scry_test_engine_core_test.exs`: the first real end-to-end integration test of the whole pipeline as a genuinely separate package — query text → `ScryCore.parse/1` → `%ScryCore.Query{}` → `ScryCore.Executor.run/3` → `ScryTestEngineCore` → real static rows. Covers a `where` filter, boolean-logic + multi-field projection, a nested `SELECT` body item, and the unknown-source error path.

### Fixed

- `scry_core`'s own `ichor` dependency had to be un-scoped from `only: [:dev, :test]` to compile at all as a dependency of this package — see `scry_core`'s own changelog and impl_spec.md's Open Implementation Risks for the finding; this package's `mix.exs` needed no changes of its own once that was fixed.

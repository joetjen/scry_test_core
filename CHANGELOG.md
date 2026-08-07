# Changelog

## [Unreleased]

### Fixed

- `mix.lock`: `ichor` no longer resolves into this package's own dependency tree at all (regenerated after `scry_core` moved `ichor` back to `only: [:dev, :test], runtime: false` for real -- confirmed via a from-scratch `rm -rf _build deps && mix deps.get`). This package never called anything `ichor`-specific itself; it only ever needed `scry_core`'s own compiled types, which no longer pull `ichor` in as a side effect.

### Added

- Initial project scaffold: `mix.exs` (app `:scry_test_engine_core`, `{:scry_core, path: "../scry_core"}` local path dependency until scry_core is published to Hex), `.credo.exs`/`.formatter.exs`/`.tool-versions`.
- `ScryTestEngineCore.Conn`: the static, in-memory "connection" this engine reads from — a plain `%{source_path => rows}` map, named `Conn` to match the shape a real adapter's own connection/config struct will have (impl_spec.md §2).
- `ScryTestEngineCore`: a full `ScryCore.EngineBehaviour` implementation (`fetch/2`) backed entirely by `Conn`'s static data, returning `{:error, {:no_such_source, source}}` for an unknown source rather than raising.
- `test/scry_test_engine_core_test.exs`: the first real end-to-end integration test of the whole pipeline as a genuinely separate package — query text → `ScryCore.parse/1` → `%ScryCore.Query{}` → `ScryCore.Executor.run/3` → `ScryTestEngineCore` → real static rows. Covers a `where` filter, boolean-logic + multi-field projection, a nested `SELECT` body item, and the unknown-source error path.
- `test/native_builder_test.exs`: the analogous end-to-end proof for `scry_core`'s own Elixir-native front end (impl_spec.md §7 -- `ScryCore.Query`'s Layer 1 functional API and Layer 2's `from/2` macro), from this genuinely separate package rather than `scry_core`'s own test suite. Covers a hand-built Layer 1 query and the equivalent `from/2`-built one executing identically, a `^`-pinned parameter resolved through `run/4`'s own `params` argument, `group_by`/`having`/an aggregate, `from/2` and the equivalent query text producing the exact same rows, and the unknown-source error path via the native builder.
- `ScryTestEngineCore.Seed` + `ScryTestEngineCore.Conn.seed/0`: a reasonably large, realistic, multi-table relational dataset (`users`/`products`/`orders`/`order_items`, with real foreign-key-shaped references between them) available out of the box, alongside (not instead of) `Conn.new/1`'s own existing "supply your own data" path, which is completely unchanged. Motivated by nested `SELECT`/correlation (lang_spec.md §6, and `scry_core`'s own newly-landed nested-`from` support in the native builder) needing something with real relationships to correlate across to be worth exercising at all -- a handful of flat, unrelated rows doesn't exercise that path meaningfully. `test/seed_test.exs` runs a plain filter, `GROUP BY`/an aggregate, and a nested correlation two levels deep (`orders` → their own `order_items`), through both query text and the native builder, confirming both front ends see the same relationships in the same data.
- `mix scry.query` -- runs a query (given as an argument, or via `--file PATH`) against `Conn.seed/0`'s own dataset and prints the resulting rows, for trying the query language out from the command line without writing any Elixir code first. A parse error is formatted via `Ichor.Error.format/1` (the same way `mix ichor.gen`'s own error path does), not a raw struct dump. `test/mix/tasks/scry.query_test.exs` covers both ways of supplying a query, both usage errors (neither given, both given), and the formatted-parse-error case.

### Fixed

- `scry_core`'s own `ichor` dependency had to be un-scoped from `only: [:dev, :test]` to compile at all as a dependency of this package — see `scry_core`'s own changelog and impl_spec.md's Open Implementation Risks for the finding; this package's `mix.exs` needed no changes of its own once that was fixed.

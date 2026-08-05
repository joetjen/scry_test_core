# scry_test_engine_core

A static, in-memory implementation of
[`scry_core`](https://github.com/joetjen/scry_core)'s
`ScryCore.EngineBehaviour` — for testing the composition/execution
pipeline (grammar → `ScryCore.Actions` → `%ScryCore.Query{}` →
`ScryCore.Executor`) end to end, without any real external data
source. Not for production use.

Named `scry_test_engine_core`, not `scry_engine_..._<driver>`, to keep
this class of package visually distinct from a real adapter at a
glance — the naming convention is `scry_test_engine_<kind>`; this one
is `core`'s own, since `scry_core` itself needs one before any real
kind library does. A future kind library (`scry_time_series`, ...)
gets its own `scry_test_engine_time_series` alongside it, once it
exists.

Source: <https://github.com/joetjen/scry_test_engine_core>. Specs live
in the separate [`scry`](https://github.com/joetjen/scry) repository;
the behaviour this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core). Implementation
has not started yet.

## Installation

```elixir
def deps do
  [
    {:scry_test_engine_core, "~> 0.1.0", only: :test}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_test_engine_core>.
- Latest `main` is built and deployed automatically by
  [`.github/workflows/docs.yml`](.github/workflows/docs.yml) to
  [GitHub Pages](https://joetjen.github.io/scry_test_engine_core/) on every push to `main`.

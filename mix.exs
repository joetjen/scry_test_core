defmodule Scry.Test.Core.MixProject do
  use Mix.Project

  @version "0.1.0"

  # `mix precommit` includes `test` as a step; without this, Mix runs
  # the whole alias chain (including `mix test`) in :dev, and `mix test`
  # itself refuses to run outside :test when invoked as a sub-task
  # rather than the top-level command. `test.postgres`/`test.timescaledb`
  # need the same treatment, for the same reason.
  def cli do
    [preferred_envs: [precommit: :test, "test.postgres": :test, "test.timescaledb": :test]]
  end

  def project do
    [
      app: :scry_test_core,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "Scry.Test.Core",
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      # :iex -- `mix scry.iex`'s own `IEx.started?/0` check needs
      # Dialyzer's own PLT to know the function exists. Deliberately
      # *not* also in `extra_applications` below -- confirmed
      # empirically that starting the `:iex` OTP application (which
      # declaring it there would trigger, via `Mix.Task.run(
      # "app.start")`) flips `IEx.started?/0` to `true` all by itself,
      # with no real interactive session involved at all, defeating
      # the whole point of checking it. `IEx`'s own module is already
      # on the code path without starting its application (part of
      # the Elixir installation itself), so no `extra_applications`
      # entry is needed for the call to actually work at runtime.
      dialyzer: [plt_add_apps: [:mix, :iex]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # === SCRY CORE ===
      # A local path dependency, not a Hex version constraint, since
      # scry_core isn't published to Hex yet -- this is the real
      # dependency (Scry.Core.EngineBehaviour, Scry.Core.Executor,
      # Scry.Core.Actions, the grammar this package's own integration
      # tests parse queries against), not test-only, since implementing
      # Scry.Core.EngineBehaviour genuinely needs its types at compile
      # time. Switch to a `~> x.y` Hex requirement once scry_core is
      # actually published (impl_spec.md's own dependency-versions
      # convention).
      {:scry_core, path: "../scry_core"},

      # === BACKEND ENGINES ===
      # Local path dependencies, same reasoning as scry_core above --
      # none of these four are published to Hex yet either. This
      # package's own Scry.Test.Core.Conn exposes one constructor per
      # engine (in_memory/1, ets/1, sqlite/1, postgres/1), all sharing
      # the same seed dataset, so every scry_<kind> package gets real
      # parity testing (and a real speed/memory comparison, via mix
      # scry.bench) across all four "for real" -- not just the trivial
      # in-memory case.
      {:scry_engine_inmemory, path: "../scry_engine_inmemory"},
      {:scry_engine_ets, path: "../scry_engine_ets"},
      {:scry_engine_exqlite, path: "../scry_engine_exqlite"},
      {:scry_engine_postgrex, path: "../scry_engine_postgrex"},

      # === CODE QUALITY & STATIC ANALYSIS ===
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      # Credo is invoked via `MIX_ENV=test mix credo`
      # Dialyzer is invoked via `MIX_ENV=test mix dialyzer`
      # Sobelow is invoked via `MIX_ENV=test mix sobelow`
      # Coveralls is invoked via `MIX_ENV=test mix coveralls

      # === TESTING ===
      {:stream_data, "~> 1.1", only: [:dev, :test]},

      # === DEVELOPMENT TOOLING ===
      # Mix, and Hex are built-in (no deps needed)
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false},

      # `mix scry.bench` -- `Scry.Engine.Exqlite` above serves queries,
      # but generating the benchmark database itself (schema, bulk
      # inserts, `CREATE INDEX`) still goes straight through `exqlite`'s
      # own low-level API, so this package needs it directly too. This
      # whole package is test/integration tooling, never a production
      # build in its own right, so unlike `scry_core`'s own `ichor`
      # (which had to stay out of a real downstream production build),
      # there's no equivalent boundary to protect here; a plain,
      # unscoped dependency is the right shape.
      {:exqlite, "~> 0.30"},

      # `Conn.postgres/1` issues real `Postgrex.query!/3` DDL/INSERT
      # calls directly (loading `Seed.data()` into a real Postgres),
      # same unscoped reasoning as `exqlite` above.
      {:postgrex, "~> 0.22"}
      # ExDoc is invoked via `MIX_ENV=dev mix docs`
    ]
  end

  # Fast/cheap checks first so a broken commit fails quickly; dialyzer
  # (slowest, especially its first PLT build) runs last.
  defp aliases do
    [
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        "sobelow",
        "test",
        "dialyzer"
      ],
      # `Conn.postgres/1` (and its own `postgres_parity_test.exs`/
      # `postgres_conn_test.exs`) are tagged `:postgres` and excluded
      # by default (`test/test_helper.exs`) specifically so `mix test`/
      # `mix precommit` stay zero-external-setup for anyone who merely
      # depends on this package for the other three backends. Run
      # `docker compose up -d` (this package's own root
      # `docker-compose.yml`) then `mix test.postgres` whenever a
      # change touches `Conn.postgres/1` or `scry_engine_postgrex`.
      "test.postgres": ["test --include postgres"],
      # Same reasoning, for `Conn.timescaledb/1` (and its own
      # `timescaledb_parity_test.exs`/`timescaledb_conn_test.exs`) --
      # tagged `:timescaledb`, needs `docker compose up -d` then
      # `mix test.timescaledb`.
      "test.timescaledb": ["test --include timescaledb"]
    ]
  end

  defp description do
    "Shared test/benchmark fixtures for scry_core: one seed dataset, servable through five " <>
      "real Scry.Core.EngineBehaviour backends (in-memory, ETS, SQLite, Postgres, TimescaleDB) " <>
      "via Scry.Test.Core.Conn, plus scry_core's own mix scry.query/scry.iex (configured here) " <>
      "and this package's own mix scry.bench for exercising them."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/scry_test_core"},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/scry_test_core",
      source_ref: "v#{@version}",
      extras: extras()
    ]
  end

  defp extras do
    [
      "README.md",
      "CHANGELOG.md",
      "LICENSE"
    ]
  end
end

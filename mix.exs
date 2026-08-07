defmodule ScryTestEngineCore.MixProject do
  use Mix.Project

  @version "0.1.0"

  # `mix precommit` includes `test` as a step; without this, Mix runs
  # the whole alias chain (including `mix test`) in :dev, and `mix test`
  # itself refuses to run outside :test when invoked as a sub-task
  # rather than the top-level command.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def project do
    [
      app: :scry_test_engine_core,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "ScryTestEngineCore",
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
      # dependency (ScryCore.EngineBehaviour, ScryCore.Executor,
      # ScryCore.Actions, the grammar this package's own integration
      # tests parse queries against), not test-only, since implementing
      # ScryCore.EngineBehaviour genuinely needs its types at compile
      # time. Switch to a `~> x.y` Hex requirement once scry_core is
      # actually published (impl_spec.md's own dependency-versions
      # convention).
      {:scry_core, path: "../scry_core"},

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
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false}
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
      ]
    ]
  end

  defp description do
    "A static, in-memory implementation of scry_core's ScryCore.EngineBehaviour, for testing " <>
      "the composition/execution pipeline end to end without a real external data source."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/scry_test_engine_core"},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/scry_test_engine_core",
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

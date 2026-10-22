defmodule ForgeOpsTracker.MixProject do
  use Mix.Project

  def project do
    [
      app: :forge_ops_tracker,
      version: "0.19.0",
      # The JSON module (used by ForgeOpsTracker.EventBuilder/Client) is part of Elixir's own
      # standard library only since 1.18: see README.md's "Dependencies" section for why that's
      # this SDK's one real floor, not an arbitrary pin.
      elixir: "~> 1.18",
      description: "Elixir error reporting client for ForgeOps.",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      source_url: "https://github.com/Luke-Popwell/forge-ops-tracker-elixir",
      docs: docs()
    ]
  end

  # main: "readme" makes the published docs' front page the actual README instead of ex_doc's
  # own generated (and here, empty) API-overview default: the README already covers
  # installation/configuration/what's automatic, exactly what a first-time visitor to
  # hexdocs.pm/forge_ops_tracker wants to land on.
  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end

  # The GitHub link points at the public read-only mirror of this directory (see
  # .github/workflows/mirror-elixir-sdk.yml), not the private monorepo this actually lives in.
  defp package do
    [
      maintainers: ["ForgeOps"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/Luke-Popwell/forge-ops-tracker-elixir",
        "Homepage" => "https://getforgeops.net"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE.txt)
    ]
  end

  # test/support holds a hand-rolled local HTTP test server (see its own moduledoc): only
  # compiled for :test, the standard Elixir convention for test-only helper modules that aren't
  # themselves *_test.exs files (which mix test already picks up on its own).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :crypto],
      mod: {ForgeOpsTracker.Application, []}
    ]
  end

  # No required runtime dependencies: see README.md's "Dependencies" section: :httpc/:ssl (bundled
  # with every OTP install, not a Hex package) cover HTTP delivery, Elixir's own JSON module
  # (stdlib since 1.18) covers JSON, and Elixir's Regex (PCRE via Erlang's :re, unlike the C
  # client in this repo, which had to adapt its patterns to POSIX ERE) covers PII scrubbing
  # unmodified from the Ruby original. ex_doc is dev-only, needed to actually publish docs
  # alongside the package (see "mix hex.publish"'s own requirement for it), never compiled into
  # a consumer's own build.
  #
  # :telemetry is optional: true, needed only by ForgeOpsTracker.Integrations.Phoenix/Ecto/Oban
  # (each ultimately calls :telemetry.attach/attach_many), never by the rest of this SDK. Marking
  # it optional rather than required never actually costs anyone anything in practice: a host app
  # using Phoenix, Ecto, or Oban already carries :telemetry transitively, since all three depend
  # on it themselves, so it's already present for exactly the apps that would call these
  # integration modules in the first place. Not gated behind Code.ensure_loaded?(:telemetry)
  # inside those modules either: calling attach/0 or attach/1 without :telemetry present is meant
  # to be an immediate, clear crash pointing at the missing dependency.
  #
  # :plug is optional the same way, needed only by
  # ForgeOpsTracker.Integrations.Phoenix.UserContextPlug (a real Plug module, so it compiles
  # against Plug.Conn/the Plug behaviour directly): a host app using Phoenix already carries :plug
  # transitively, since Phoenix itself is built on it.
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:telemetry, "~> 1.0", optional: true},
      {:plug, "~> 1.0", optional: true}
    ]
  end
end

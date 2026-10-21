defmodule GcpGcs.MixProject do
  use Mix.Project

  @version "0.3.1"
  @source_url "https://github.com/nyo16/gcp_gcs"

  def project do
    [
      app: :gcp_gcs,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        # CI runs dialyzer with MIX_ENV=test, which compiles test/support (ExUnit).
        plt_add_apps: [:ex_unit]
      ],

      # Docs
      name: "GcpGcs",
      description: "Google Cloud Storage client for Elixir with streaming and resumable uploads",
      source_url: @source_url,
      docs: [
        main: "GcpGcs",
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "v#{@version}",
        groups_for_modules: [
          Core: [GcpGcs, GcpGcs.Bucket, GcpGcs.Object, GcpGcs.Upload, GcpGcs.Download],
          Infrastructure: [GcpGcs.Auth, GcpGcs.Config, GcpGcs.Error],
          Observability: [GcpGcs.Telemetry]
        ]
      ],
      package: package()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {GcpGcs.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      description:
        "Google Cloud Storage client for Elixir using the JSON API, with streamed " <>
          "downloads and resumable uploads over Finch",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*)
    ]
  end

  defp deps do
    [
      # >= 0.24: pulls Mint CVE fixes and Finch PR #397 (pool checkout timeout
      # no longer crashes with CaseClauseError under mint 1.11).
      {:finch, "~> 0.24"},
      {:telemetry, "~> 1.0"},
      {:goth, "~> 1.4", optional: true},
      # Local HTTP server for tests (test/support/fake_server.ex).
      {:bandit, "~> 1.6", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end
end

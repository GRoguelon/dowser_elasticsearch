defmodule DowserElasticsearch.MixProject do
  use Mix.Project

  @source_url "https://github.com/GRoguelon/dowser_elasticsearch"
  @version "0.4.0"

  def project do
    [
      app: :dowser_elasticsearch,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      package: package(),
      name: "Dowser.Elasticsearch",
      description: "Elixir client for the Elasticsearch API, built on top of Dowser.Client",
      source_url: @source_url,
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {Dowser.Elasticsearch.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp aliases do
    [
      credo: ["credo --strict"],
      lint: ["format --check-formatted", "credo", "dialyzer"]
    ]
  end

  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end

  defp package do
    [
      name: :dowser_elasticsearch,
      files: ~w[lib .formatter.exs mix.exs README* CHANGELOG* UPGRADE* LICENSE*],
      maintainers: ["Geoffrey Roguelon"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://dowser-elasticsearch.hexdocs.pm/changelog.html",
        "Upgrade guide" => "https://dowser-elasticsearch.hexdocs.pm/upgrade_0_2.html",
        "Dowser.Client" => "https://hex.pm/packages/dowser_client"
      }
    ]
  end

  defp docs do
    [
      formatters: ["html"],
      main: "readme",
      extras: ["README.md", "UPGRADE_0_2.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md", "UPGRADE_0_2.md"],
      groups_for_modules: [
        API: [
          Dowser.Elasticsearch.Cat,
          Dowser.Elasticsearch.Cluster,
          Dowser.Elasticsearch.Document,
          Dowser.Elasticsearch.HealthReport,
          Dowser.Elasticsearch.Index,
          Dowser.Elasticsearch.Info,
          Dowser.Elasticsearch.Reindex,
          Dowser.Elasticsearch.Repository,
          Dowser.Elasticsearch.Search,
          Dowser.Elasticsearch.Streamer,
          Dowser.Elasticsearch.XPack
        ],
        "Type casting": [
          Dowser.Elasticsearch.Codec,
          Dowser.Elasticsearch.MappingCacher,
          Dowser.Elasticsearch.Codec.Binary,
          Dowser.Elasticsearch.Codec.Date,
          Dowser.Elasticsearch.Codec.DateRange,
          Dowser.Elasticsearch.Codec.GeoPoint,
          Dowser.Elasticsearch.Codec.IP,
          Dowser.Elasticsearch.Codec.Range
        ]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      dowser_client(),
      {:telemetry, "~> 1.2", optional: true},

      ## Dev
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true}
    ]
  end

  # The two packages are developed together: `DOWSER_CLIENT_PATH=../dowser_client`
  # builds against a working copy instead of the published version.
  defp dowser_client do
    if path = System.get_env("DOWSER_CLIENT_PATH") do
      {:dowser_client, path: path, override: true}
    else
      {:dowser_client, "~> 0.3.0"}
    end
  end
end

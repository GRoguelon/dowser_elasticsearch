defmodule DowserElasticsearch.MixProject do
  use Mix.Project

  @source_url "https://github.com/GRoguelon/dowser_elasticsearch"
  @version "0.2.2"

  def project do
    [
      app: :dowser_elasticsearch,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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
          Dowser.Elasticsearch.Document,
          Dowser.Elasticsearch.Streamer,
          Dowser.Elasticsearch.Index,
          Dowser.Elasticsearch.Search,
          Dowser.Elasticsearch.Repository
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
      {:dowser_client, "~> 0.2.1"},

      ## Dev
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true}
    ]
  end
end

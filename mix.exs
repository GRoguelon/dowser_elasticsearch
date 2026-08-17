defmodule DowserElasticsearch.MixProject do
  use Mix.Project

  @source_url "https://github.com/GRoguelon/dowser_elasticsearch"
  @version "0.1.0"

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
      extra_applications: [:logger],
      mod: {Dowser.Elasticsearch.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      name: :dowser_elasticsearch,
      files: ~w[lib .formatter.exs mix.exs README* CHANGELOG* LICENSE*],
      maintainers: ["Geoffrey Roguelon"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://dowser-elasticsearch.hexdocs.pm/changelog.html",
        "Dowser.Client" => "https://hex.pm/packages/dowser_client"
      }
    ]
  end

  defp docs do
    [
      formatters: ["html"],
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      groups_for_modules: [
        API: [
          Dowser.Elasticsearch.Document,
          Dowser.Elasticsearch.Index,
          Dowser.Elasticsearch.Search,
          Dowser.Elasticsearch.Repository
        ],
        "Type casting": [
          Dowser.Elasticsearch.TypeCodec,
          Dowser.Elasticsearch.Codec,
          Dowser.Elasticsearch.Mappable,
          Dowser.Elasticsearch.MappingCacher,
          Dowser.Elasticsearch.Fields.Binary,
          Dowser.Elasticsearch.Fields.Date,
          Dowser.Elasticsearch.Fields.DateRange,
          Dowser.Elasticsearch.Fields.GeoPoint,
          Dowser.Elasticsearch.Fields.IP,
          Dowser.Elasticsearch.Fields.Range
        ]
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dowser_client, path: "../dowser_client"},
      {:req, "~> 0.7", optional: true},
      {:hackney, "~> 4.6", optional: true},
      {:jason, "~> 1.4", optional: true},
      {:poison, "~> 6.0", optional: true},

      ## Dev
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true},
      {:benchee, "~> 1.0", only: :dev}
    ]
  end
end

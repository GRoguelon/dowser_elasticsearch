defmodule Dowser.Elasticsearch.Repo do
  @moduledoc """
  An Elasticsearch cluster an application talks to — a `Dowser.Repo`.

      defmodule MyApp.Search do
        use Dowser.Elasticsearch.Repo, otp_app: :my_app
      end

      # config/runtime.exs
      config :my_app, MyApp.Search,
        endpoint: System.fetch_env!("ELASTICSEARCH_URL"),
        decoder: Dowser.Elasticsearch.Codec,
        encoder: Dowser.Elasticsearch.Codec

      # the repo used when a call names none
      config :dowser_elasticsearch, default_repo: MyApp.Search

      # application.ex
      children = [MyApp.Search]

  Every API function takes the repo as its `:repo` option, and falls back to
  the default repo without one:

      Dowser.Elasticsearch.Search.search(%{query: %{match_all: %{}}}, index: "posts")
      Dowser.Elasticsearch.Search.search(%{query: %{match_all: %{}}}, index: "logs-*", repo: MyApp.Logs)

  See `Dowser.Repo` for the configuration, `init/2`, and the HTTP verbs a repo
  exposes (`MyApp.Search.post("/_ml/trained_models/_search", query)`).

  ## Checking the engine

  With `verify: true`, the repo checks at startup that its endpoint is an
  Elasticsearch cluster, and fails to start otherwise, with
  `{:unexpected_engine, version}`. `GET /` must carry no `distribution` (which
  OpenSearch sets to `"opensearch"`) and Elasticsearch's own signature: the
  `x-elastic-product: Elasticsearch` header (7.14 and later), or its tagline
  (earlier releases). `engine/0` then returns what it found, e.g.
  `{:elasticsearch, "8.15.0"}`. It is off by default: a cluster that is down
  would stop the application from booting.
  """

  ## Module attributes

  @tagline "You Know, for Search"

  ## The `use` macro

  defmacro __using__(opts) do
    quote do
      use Dowser.Repo, unquote(opts)

      @impl Dowser.Repo
      def verify(context) do
        Dowser.Elasticsearch.Repo.verify(context)
      end
    end
  end

  ## Public functions

  @doc """
  Checks that `repo` points at an Elasticsearch cluster, returning
  `{:ok, {:elasticsearch, version}}`, or `{:error, reason}` —
  `{:unexpected_engine, version}` for another engine, or why `GET /` failed.

  `repo` is anything `Dowser.Client` takes as `:repo`.
  """
  @spec verify(Dowser.Repo.t()) :: {:ok, {:elasticsearch, String.t()}} | {:error, term()}
  def verify(repo) do
    case Dowser.Client.get("/", repo: repo, keys: :strings, decoder: &raw/2) do
      {:ok,
       %Dowser.Client.Response{status: 200, headers: headers, body: %{"version" => _} = body}} ->
        engine(body, headers)

      {:ok, %Dowser.Client.Response{status: status, body: body}} ->
        {:error, {:unexpected_response, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  ## Private functions

  defp engine(%{"version" => %{"distribution" => _distribution} = version}, _headers) do
    {:error, {:unexpected_engine, version}}
  end

  defp engine(%{"version" => %{"number" => number} = version} = body, headers) do
    if Map.get(headers, "x-elastic-product") == "Elasticsearch" or
         Map.get(body, "tagline") == @tagline do
      {:ok, {:elasticsearch, number}}
    else
      {:error, {:unexpected_engine, version}}
    end
  end

  defp engine(%{"version" => version}, _headers) do
    {:error, {:unexpected_engine, version}}
  end

  # The cluster's own description, not a document: the repo's decoder, if it
  # has one, has nothing to cast in it.
  defp raw(body, _opts), do: body
end

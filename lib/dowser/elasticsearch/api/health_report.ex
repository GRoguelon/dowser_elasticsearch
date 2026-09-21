defmodule Dowser.Elasticsearch.HealthReport do
  @moduledoc """
  The Elasticsearch health report API — the endpoint tagged `health_report` in
  the
  [Elasticsearch OpenAPI specification](https://github.com/elastic/elasticsearch-specification).

  Built on `Dowser.Client`. The endpoint requires no attribute: the feature to
  report on is the `:feature` option, and the signature is `opts`-only.

  This is the cluster health *report* — a list of indicators
  (`master_is_stable`, `shards_availability`, `disk`, …), each with its own
  `green`/`unknown`/`yellow`/`red` status, an explanation of that status, the
  impacts of a non-green one and, where Elasticsearch can tell, the diagnosis
  and the steps to fix it. The cluster's own status is the worst indicator's.
  For the older, terser status — `GET /_cluster/health` — see the `cluster`
  APIs, and for it as one text row, `Dowser.Elasticsearch.Cat.health/1`.

  All options are forwarded to `Dowser.Client.request/4`, e.g. `:context`,
  `:params` (query-string parameters), `:format`, `:keys` and `:http_opts`
  (including `:headers`).

  On a 2xx response the function returns `{:ok, body}` with the decoded
  response body. A non-2xx response returns
  `{:error, %Dowser.Elasticsearch.Error{}}`; a transport, encoding or decoding
  failure returns `{:error, exception}` from `Dowser.Client`. The bang variant
  returns the body directly or raises the error exception.
  """

  alias Dowser.Elasticsearch.Client
  alias Dowser.Elasticsearch.Helpers
  alias Dowser.Elasticsearch.Index

  ## Typespecs

  @typedoc "One indicator name (a one-element list is accepted too)."
  @type feature :: String.t() | atom() | [String.t() | atom()]

  @type body :: term()
  @type result :: {:ok, body()} | {:error, Exception.t()}

  ## Public functions

  @doc """
  Returns the health report of the cluster — `GET /_health_report`
  ([Health API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-health-report)).

      {:ok, report} = Dowser.Elasticsearch.HealthReport.health_report()
      report["status"]
      #=> "green"
      Map.keys(report["indicators"])
      #=> ["master_is_stable", "repository_integrity", "disk", "shards_availability", ...]

  ## Options

    * `:feature` — restrict the report to **one** indicator, as named by a
      full report (`"disk"`, `"master_is_stable"`, …); absent for all of them.
      Elasticsearch resolves the path segment as a single indicator name and
      answers a comma-joined list with a `404`, so a list of several is
      refused here: `{:error, %ArgumentError{}}` — raised by
      `health_report!/1` — rather than a request the cluster rejects. Call the
      function once per indicator instead. A one-element list is accepted.
    * `:params` — the endpoint's query parameters: `timeout`, `verbose`
      (`true` by default; `false` drops the details) and `size` (the maximum
      number of affected resources reported, `1000` by default).
  """
  @spec health_report(keyword()) :: result()
  def health_report(opts \\ []) do
    {feature, opts} = Keyword.pop(opts, :feature)

    with {:ok, path} <- feature_path("/_health_report", feature) do
      path
      |> Client.get(opts)
      |> Helpers.parse_result()
    end
  end

  @doc """
  Like `health_report/1`, but returns the body directly or raises the error
  exception.
  """
  @spec health_report!(keyword()) :: body()
  def health_report!(opts \\ []) do
    opts |> health_report() |> Dowser.unwrap()
  end

  ## Private functions

  # The feature is a trailing path segment, where `Helpers.path/2` prefixes.
  # The specification types it as one name *or* a list, but Elasticsearch looks
  # the path segment up as a single indicator name and answers a comma-joined
  # list with a 404 — so a list of several is refused here rather than at the
  # cluster, as an error the non-bang variant can return.
  @spec feature_path(String.t(), feature()) :: {:ok, String.t()} | {:error, ArgumentError.t()}
  defp feature_path(base, feature) when feature in [nil, ""] do
    {:ok, base}
  end

  defp feature_path(base, feature) when is_binary(feature) or is_atom(feature) do
    {:ok, base <> "/" <> Index.segment(feature)}
  end

  defp feature_path(base, [feature]) do
    feature_path(base, feature)
  end

  defp feature_path(_base, feature) do
    {:error,
     %ArgumentError{
       message:
         ":feature is a single indicator name, got: #{inspect(feature)}. " <>
           "Call health_report/1 once per indicator, or omit :feature for the whole report."
     }}
  end
end

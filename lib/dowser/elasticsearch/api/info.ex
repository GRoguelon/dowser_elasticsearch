defmodule Dowser.Elasticsearch.Info do
  @moduledoc """
  The Elasticsearch cluster info API — the endpoint tagged `info` in the
  [Elasticsearch OpenAPI specification](https://github.com/elastic/elasticsearch-specification).

  Built on `Dowser.Client`. The endpoint takes no Elasticsearch attribute at
  all, so `info/1` only carries the transport options.

  All options are forwarded to `Dowser.Client.request/4`, e.g. `:context`,
  `:params` (query-string parameters), `:format`, `:keys` and `:http_opts`
  (including `:headers`) — plus `:codec`, this package's own, which picks the
  per-field codec for this one request (see `Dowser.Elasticsearch.Codec`).

  On a 2xx response the function returns `{:ok, body}` with the decoded
  response body. A non-2xx response returns
  `{:error, %Dowser.Elasticsearch.Error{}}`; a transport, encoding or decoding
  failure returns `{:error, exception}` from `Dowser.Client`. The bang variant
  returns the body directly or raises the error exception.
  """

  alias Dowser.Elasticsearch.Client
  alias Dowser.Elasticsearch.Helpers

  ## Typespecs

  @type body :: term()
  @type result :: {:ok, body()} | {:error, Exception.t()}

  ## Public functions

  @doc """
  Gets the basic information about the cluster — `GET /`
  ([Cluster info API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-info)).

  The response carries the node name, the cluster name and UUID, the
  Elasticsearch version and the tagline, which makes it the usual way to check
  that a cluster is reachable and to read its version:

      {:ok, info} = Dowser.Elasticsearch.Info.info()
      info["version"]["number"]
      #=> "8.13.4"

  ## Options

  Only the transport options listed in the module documentation, e.g.
  `:context` to pick the cluster to query.
  """
  @spec info(keyword()) :: result()
  def info(opts \\ []) do
    "/"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `info/1`, but returns the body directly or raises the error exception.
  """
  @spec info!(keyword()) :: body()
  def info!(opts \\ []) do
    opts |> info() |> Dowser.unwrap()
  end
end

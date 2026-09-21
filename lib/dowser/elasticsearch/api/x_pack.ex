defmodule Dowser.Elasticsearch.XPack do
  @moduledoc """
  The Elasticsearch X-Pack APIs — every endpoint tagged `xpack` in the
  [Elasticsearch OpenAPI specification](https://github.com/elastic/elasticsearch-specification):
  which features the cluster's build ships and licenses (`info/1`), and how
  much each one is actually used (`usage/1`).

  Built on `Dowser.Client`. Neither endpoint requires an attribute, so both
  signatures are `opts`-only.

  All options are forwarded to `Dowser.Client.request/4`, e.g. `:context`,
  `:params` (query-string parameters), `:format`, `:keys` and `:http_opts`
  (including `:headers`).

  On a 2xx response every function returns `{:ok, body}` with the decoded
  response body. A non-2xx response returns
  `{:error, %Dowser.Elasticsearch.Error{}}`; a transport, encoding or decoding
  failure returns `{:error, exception}` from `Dowser.Client`. Each function has
  a bang variant that returns the body directly or raises the error exception.
  """

  alias Dowser.Elasticsearch.Client
  alias Dowser.Elasticsearch.Helpers

  ## Typespecs

  @type body :: term()
  @type result :: {:ok, body()} | {:error, Exception.t()}

  ## Public functions

  @doc """
  Returns the build, license and feature set of the cluster — `GET /_xpack`
  ([Get information API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-xpack-info)).

      {:ok, info} = Dowser.Elasticsearch.XPack.info()
      info["license"]["type"]
      #=> "basic"
      info["features"]["ml"]["available"]
      #=> true

  ## Options

    * `:params` — `categories` restricts the response to any of `build`,
      `license` and `features` (comma-separated); `accept_enterprise` and
      `human` shape the license section.
  """
  @spec info(keyword()) :: result()
  def info(opts \\ []) do
    "/_xpack"
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

  @doc """
  Returns the usage of each X-Pack feature across the cluster — `GET
  /_xpack/usage`
  ([Get usage information API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-xpack-usage)).

  Where `info/1` says which features are available, this says what is being
  used: how many jobs, watches, rollup jobs, mapped runtime fields and so on
  each feature holds.

      {:ok, usage} = Dowser.Elasticsearch.XPack.usage()
      usage["watcher"]["count"]
      #=> %{"active" => 2, "total" => 3}

  ## Options

    * `:params` — `master_timeout` caps the wait for the master node.
  """
  @spec usage(keyword()) :: result()
  def usage(opts \\ []) do
    "/_xpack/usage"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `usage/1`, but returns the body directly or raises the error exception.
  """
  @spec usage!(keyword()) :: body()
  def usage!(opts \\ []) do
    opts |> usage() |> Dowser.unwrap()
  end
end

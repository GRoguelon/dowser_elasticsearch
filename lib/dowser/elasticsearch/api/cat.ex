defmodule Dowser.Elasticsearch.Cat do
  @moduledoc """
  The Elasticsearch compact and aligned text (CaT) APIs — every endpoint tagged
  `cat` in the
  [Elasticsearch OpenAPI specification](https://github.com/elastic/elasticsearch-specification).

  Built on `Dowser.Client`. The cat endpoints take no request body and no
  required attribute: each one's optional path parameter is an option, so every
  function has the same `opts`-only signature.

  ## JSON, not text

  The cat APIs are meant for humans at a terminal and answer in aligned text by
  default — but they honour the `accept` header `Dowser.Client` already sends,
  so the response comes back as JSON and is decoded like every other endpoint:
  a list of maps, one per row.

      Dowser.Elasticsearch.Cat.indices!(index: "posts*")
      #=> [%{"index" => "posts", "health" => "green", "docs.count" => "42", ...}]

  Every value in those maps is a string — that is what the cat APIs emit, JSON
  or not. For the aligned text a terminal wants, ask for it explicitly: the
  `format` query parameter wins over the header, and `resp_format: :raw` keeps
  the body from being parsed as JSON.

      Dowser.Elasticsearch.Cat.indices!(params: [format: "text", v: true], resp_format: :raw)

  ## Shared options

  Most cat endpoints accept the same query parameters, passed through `:params`:

    * `v` — add the column headers.
    * `h` — the columns to return, e.g. `h: "index,docs.count"`.
    * `s` — the columns to sort on, e.g. `s: "docs.count:desc"`.
    * `bytes` / `time` — the unit sizes and durations are expressed in
      (`"kb"`, `"gb"`, `"s"`, `"ms"`, …).
    * `format` — see above.

  Use `help/1` to ask an endpoint which columns it supports.

  All remaining options are forwarded to `Dowser.Client.request/4`, e.g.
  `:context`, `:params` (query-string parameters), `:format`, `:keys` and
  `:http_opts` (including `:headers`).

  On a 2xx response every function returns `{:ok, body}` with the decoded
  response body. A non-2xx response returns
  `{:error, %Dowser.Elasticsearch.Error{}}`; a transport, encoding or decoding
  failure returns `{:error, exception}` from `Dowser.Client`. Each function has
  a bang variant that returns the body directly or raises the error exception.
  """

  alias Dowser.Elasticsearch.Client
  alias Dowser.Elasticsearch.Helpers
  alias Dowser.Elasticsearch.Index

  ## Typespecs

  @type index :: Index.t()

  @typedoc "A path parameter: a single name, or several (joined with `,`)."
  @type name :: Index.name()

  @type body :: term()
  @type result :: {:ok, body()} | {:error, Exception.t()}

  ## Public functions — help

  @doc """
  Lists the available cat APIs — `GET /_cat`
  ([Cat help API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-help)).

  This one endpoint answers in plain text whatever the `accept` header says —
  a banner line, then one endpoint per line — so the response format defaults
  to `:raw` and the body is parsed here into the list of endpoints:

      Dowser.Elasticsearch.Cat.help!()
      #=> ["/_cat/allocation", "/_cat/shards", "/_cat/shards/{index}", ...]

  Pass `resp_format: :json` (or `:ndjson`) to opt out of both the `:raw`
  default and the parsing, and get whatever `Dowser.Client` decodes instead.
  """
  @spec help(keyword()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def help(opts \\ []) do
    opts = Helpers.put_default_format(opts, :resp_format, :raw)

    "/_cat"
    |> Client.get(opts)
    |> Helpers.parse_result()
    |> parse_help()
  end

  @doc """
  Like `help/1`, but returns the endpoints directly or raises the error
  exception.
  """
  @spec help!(keyword()) :: [String.t()]
  def help!(opts \\ []) do
    opts |> help() |> Dowser.unwrap()
  end

  ## Public functions — indices & documents

  @doc """
  Returns high-level information about one, several, or all indices
  ([Cat indices API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-indices)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec indices(keyword()) :: result()
  def indices(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    "/_cat/indices"
    |> cat_path(index)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `indices/1`, but returns the body directly or raises the error
  exception.
  """
  @spec indices!(keyword()) :: body()
  def indices!(opts \\ []) do
    opts |> indices() |> Dowser.unwrap()
  end

  @doc """
  Counts the documents of one, several, or all indices
  ([Cat count API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-count)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec count(keyword()) :: result()
  def count(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    "/_cat/count"
    |> cat_path(index)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `count/1`, but returns the body directly or raises the error exception.
  """
  @spec count!(keyword()) :: body()
  def count!(opts \\ []) do
    opts |> count() |> Dowser.unwrap()
  end

  @doc """
  Returns the aliases of one, several, or all indices
  ([Cat aliases API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-aliases)).

  ## Options

    * `:name` — restrict the result to one or several alias names.
  """
  @spec aliases(keyword()) :: result()
  def aliases(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    "/_cat/aliases"
    |> cat_path(name)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `aliases/1`, but returns the body directly or raises the error
  exception.
  """
  @spec aliases!(keyword()) :: body()
  def aliases!(opts \\ []) do
    opts |> aliases() |> Dowser.unwrap()
  end

  @doc """
  Returns the shards of one, several, or all indices, and the node each sits on
  ([Cat shards API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-shards)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec shards(keyword()) :: result()
  def shards(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    "/_cat/shards"
    |> cat_path(index)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `shards/1`, but returns the body directly or raises the error exception.
  """
  @spec shards!(keyword()) :: body()
  def shards!(opts \\ []) do
    opts |> shards() |> Dowser.unwrap()
  end

  @doc """
  Returns the low-level Lucene segments of one, several, or all indices
  ([Cat segments API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-segments)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec segments(keyword()) :: result()
  def segments(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    "/_cat/segments"
    |> cat_path(index)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `segments/1`, but returns the body directly or raises the error
  exception.
  """
  @spec segments!(keyword()) :: body()
  def segments!(opts \\ []) do
    opts |> segments() |> Dowser.unwrap()
  end

  @doc """
  Returns the shard recoveries — ongoing and completed — of one, several, or
  all indices
  ([Cat recovery API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-recovery)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec recovery(keyword()) :: result()
  def recovery(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    "/_cat/recovery"
    |> cat_path(index)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `recovery/1`, but returns the body directly or raises the error
  exception.
  """
  @spec recovery!(keyword()) :: body()
  def recovery!(opts \\ []) do
    opts |> recovery() |> Dowser.unwrap()
  end

  @doc """
  Returns the heap memory each field's fielddata uses, per node
  ([Cat fielddata API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-fielddata)).

  ## Options

    * `:fields` — restrict the result to one or several field names.
  """
  @spec fielddata(keyword()) :: result()
  def fielddata(opts \\ []) do
    {fields, opts} = Keyword.pop(opts, :fields)

    "/_cat/fielddata"
    |> cat_path(fields)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `fielddata/1`, but returns the body directly or raises the error
  exception.
  """
  @spec fielddata!(keyword()) :: body()
  def fielddata!(opts \\ []) do
    opts |> fielddata() |> Dowser.unwrap()
  end

  ## Public functions — cluster & nodes

  @doc """
  Returns the cluster health
  ([Cat health API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-health)).
  """
  @spec health(keyword()) :: result()
  def health(opts \\ []) do
    "/_cat/health"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `health/1`, but returns the body directly or raises the error exception.
  """
  @spec health!(keyword()) :: body()
  def health!(opts \\ []) do
    opts |> health() |> Dowser.unwrap()
  end

  @doc """
  Returns the nodes of the cluster
  ([Cat nodes API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-nodes)).
  """
  @spec nodes(keyword()) :: result()
  def nodes(opts \\ []) do
    "/_cat/nodes"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `nodes/1`, but returns the body directly or raises the error exception.
  """
  @spec nodes!(keyword()) :: body()
  def nodes!(opts \\ []) do
    opts |> nodes() |> Dowser.unwrap()
  end

  @doc """
  Returns the custom node attributes
  ([Cat nodeattrs API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-nodeattrs)).
  """
  @spec nodeattrs(keyword()) :: result()
  def nodeattrs(opts \\ []) do
    "/_cat/nodeattrs"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `nodeattrs/1`, but returns the body directly or raises the error
  exception.
  """
  @spec nodeattrs!(keyword()) :: body()
  def nodeattrs!(opts \\ []) do
    opts |> nodeattrs() |> Dowser.unwrap()
  end

  @doc """
  Returns the elected master node
  ([Cat master API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-master)).
  """
  @spec master(keyword()) :: result()
  def master(opts \\ []) do
    "/_cat/master"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `master/1`, but returns the body directly or raises the error exception.
  """
  @spec master!(keyword()) :: body()
  def master!(opts \\ []) do
    opts |> master() |> Dowser.unwrap()
  end

  @doc """
  Returns the disk space and shard count of each node
  ([Cat allocation API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-allocation)).

  ## Options

    * `:node_id` — restrict the result to one or several node ids.
  """
  @spec allocation(keyword()) :: result()
  def allocation(opts \\ []) do
    {node_id, opts} = Keyword.pop(opts, :node_id)

    "/_cat/allocation"
    |> cat_path(node_id)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `allocation/1`, but returns the body directly or raises the error
  exception.
  """
  @spec allocation!(keyword()) :: body()
  def allocation!(opts \\ []) do
    opts |> allocation() |> Dowser.unwrap()
  end

  @doc """
  Returns the circuit breaker statistics of each node
  ([Cat circuit breaker API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-circuit-breaker)).

  ## Options

    * `:circuit_breaker_patterns` — restrict the result to one or several
      circuit breaker names or patterns.
  """
  @spec circuit_breaker(keyword()) :: result()
  def circuit_breaker(opts \\ []) do
    {patterns, opts} = Keyword.pop(opts, :circuit_breaker_patterns)

    "/_cat/circuit_breaker"
    |> cat_path(patterns)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `circuit_breaker/1`, but returns the body directly or raises the error
  exception.
  """
  @spec circuit_breaker!(keyword()) :: body()
  def circuit_breaker!(opts \\ []) do
    opts |> circuit_breaker() |> Dowser.unwrap()
  end

  @doc """
  Returns the thread pools of each node
  ([Cat thread pool API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-thread-pool)).

  ## Options

    * `:thread_pool_patterns` — restrict the result to one or several thread
      pool names or patterns.
  """
  @spec thread_pool(keyword()) :: result()
  def thread_pool(opts \\ []) do
    {patterns, opts} = Keyword.pop(opts, :thread_pool_patterns)

    "/_cat/thread_pool"
    |> cat_path(patterns)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `thread_pool/1`, but returns the body directly or raises the error
  exception.
  """
  @spec thread_pool!(keyword()) :: body()
  def thread_pool!(opts \\ []) do
    opts |> thread_pool() |> Dowser.unwrap()
  end

  @doc """
  Returns the cluster-level changes not yet executed
  ([Cat pending tasks API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-pending-tasks)).
  """
  @spec pending_tasks(keyword()) :: result()
  def pending_tasks(opts \\ []) do
    "/_cat/pending_tasks"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `pending_tasks/1`, but returns the body directly or raises the error
  exception.
  """
  @spec pending_tasks!(keyword()) :: body()
  def pending_tasks!(opts \\ []) do
    opts |> pending_tasks() |> Dowser.unwrap()
  end

  @doc """
  Returns the tasks currently running on the nodes
  ([Cat task management API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-tasks)).
  """
  @spec tasks(keyword()) :: result()
  def tasks(opts \\ []) do
    "/_cat/tasks"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `tasks/1`, but returns the body directly or raises the error exception.
  """
  @spec tasks!(keyword()) :: body()
  def tasks!(opts \\ []) do
    opts |> tasks() |> Dowser.unwrap()
  end

  @doc """
  Returns the plugins installed on each node
  ([Cat plugins API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-plugins)).
  """
  @spec plugins(keyword()) :: result()
  def plugins(opts \\ []) do
    "/_cat/plugins"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `plugins/1`, but returns the body directly or raises the error
  exception.
  """
  @spec plugins!(keyword()) :: body()
  def plugins!(opts \\ []) do
    opts |> plugins() |> Dowser.unwrap()
  end

  ## Public functions — templates

  @doc """
  Returns the index templates
  ([Cat templates API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-templates)).

  ## Options

    * `:name` — restrict the result to one or several template names or
      patterns.
  """
  @spec templates(keyword()) :: result()
  def templates(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    "/_cat/templates"
    |> cat_path(name)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `templates/1`, but returns the body directly or raises the error
  exception.
  """
  @spec templates!(keyword()) :: body()
  def templates!(opts \\ []) do
    opts |> templates() |> Dowser.unwrap()
  end

  @doc """
  Returns the component templates
  ([Cat component templates API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-component-templates)).

  ## Options

    * `:name` — restrict the result to one or several component template names
      or patterns.
  """
  @spec component_templates(keyword()) :: result()
  def component_templates(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    "/_cat/component_templates"
    |> cat_path(name)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `component_templates/1`, but returns the body directly or raises the
  error exception.
  """
  @spec component_templates!(keyword()) :: body()
  def component_templates!(opts \\ []) do
    opts |> component_templates() |> Dowser.unwrap()
  end

  ## Public functions — snapshots

  @doc """
  Returns the snapshot repositories of the cluster
  ([Cat repositories API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-repositories)).
  """
  @spec repositories(keyword()) :: result()
  def repositories(opts \\ []) do
    "/_cat/repositories"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `repositories/1`, but returns the body directly or raises the error
  exception.
  """
  @spec repositories!(keyword()) :: body()
  def repositories!(opts \\ []) do
    opts |> repositories() |> Dowser.unwrap()
  end

  @doc """
  Returns the snapshots held by one or several repositories
  ([Cat snapshots API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-snapshots)).

  ## Options

    * `:repository` — restrict the result to one or several repository names;
      absent for all repositories.
  """
  @spec snapshots(keyword()) :: result()
  def snapshots(opts \\ []) do
    {repository, opts} = Keyword.pop(opts, :repository)

    "/_cat/snapshots"
    |> cat_path(repository)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `snapshots/1`, but returns the body directly or raises the error
  exception.
  """
  @spec snapshots!(keyword()) :: body()
  def snapshots!(opts \\ []) do
    opts |> snapshots() |> Dowser.unwrap()
  end

  ## Public functions — transforms & machine learning

  @doc """
  Returns the transforms of the cluster
  ([Cat transforms API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-transforms)).

  ## Options

    * `:transform_id` — restrict the result to one transform id.
  """
  @spec transforms(keyword()) :: result()
  def transforms(opts \\ []) do
    {transform_id, opts} = Keyword.pop(opts, :transform_id)

    "/_cat/transforms"
    |> cat_path(transform_id)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `transforms/1`, but returns the body directly or raises the error
  exception.
  """
  @spec transforms!(keyword()) :: body()
  def transforms!(opts \\ []) do
    opts |> transforms() |> Dowser.unwrap()
  end

  @doc """
  Returns the anomaly detection jobs
  ([Cat anomaly detectors API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-ml-jobs)).

  ## Options

    * `:job_id` — restrict the result to one job id.
  """
  @spec ml_jobs(keyword()) :: result()
  def ml_jobs(opts \\ []) do
    {job_id, opts} = Keyword.pop(opts, :job_id)

    "/_cat/ml/anomaly_detectors"
    |> cat_path(job_id)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `ml_jobs/1`, but returns the body directly or raises the error
  exception.
  """
  @spec ml_jobs!(keyword()) :: body()
  def ml_jobs!(opts \\ []) do
    opts |> ml_jobs() |> Dowser.unwrap()
  end

  @doc """
  Returns the datafeeds of the anomaly detection jobs
  ([Cat datafeeds API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-ml-datafeeds)).

  ## Options

    * `:datafeed_id` — restrict the result to one datafeed id.
  """
  @spec ml_datafeeds(keyword()) :: result()
  def ml_datafeeds(opts \\ []) do
    {datafeed_id, opts} = Keyword.pop(opts, :datafeed_id)

    "/_cat/ml/datafeeds"
    |> cat_path(datafeed_id)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `ml_datafeeds/1`, but returns the body directly or raises the error
  exception.
  """
  @spec ml_datafeeds!(keyword()) :: body()
  def ml_datafeeds!(opts \\ []) do
    opts |> ml_datafeeds() |> Dowser.unwrap()
  end

  @doc """
  Returns the data frame analytics jobs
  ([Cat data frame analytics API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-ml-data-frame-analytics)).

  ## Options

    * `:id` — restrict the result to one data frame analytics job id.
  """
  @spec ml_data_frame_analytics(keyword()) :: result()
  def ml_data_frame_analytics(opts \\ []) do
    {id, opts} = Keyword.pop(opts, :id)

    "/_cat/ml/data_frame/analytics"
    |> cat_path(id)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `ml_data_frame_analytics/1`, but returns the body directly or raises the
  error exception.
  """
  @spec ml_data_frame_analytics!(keyword()) :: body()
  def ml_data_frame_analytics!(opts \\ []) do
    opts |> ml_data_frame_analytics() |> Dowser.unwrap()
  end

  @doc """
  Returns the trained models and their allocations
  ([Cat trained model API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cat-ml-trained-models)).

  ## Options

    * `:model_id` — restrict the result to one trained model id.
  """
  @spec ml_trained_models(keyword()) :: result()
  def ml_trained_models(opts \\ []) do
    {model_id, opts} = Keyword.pop(opts, :model_id)

    "/_cat/ml/trained_models"
    |> cat_path(model_id)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `ml_trained_models/1`, but returns the body directly or raises the error
  exception.
  """
  @spec ml_trained_models!(keyword()) :: body()
  def ml_trained_models!(opts \\ []) do
    opts |> ml_trained_models() |> Dowser.unwrap()
  end

  ## Private functions

  # `/_cat` answers with a `=^.^=` banner and one endpoint per line; a body
  # that isn't text is whatever the caller's own `:resp_format` produced, and
  # is passed through.
  @spec parse_help(result()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  defp parse_help({:ok, body}) when is_binary(body) do
    endpoints =
      body
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "/"))

    {:ok, endpoints}
  end

  defp parse_help(result) do
    result
  end

  # The cat endpoints take their target as a trailing path segment, where the
  # rest of the library takes it as a leading one — so `Helpers.path/2` doesn't
  # fit.
  @spec cat_path(String.t(), name()) :: String.t()
  defp cat_path(base, target) do
    case Index.segment(target) do
      nil ->
        base

      segment ->
        base <> "/" <> segment
    end
  end
end

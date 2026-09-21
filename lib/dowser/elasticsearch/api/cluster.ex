defmodule Dowser.Elasticsearch.Cluster do
  @moduledoc """
  The Elasticsearch cluster APIs — every endpoint tagged `cluster` in the
  [Elasticsearch OpenAPI specification](https://github.com/elastic/elasticsearch-specification):
  cluster health, settings, state and statistics, shard allocation and
  rerouting, voting configuration exclusions, remote clusters, and the
  `_nodes` endpoints, which the specification tags `cluster` too.

  Built on `Dowser.Client`. Required Elasticsearch attributes are positional
  arguments; everything optional lives in `opts`.

  ## Shared conventions

    * `:node_id` — where an endpoint accepts an optional node target: absent
      for every node, a single node id/name/pattern, or a list of them
      (joined with `,`). The two repositories-metering endpoints *require* a
      node target and take it as their first argument instead.
    * `:metric` — where an endpoint accepts a metric filter: a single metric
      or a list. `/_cluster/state` and `/_nodes/.../stats` nest a second
      filter under it (`:index` and `:index_metric`), which Elasticsearch can
      only read as the segment after a metric — passing one without `:metric`
      is reported as `{:error, %ArgumentError{}}`.
    * Endpoints that accept a request body take it as their first argument,
      required — pass `%{}` to send nothing.
    * `ping/1` is the `HEAD /` check, and comes as the pair the rest of the
      library uses: `ping/1` returns `{:ok, boolean()}` or
      `{:error, exception}`, `ping?/1` returns the bare boolean and raises on
      a genuine error.

  All remaining options are forwarded to `Dowser.Client.request/4`, e.g.
  `:context`, `:params` (query-string parameters), `:format`, `:keys` and
  `:http_opts` (including `:headers`) — plus `:codec`, this package's own,
  which picks the per-field codec for this one request (see
  `Dowser.Elasticsearch.Codec`).

  On a 2xx response every function returns `{:ok, body}` with the decoded
  response body. A non-2xx response returns
  `{:error, %Dowser.Elasticsearch.Error{}}`; a transport, encoding or decoding
  failure returns `{:error, exception}` from `Dowser.Client`. A required
  argument that is missing or empty is reported the same way, before any
  request is made: `{:error, %ArgumentError{}}`. Each function has a bang
  variant that returns the body directly or raises the error exception.
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
  @type exists_result :: {:ok, boolean()} | {:error, Exception.t()}

  ## Public functions — health & info

  @doc """
  Returns the health status of the cluster
  ([Cluster health API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-health)).

  ## Options

    * `:index` — index target; absent for the whole cluster.
    * `:params` — e.g. `level`, `wait_for_status`, `wait_for_nodes`,
      `timeout`.
  """
  @spec health(keyword()) :: result()
  def health(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    "/_cluster/health"
    |> Helpers.suffix_path(index)
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
  Returns the cluster information of one or several targets — `_all`, or any
  of `http`, `ingest`, `thread_pool` and `script`
  ([Cluster info API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-info)).

  `target` is required. For the node name, cluster name and version, see
  `Dowser.Elasticsearch.Info.info/1` (`GET /`).
  """
  @spec info(name(), keyword()) :: result()
  def info(target, opts \\ []) do
    with {:ok, target_segment} <- Helpers.required_segment(target, "target") do
      ("/_info/" <> target_segment)
      |> Client.get(opts)
      |> Helpers.parse_result()
    end
  end

  @doc """
  Like `info/2`, but returns the body directly or raises the error exception.
  """
  @spec info!(name(), keyword()) :: body()
  def info!(target, opts \\ []) do
    target |> info(opts) |> Dowser.unwrap()
  end

  @doc """
  Checks whether the cluster answers — `HEAD /`
  ([Ping API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-ping)).

  Returns `{:ok, true}`, `{:ok, false}` or `{:error, exception}`.
  """
  @spec ping(keyword()) :: exists_result()
  def ping(opts \\ []) do
    opts = Helpers.put_default_format(opts, :resp_format, :raw)

    :head
    |> Client.request("/", nil, opts)
    |> Helpers.parse_exists()
  end

  @doc """
  Like `ping/1`, but returns the boolean directly (`404` → `false`) or raises
  the error exception.
  """
  @spec ping?(keyword()) :: boolean()
  def ping?(opts \\ []) do
    opts |> ping() |> Dowser.unwrap()
  end

  @doc """
  Returns the configured remote clusters and whether each one is connected
  ([Remote cluster info API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-remote-info)).
  """
  @spec remote_info(keyword()) :: result()
  def remote_info(opts \\ []) do
    "/_remote/info"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `remote_info/1`, but returns the body directly or raises the error
  exception.
  """
  @spec remote_info!(keyword()) :: body()
  def remote_info!(opts \\ []) do
    opts |> remote_info() |> Dowser.unwrap()
  end

  ## Public functions — settings, state & statistics

  @doc """
  Returns the cluster-wide settings
  ([Get cluster settings API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-get-settings)).

  ## Options

    * `:params` — e.g. `flat_settings`, `include_defaults`.
  """
  @spec get_settings(keyword()) :: result()
  def get_settings(opts \\ []) do
    "/_cluster/settings"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get_settings/1`, but returns the body directly or raises the error
  exception.
  """
  @spec get_settings!(keyword()) :: body()
  def get_settings!(opts \\ []) do
    opts |> get_settings() |> Dowser.unwrap()
  end

  @doc """
  Updates the cluster-wide settings
  ([Update cluster settings API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-put-settings)).

  `settings` is the request body, with the settings under `persistent` and/or
  `transient`:

      Dowser.Elasticsearch.Cluster.put_settings(%{
        persistent: %{"indices.recovery.max_bytes_per_sec" => "50mb"}
      })
  """
  @spec put_settings(map(), keyword()) :: result()
  def put_settings(%{} = settings, opts \\ []) do
    "/_cluster/settings"
    |> Client.put(settings, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `put_settings/2`, but returns the body directly or raises the error
  exception.
  """
  @spec put_settings!(map(), keyword()) :: body()
  def put_settings!(%{} = settings, opts \\ []) do
    settings |> put_settings(opts) |> Dowser.unwrap()
  end

  @doc """
  Returns the internal state of the cluster
  ([Cluster state API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-state)).

  ## Options

    * `:metric` — restrict the state to one or several metrics (`metadata`,
      `routing_table`, `nodes`, …); absent for all of them.
    * `:index` — index target, only alongside `:metric` — Elasticsearch reads
      it as the segment after one. Without `:metric`, returns
      `{:error, %ArgumentError{}}`.
  """
  @spec state(keyword()) :: result()
  def state(opts \\ []) do
    {metric, opts} = Keyword.pop(opts, :metric)
    {index, opts} = Keyword.pop(opts, :index)

    with {:ok, path} <- nested_path("/_cluster/state", {metric, :metric}, {index, :index}) do
      path
      |> Client.get(opts)
      |> Helpers.parse_result()
    end
  end

  @doc """
  Like `state/1`, but returns the body directly or raises the error exception.
  """
  @spec state!(keyword()) :: body()
  def state!(opts \\ []) do
    opts |> state() |> Dowser.unwrap()
  end

  @doc """
  Returns cluster-wide statistics — indices, nodes, shards, and the plugins
  installed
  ([Cluster stats API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-stats)).

  ## Options

    * `:node_id` — restrict the statistics to one or several nodes.
    * `:params` — e.g. `include_remotes`, `timeout`.
  """
  @spec stats(keyword()) :: result()
  def stats(opts \\ []) do
    {node_id, opts} = Keyword.pop(opts, :node_id)

    "/_cluster/stats"
    |> Helpers.suffix_path(node_id, "/nodes")
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `stats/1`, but returns the body directly or raises the error exception.
  """
  @spec stats!(keyword()) :: body()
  def stats!(opts \\ []) do
    opts |> stats() |> Dowser.unwrap()
  end

  @doc """
  Returns the cluster-level changes not yet executed
  ([Pending cluster tasks API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-pending-tasks)).
  """
  @spec pending_tasks(keyword()) :: result()
  def pending_tasks(opts \\ []) do
    "/_cluster/pending_tasks"
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

  ## Public functions — allocation & routing

  @doc """
  Explains why a shard is assigned to a node, or why it is unassigned
  ([Cluster allocation explain API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-allocation-explain)).

  `body` names the shard (`index`, `shard`, `primary`, …); pass `%{}` to let
  Elasticsearch pick the first unassigned shard it finds.

      %{index: "posts", shard: 0, primary: true}
      |> Dowser.Elasticsearch.Cluster.allocation_explain()
  """
  @spec allocation_explain(map(), keyword()) :: result()
  def allocation_explain(%{} = body, opts \\ []) do
    "/_cluster/allocation/explain"
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `allocation_explain/2`, but returns the body directly or raises the
  error exception.
  """
  @spec allocation_explain!(map(), keyword()) :: body()
  def allocation_explain!(%{} = body, opts \\ []) do
    body |> allocation_explain(opts) |> Dowser.unwrap()
  end

  @doc """
  Moves, cancels or allocates shards by hand
  ([Cluster reroute API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-reroute)).

  `body` carries the `commands` to apply; pass `%{}` to run the allocation
  logic without any (e.g. with `params: [retry_failed: true]`).

      %{commands: [%{move: %{index: "posts", shard: 0, from_node: "n1", to_node: "n2"}}]}
      |> Dowser.Elasticsearch.Cluster.reroute()
  """
  @spec reroute(map(), keyword()) :: result()
  def reroute(%{} = body, opts \\ []) do
    "/_cluster/reroute"
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `reroute/2`, but returns the body directly or raises the error
  exception.
  """
  @spec reroute!(map(), keyword()) :: body()
  def reroute!(%{} = body, opts \\ []) do
    body |> reroute(opts) |> Dowser.unwrap()
  end

  @doc """
  Excludes master-eligible nodes from the voting configuration, so they can be
  shut down without losing the quorum
  ([Update voting configuration exclusions API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-post-voting-config-exclusions)).

  The nodes to exclude go in `:params`, as `node_names` or `node_ids`:

      Dowser.Elasticsearch.Cluster.update_voting_config_exclusions(
        params: [node_names: "node-1,node-2"]
      )
  """
  @spec update_voting_config_exclusions(keyword()) :: result()
  def update_voting_config_exclusions(opts \\ []) do
    "/_cluster/voting_config_exclusions"
    |> Client.post(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `update_voting_config_exclusions/1`, but returns the body directly or
  raises the error exception.
  """
  @spec update_voting_config_exclusions!(keyword()) :: body()
  def update_voting_config_exclusions!(opts \\ []) do
    opts |> update_voting_config_exclusions() |> Dowser.unwrap()
  end

  @doc """
  Clears the voting configuration exclusions
  ([Clear voting configuration exclusions API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-delete-voting-config-exclusions)).

  ## Options

    * `:params` — `wait_for_removal: false` clears the list without waiting
      for the excluded nodes to leave the cluster.
  """
  @spec clear_voting_config_exclusions(keyword()) :: result()
  def clear_voting_config_exclusions(opts \\ []) do
    "/_cluster/voting_config_exclusions"
    |> Client.delete(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `clear_voting_config_exclusions/1`, but returns the body directly or
  raises the error exception.
  """
  @spec clear_voting_config_exclusions!(keyword()) :: body()
  def clear_voting_config_exclusions!(opts \\ []) do
    opts |> clear_voting_config_exclusions() |> Dowser.unwrap()
  end

  ## Public functions — nodes

  @doc """
  Returns information about the nodes of the cluster
  ([Nodes info API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-nodes-info)).

  ## Options

    * `:node_id` — node target; absent for every node.
    * `:metric` — restrict the result to one or several metrics (`settings`,
      `os`, `jvm`, `plugins`, …).
    * `:params` — e.g. `flat_settings`, `timeout`.
  """
  @spec nodes_info(keyword()) :: result()
  def nodes_info(opts \\ []) do
    {node_id, opts} = Keyword.pop(opts, :node_id)
    {metric, opts} = Keyword.pop(opts, :metric)

    "/_nodes"
    |> Helpers.suffix_path(node_id)
    |> Helpers.suffix_path(metric)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `nodes_info/1`, but returns the body directly or raises the error
  exception.
  """
  @spec nodes_info!(keyword()) :: body()
  def nodes_info!(opts \\ []) do
    opts |> nodes_info() |> Dowser.unwrap()
  end

  @doc """
  Returns the statistics of the nodes of the cluster
  ([Nodes stats API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-nodes-stats)).

  ## Options

    * `:node_id` — node target; absent for every node.
    * `:metric` — restrict the result to one or several metrics (`indices`,
      `os`, `jvm`, `thread_pool`, …).
    * `:index_metric` — restrict the `indices` metric to one or several index
      metrics (`docs`, `store`, `search`, …), only alongside `:metric` —
      Elasticsearch reads it as the segment after one. Without `:metric`,
      returns `{:error, %ArgumentError{}}`.
    * `:params` — e.g. `level`, `fields`, `groups`, `types`, `timeout`.
  """
  @spec nodes_stats(keyword()) :: result()
  def nodes_stats(opts \\ []) do
    {node_id, opts} = Keyword.pop(opts, :node_id)
    {metric, opts} = Keyword.pop(opts, :metric)
    {index_metric, opts} = Keyword.pop(opts, :index_metric)

    base = Helpers.suffix_path("/_nodes", node_id) <> "/stats"

    with {:ok, path} <-
           nested_path(base, {metric, :metric}, {index_metric, :index_metric}) do
      path
      |> Client.get(opts)
      |> Helpers.parse_result()
    end
  end

  @doc """
  Like `nodes_stats/1`, but returns the body directly or raises the error
  exception.
  """
  @spec nodes_stats!(keyword()) :: body()
  def nodes_stats!(opts \\ []) do
    opts |> nodes_stats() |> Dowser.unwrap()
  end

  @doc """
  Returns how often each feature of the cluster has been used since each node
  started
  ([Nodes feature usage API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-nodes-usage)).

  ## Options

    * `:node_id` — node target; absent for every node.
    * `:metric` — restrict the result to one or several metrics
      (`_all`, `rest_actions`).
  """
  @spec nodes_usage(keyword()) :: result()
  def nodes_usage(opts \\ []) do
    {node_id, opts} = Keyword.pop(opts, :node_id)
    {metric, opts} = Keyword.pop(opts, :metric)

    "/_nodes"
    |> Helpers.suffix_path(node_id)
    |> Kernel.<>("/usage")
    |> Helpers.suffix_path(metric)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `nodes_usage/1`, but returns the body directly or raises the error
  exception.
  """
  @spec nodes_usage!(keyword()) :: body()
  def nodes_usage!(opts \\ []) do
    opts |> nodes_usage() |> Dowser.unwrap()
  end

  @doc """
  Returns the hot threads of each node — the threads taking the most CPU, with
  their stack traces
  ([Nodes hot threads API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-nodes-hot-threads)).

  This endpoint answers in plain text, so the response format defaults to
  `:raw` and the body comes back as a binary to print.

  ## Options

    * `:node_id` — node target; absent for every node.
    * `:params` — e.g. `threads`, `interval`, `snapshots`, `type`, `sort`,
      `ignore_idle_threads`.
  """
  @spec nodes_hot_threads(keyword()) :: result()
  def nodes_hot_threads(opts \\ []) do
    {node_id, opts} = Keyword.pop(opts, :node_id)
    opts = Helpers.put_default_format(opts, :resp_format, :raw)

    "/_nodes"
    |> Helpers.suffix_path(node_id)
    |> Kernel.<>("/hot_threads")
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `nodes_hot_threads/1`, but returns the body directly or raises the
  error exception.
  """
  @spec nodes_hot_threads!(keyword()) :: body()
  def nodes_hot_threads!(opts \\ []) do
    opts |> nodes_hot_threads() |> Dowser.unwrap()
  end

  @doc """
  Reloads the keystore of one or several nodes, so secure settings changed on
  disk take effect without a restart
  ([Nodes reload secure settings API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-nodes-reload-secure-settings)).

  `body` carries the `secure_settings_password` when the keystore is password
  protected; pass `%{}` when it isn't.

  ## Options

    * `:node_id` — node target; absent for every node.
  """
  @spec nodes_reload_secure_settings(map(), keyword()) :: result()
  def nodes_reload_secure_settings(%{} = body, opts \\ []) do
    {node_id, opts} = Keyword.pop(opts, :node_id)

    "/_nodes"
    |> Helpers.suffix_path(node_id)
    |> Kernel.<>("/reload_secure_settings")
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `nodes_reload_secure_settings/2`, but returns the body directly or
  raises the error exception.
  """
  @spec nodes_reload_secure_settings!(map(), keyword()) :: body()
  def nodes_reload_secure_settings!(%{} = body, opts \\ []) do
    body |> nodes_reload_secure_settings(opts) |> Dowser.unwrap()
  end

  @doc """
  Returns the snapshot repositories metering of one or several nodes — how
  much each repository has been read from and written to
  ([Get repositories metering API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-nodes-get-repositories-metering-info)).

  `node_id` is required, unlike the other `_nodes` endpoints.
  """
  @spec nodes_get_repositories_metering_info(name(), keyword()) :: result()
  def nodes_get_repositories_metering_info(node_id, opts \\ []) do
    with {:ok, node_segment} <- Helpers.required_segment(node_id, "node_id") do
      ("/_nodes/" <> node_segment <> "/_repositories_metering")
      |> Client.get(opts)
      |> Helpers.parse_result()
    end
  end

  @doc """
  Like `nodes_get_repositories_metering_info/2`, but returns the body directly
  or raises the error exception.
  """
  @spec nodes_get_repositories_metering_info!(name(), keyword()) :: body()
  def nodes_get_repositories_metering_info!(node_id, opts \\ []) do
    node_id |> nodes_get_repositories_metering_info(opts) |> Dowser.unwrap()
  end

  @doc """
  Clears the archived repositories metering of one or several nodes, up to and
  including `max_archive_version`
  ([Clear repositories metering archive API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-nodes-clear-repositories-metering-archive)).

  Both `node_id` and `max_archive_version` are required.
  """
  @spec nodes_clear_repositories_metering_archive(name(), integer(), keyword()) :: result()
  def nodes_clear_repositories_metering_archive(node_id, max_archive_version, opts \\ [])
      when is_integer(max_archive_version) do
    with {:ok, node_segment} <- Helpers.required_segment(node_id, "node_id") do
      ("/_nodes/" <> node_segment <> "/_repositories_metering/#{max_archive_version}")
      |> Client.delete(nil, opts)
      |> Helpers.parse_result()
    end
  end

  @doc """
  Like `nodes_clear_repositories_metering_archive/3`, but returns the body
  directly or raises the error exception.
  """
  @spec nodes_clear_repositories_metering_archive!(name(), integer(), keyword()) :: body()
  def nodes_clear_repositories_metering_archive!(node_id, max_archive_version, opts \\ []) do
    node_id
    |> nodes_clear_repositories_metering_archive(max_archive_version, opts)
    |> Dowser.unwrap()
  end

  ## Private functions

  # Two nested path filters, where the second is only a path segment after the
  # first: `/_cluster/state/{metric}/{index}` and
  # `/_nodes/stats/{metric}/{index_metric}`.
  @spec nested_path(String.t(), {name(), atom()}, {name(), atom()}) ::
          {:ok, String.t()} | {:error, ArgumentError.t()}
  defp nested_path(base, {outer, outer_key}, {inner, inner_key}) do
    case {Index.segment(outer), Index.segment(inner)} do
      {nil, nil} ->
        {:ok, base}

      {nil, _inner} ->
        {:error,
         %ArgumentError{
           message:
             "#{inspect(inner_key)} needs #{inspect(outer_key)}: Elasticsearch reads it as " <>
               "the path segment after one, got: #{inspect(inner)}"
         }}

      {outer, nil} ->
        {:ok, base <> "/" <> outer}

      {outer, inner} ->
        {:ok, base <> "/" <> outer <> "/" <> inner}
    end
  end
end

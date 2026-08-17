defmodule Dowser.Elasticsearch.Document do
  @moduledoc """
  The Elasticsearch document APIs — every endpoint tagged `document` in the
  [Elasticsearch OpenAPI specification](https://github.com/elastic/elasticsearch-specification)
  (single-document CRUD, bulk, multi-get, by-query operations, reindex,
  term vectors).

  Built on `Dowser.Client`. Required Elasticsearch attributes are positional
  arguments; everything optional lives in `opts`.

  ## Shared conventions

    * Endpoints that accept a request body take it as their first argument,
      required — pass `%{}` to send nothing. The argument is named `query`
      when the body is an Elasticsearch query DSL document, and `body` (or a
      more specific name such as `document` or `operations`) otherwise.
    * `:index` — optional index target where the endpoint accepts one;
      endpoints that require an index take it as an argument.
    * `HEAD` existence checks come as a pair where the `?` variant plays the
      bang role: `exists/3` returns `{:ok, boolean()}` or
      `{:error, exception}`, `exists?/3` returns the bare boolean
      (`404` → `false`) and raises on genuine errors.

  All remaining options are forwarded to `Dowser.Client.request/4`, e.g.
  `:config`, `:params` (query-string parameters), `:format`, `:http_adapter`,
  `:json_adapter` and `:http_opts` (including `:headers`).

  Values are cast automatically wherever `:codec_adapter` is set to
  `Dowser.Elasticsearch.Codec` — no per-call option needed.

  On a 2xx response every function returns `{:ok, body}` with the decoded
  response body. A non-2xx response returns
  `{:error, %Dowser.Elasticsearch.Error{}}`; a transport, encoding or decoding
  failure returns `{:error, exception}` from `Dowser.Client`. Each function has
  a bang variant that returns the body directly or raises the error exception.
  """

  alias Dowser.Client
  alias Dowser.Elasticsearch.Helpers
  alias Dowser.Elasticsearch.Index

  ## Typespecs

  @type index :: Index.t()
  @type id :: String.t()
  @type body :: term()
  @type result :: {:ok, body()} | {:error, Exception.t()}
  @type exists_result :: {:ok, boolean()} | {:error, Exception.t()}

  ## Public functions — single documents

  @doc """
  Indexes (creates or replaces) a document
  ([Index document API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-index)).

  `document` is the document body.

  ## Options

    * `:id` — document id; absent to let Elasticsearch generate one.
  """
  @spec index(map(), index(), keyword()) :: result()
  def index(%{} = document, index, opts \\ []) do
    {id, opts} = Keyword.pop(opts, :id)
    opts = Helpers.put_codec_opts(opts, index: index)

    suffix =
      if id do
        "/_doc/" <> URI.encode(id)
      else
        "/_doc"
      end

    index
    |> Helpers.required_path(suffix)
    |> Client.post(document, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `index/3`, but returns the body directly or raises the error exception.
  """
  @spec index!(map(), index(), keyword()) :: body()
  def index!(%{} = document, index, opts \\ []) do
    document |> index(index, opts) |> Dowser.unwrap()
  end

  @doc """
  Creates the document `id`, failing if it already exists
  ([Create document API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-create)).

  `document` is the document body.
  """
  @spec create(map(), index(), id(), keyword()) :: result()
  def create(%{} = document, index, id, opts \\ []) do
    opts = Helpers.put_codec_opts(opts, index: index)

    index
    |> Helpers.required_path("/_create/" <> URI.encode(id))
    |> Client.post(document, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `create/4`, but returns the body directly or raises the error exception.
  """
  @spec create!(map(), index(), id(), keyword()) :: body()
  def create!(%{} = document, index, id, opts \\ []) do
    document |> create(index, id, opts) |> Dowser.unwrap()
  end

  @doc """
  Retrieves the document `id`
  ([Get document API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-get)).
  """
  @spec get(index(), id(), keyword()) :: result()
  def get(index, id, opts \\ []) do
    index
    |> Helpers.required_path("/_doc/" <> URI.encode(id))
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get/3`, but returns the body directly or raises the error exception.
  """
  @spec get!(index(), id(), keyword()) :: body()
  def get!(index, id, opts \\ []) do
    index |> get(id, opts) |> Dowser.unwrap()
  end

  @doc """
  Deletes the document `id`
  ([Delete document API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-delete)).
  """
  @spec delete(index(), id(), keyword()) :: result()
  def delete(index, id, opts \\ []) do
    index
    |> Helpers.required_path("/_doc/" <> URI.encode(id))
    |> Client.delete(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `delete/3`, but returns the body directly or raises the error exception.
  """
  @spec delete!(index(), id(), keyword()) :: body()
  def delete!(index, id, opts \\ []) do
    index |> delete(id, opts) |> Dowser.unwrap()
  end

  @doc """
  Checks whether the document `id` exists
  ([Document exists API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-exists)).

  Returns `{:ok, true}`, `{:ok, false}` or `{:error, exception}`.
  """
  @spec exists(index(), id(), keyword()) :: exists_result()
  def exists(index, id, opts \\ []) do
    index
    |> Helpers.required_path("/_doc/" <> URI.encode(id))
    |> head(opts)
  end

  @doc """
  Like `exists/3`, but returns the boolean directly (`404` → `false`) or
  raises the error exception.
  """
  @spec exists?(index(), id(), keyword()) :: boolean()
  def exists?(index, id, opts \\ []) do
    index |> exists(id, opts) |> Dowser.unwrap()
  end

  @doc """
  Retrieves the source of the document `id`, without metadata
  ([Get document source API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-get-source)).
  """
  @spec get_source(index(), id(), keyword()) :: result()
  def get_source(index, id, opts \\ []) do
    opts = Helpers.put_codec_opts(opts, index: index, source: true)

    index
    |> Helpers.required_path("/_source/" <> URI.encode(id))
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get_source/3`, but returns the body directly or raises the error
  exception.
  """
  @spec get_source!(index(), id(), keyword()) :: body()
  def get_source!(index, id, opts \\ []) do
    index |> get_source(id, opts) |> Dowser.unwrap()
  end

  @doc """
  Checks whether the document `id` exists and has a source
  ([Source exists API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-exists-source)).

  Returns `{:ok, true}`, `{:ok, false}` or `{:error, exception}`.
  """
  @spec source_exists(index(), id(), keyword()) :: exists_result()
  def source_exists(index, id, opts \\ []) do
    index
    |> Helpers.required_path("/_source/" <> URI.encode(id))
    |> head(opts)
  end

  @doc """
  Like `source_exists/3`, but returns the boolean directly (`404` → `false`)
  or raises the error exception.
  """
  @spec source_exists?(index(), id(), keyword()) :: boolean()
  def source_exists?(index, id, opts \\ []) do
    index |> source_exists(id, opts) |> Dowser.unwrap()
  end

  @doc """
  Updates the document `id` with a script or a partial document
  ([Update document API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-update)).

  `body` is the update body, e.g. `%{doc: %{title: "hi"}}` or
  `%{script: %{...}}`.
  """
  @spec update(map(), index(), id(), keyword()) :: result()
  def update(%{} = body, index, id, opts \\ []) do
    opts = Helpers.put_codec_opts(opts, index: index, doc_key: :doc)

    index
    |> Helpers.required_path("/_update/" <> URI.encode(id))
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `update/4`, but returns the body directly or raises the error exception.
  """
  @spec update!(map(), index(), id(), keyword()) :: body()
  def update!(%{} = body, index, id, opts \\ []) do
    body |> update(index, id, opts) |> Dowser.unwrap()
  end

  ## Public functions — multi-document

  @doc """
  Performs several index/create/update/delete operations in one request
  ([Bulk API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-bulk)).

  `operations` is a flat list alternating action and payload maps, encoded as
  NDJSON:

      Dowser.Elasticsearch.Document.bulk([
        %{index: %{_id: "1"}},
        %{title: "hello"},
        %{delete: %{_id: "2"}}
      ])

  ## Options

    * `:index` — default index target for actions that name none.
  """
  @spec bulk([map()], keyword()) :: result()
  def bulk(operations, opts \\ []) when is_list(operations) do
    {index, opts} = Keyword.pop(opts, :index)

    opts =
      opts
      |> Helpers.put_default_format(:req_format, :ndjson)
      |> Helpers.put_codec_opts(index: index)

    index
    |> Helpers.path("/_bulk")
    |> Client.post(operations, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `bulk/2`, but returns the body directly or raises the error exception.
  """
  @spec bulk!([map()], keyword()) :: body()
  def bulk!(operations, opts \\ []) do
    operations |> bulk(opts) |> Dowser.unwrap()
  end

  @doc """
  Retrieves several documents in one request
  ([Multi get API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-mget)).

  `body` is the request body, e.g. `%{ids: ["1", "2"]}` or `%{docs: [...]}`.

  ## Options

    * `:index` — index target; absent when each doc names its own.
  """
  @spec mget(map(), keyword()) :: result()
  def mget(%{} = body, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_mget")
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `mget/2`, but returns the body directly or raises the error exception.
  """
  @spec mget!(map(), keyword()) :: body()
  def mget!(%{} = body, opts \\ []) do
    body |> mget(opts) |> Dowser.unwrap()
  end

  ## Public functions — by-query operations

  @doc """
  Deletes every document matching a query
  ([Delete by query API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-delete-by-query)).

  `query` is the delete body (query DSL map).
  """
  @spec delete_by_query(map(), index(), keyword()) :: result()
  def delete_by_query(%{} = query, index, opts \\ []) do
    index
    |> Helpers.required_path("/_delete_by_query")
    |> Client.post(query, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `delete_by_query/3`, but returns the body directly or raises the error
  exception.
  """
  @spec delete_by_query!(map(), index(), keyword()) :: body()
  def delete_by_query!(%{} = query, index, opts \\ []) do
    query |> delete_by_query(index, opts) |> Dowser.unwrap()
  end

  @doc """
  Updates every document matching a query
  ([Update by query API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-update-by-query)).

  `body` is the request body (e.g. `query`, `script`); pass `%{}` to update
  everything.
  """
  @spec update_by_query(map(), index(), keyword()) :: result()
  def update_by_query(%{} = body, index, opts \\ []) do
    index
    |> Helpers.required_path("/_update_by_query")
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `update_by_query/3`, but returns the body directly or raises the error
  exception.
  """
  @spec update_by_query!(map(), index(), keyword()) :: body()
  def update_by_query!(%{} = body, index, opts \\ []) do
    body |> update_by_query(index, opts) |> Dowser.unwrap()
  end

  @doc """
  Copies documents from one index to another
  ([Reindex API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-reindex)).

  `body` is the request body, e.g.
  `%{source: %{index: "old"}, dest: %{index: "new"}}`.
  """
  @spec reindex(map(), keyword()) :: result()
  def reindex(%{} = body, opts \\ []) do
    "/_reindex"
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `reindex/2`, but returns the body directly or raises the error
  exception.
  """
  @spec reindex!(map(), keyword()) :: body()
  def reindex!(%{} = body, opts \\ []) do
    body |> reindex(opts) |> Dowser.unwrap()
  end

  ## Public functions — rethrottling

  @doc """
  Changes the throttling of the running delete-by-query task `task_id`
  ([Delete by query rethrottle API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-delete-by-query-rethrottle)).

  `requests_per_second` is sent as the required query-string parameter.
  """
  @spec delete_by_query_rethrottle(id(), number(), keyword()) :: result()
  def delete_by_query_rethrottle(task_id, requests_per_second, opts \\ []) do
    rethrottle("/_delete_by_query", task_id, requests_per_second, opts)
  end

  @doc """
  Like `delete_by_query_rethrottle/3`, but returns the body directly or raises
  the error exception.
  """
  @spec delete_by_query_rethrottle!(id(), number(), keyword()) :: body()
  def delete_by_query_rethrottle!(task_id, requests_per_second, opts \\ []) do
    task_id |> delete_by_query_rethrottle(requests_per_second, opts) |> Dowser.unwrap()
  end

  @doc """
  Changes the throttling of the running update-by-query task `task_id`
  ([Update by query rethrottle API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-update-by-query-rethrottle)).

  `requests_per_second` is sent as the required query-string parameter.
  """
  @spec update_by_query_rethrottle(id(), number(), keyword()) :: result()
  def update_by_query_rethrottle(task_id, requests_per_second, opts \\ []) do
    rethrottle("/_update_by_query", task_id, requests_per_second, opts)
  end

  @doc """
  Like `update_by_query_rethrottle/3`, but returns the body directly or raises
  the error exception.
  """
  @spec update_by_query_rethrottle!(id(), number(), keyword()) :: body()
  def update_by_query_rethrottle!(task_id, requests_per_second, opts \\ []) do
    task_id |> update_by_query_rethrottle(requests_per_second, opts) |> Dowser.unwrap()
  end

  @doc """
  Changes the throttling of the running reindex task `task_id`
  ([Reindex rethrottle API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-reindex-rethrottle)).

  `requests_per_second` is sent as the required query-string parameter.
  """
  @spec reindex_rethrottle(id(), number(), keyword()) :: result()
  def reindex_rethrottle(task_id, requests_per_second, opts \\ []) do
    rethrottle("/_reindex", task_id, requests_per_second, opts)
  end

  @doc """
  Like `reindex_rethrottle/3`, but returns the body directly or raises the
  error exception.
  """
  @spec reindex_rethrottle!(id(), number(), keyword()) :: body()
  def reindex_rethrottle!(task_id, requests_per_second, opts \\ []) do
    task_id |> reindex_rethrottle(requests_per_second, opts) |> Dowser.unwrap()
  end

  ## Public functions — term vectors

  @doc """
  Returns term and field statistics for a stored or artificial document
  ([Term vectors API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-termvectors)).

  `body` is the request body (e.g. `doc`, `fields`, `filter`); pass `%{}` to
  send nothing.

  ## Options

    * `:id` — stored document id; absent when analyzing a `doc` from the body.
  """
  @spec termvectors(map(), index(), keyword()) :: result()
  def termvectors(%{} = body, index, opts \\ []) do
    {id, opts} = Keyword.pop(opts, :id)

    suffix =
      if id do
        "/_termvectors/" <> URI.encode(id)
      else
        "/_termvectors"
      end

    index
    |> Helpers.required_path(suffix)
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `termvectors/3`, but returns the body directly or raises the error
  exception.
  """
  @spec termvectors!(map(), index(), keyword()) :: body()
  def termvectors!(%{} = body, index, opts \\ []) do
    body |> termvectors(index, opts) |> Dowser.unwrap()
  end

  @doc """
  Returns term vectors for several documents in one request
  ([Multi term vectors API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-mtermvectors)).

  `body` is the request body, e.g. `%{docs: [...]}` or `%{ids: [...]}`.

  ## Options

    * `:index` — index target; absent when each doc names its own.
  """
  @spec mtermvectors(map(), keyword()) :: result()
  def mtermvectors(%{} = body, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_mtermvectors")
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `mtermvectors/2`, but returns the body directly or raises the error
  exception.
  """
  @spec mtermvectors!(map(), keyword()) :: body()
  def mtermvectors!(%{} = body, opts \\ []) do
    body |> mtermvectors(opts) |> Dowser.unwrap()
  end

  ## Repository metadata

  # Index-related functions exposed to `Dowser.Elasticsearch.Repository`:
  # `{index_spec, arity, kind}` where index_spec is :opts (`:index` option) or
  # {:pos, n} (positional index argument), and kind selects the variants
  # (:pair for `!`, :predicate for `?`).
  @doc false
  def __repository__ do
    [
      index: {{:pos, 1}, 3, :pair},
      create: {{:pos, 1}, 4, :pair},
      get: {{:pos, 0}, 3, :pair},
      delete: {{:pos, 0}, 3, :pair},
      exists: {{:pos, 0}, 3, :predicate},
      get_source: {{:pos, 0}, 3, :pair},
      source_exists: {{:pos, 0}, 3, :predicate},
      update: {{:pos, 1}, 4, :pair},
      bulk: {:opts, 2, :pair},
      mget: {:opts, 2, :pair},
      delete_by_query: {{:pos, 1}, 3, :pair},
      update_by_query: {{:pos, 1}, 3, :pair},
      termvectors: {{:pos, 1}, 3, :pair},
      mtermvectors: {:opts, 2, :pair}
    ]
  end

  ## Private functions

  # HEAD responses have no body, so the response format defaults to :raw.
  @spec head(String.t(), keyword()) :: exists_result()
  defp head(path, opts) do
    opts = Helpers.put_default_format(opts, :resp_format, :raw)

    :head
    |> Client.request(path, nil, opts)
    |> Helpers.parse_exists()
  end

  @spec rethrottle(String.t(), id(), number(), keyword()) :: result()
  defp rethrottle(prefix, task_id, requests_per_second, opts) do
    opts = Helpers.put_param(opts, :requests_per_second, requests_per_second)

    (prefix <> "/" <> URI.encode(task_id) <> "/_rethrottle")
    |> Client.post(nil, opts)
    |> Helpers.parse_result()
  end
end

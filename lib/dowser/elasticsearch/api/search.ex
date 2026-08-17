defmodule Dowser.Elasticsearch.Search do
  @moduledoc """
  The Elasticsearch search APIs — every endpoint tagged `search` in the
  [Elasticsearch OpenAPI specification](https://github.com/elastic/elasticsearch-specification).

  Built on `Dowser.Client`. Required Elasticsearch attributes are positional
  arguments; everything optional lives in `opts`. Request bodies come first so
  they pipe naturally.

  ## Shared conventions

    * `:index` — where the endpoint accepts an optional index target:
      `nil`/absent for all indices, a single index string, or a list of index
      strings (joined with `,`). Endpoints that *require* an index take it as
      the first argument instead.
    * Endpoints that accept a request body take it as their first argument,
      required — pass `%{}` to send nothing. The argument is named `query`
      when the body is an Elasticsearch query DSL document, and `body` (or a
      more specific name such as `template` or `searches`) otherwise.
    * When Elasticsearch serves an operation over both `GET` and `POST`, the
      request uses `POST` whenever a body is present and `GET` otherwise.

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
  @type query :: map()
  @type id :: String.t()
  @type scroll_id :: String.t() | [String.t()]
  @type body :: term()
  @type result :: {:ok, body()} | {:error, Exception.t()}

  ## Public functions — search

  @doc """
  Runs a search against one, several, or all indices
  ([Search API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-search)).

  `query` is the search body (the Elasticsearch query DSL as a map); pass `%{}`
  to match everything. It comes first so it can be piped:

      %{query: %{match: %{title: "hello"}}}
      |> Dowser.Elasticsearch.Search.search(index: "posts")

  Every key in the response is cast per `:keys`. Wherever `:type_codec` is
  configured (see `Dowser.Elasticsearch.Codec`), each hit's `_source` is
  additionally cast against its own index mapping (dates become `DateTime`,
  IPs become `:inet` tuples, and so on) — automatically, at any nesting
  depth, so `msearch/2`, `search_template/2`, `scroll/2` and the rest get the
  same treatment with no extra options.

  ## Options

    * `:index` — `nil`/absent for all indices, a single index string, or a list
      of index strings (joined with `,`).
  """
  @spec search(query(), keyword()) :: result()
  def search(%{} = query, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_search")
    |> Client.post(query, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `search/2`, but returns the body directly or raises the error exception.
  """
  @spec search!(query(), keyword()) :: body()
  def search!(%{} = query, opts \\ []) do
    query |> search(opts) |> Dowser.unwrap()
  end

  @doc """
  Runs several searches in one request
  ([Multi search API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-msearch)).

  `searches` is a flat list alternating header and body maps, encoded as
  NDJSON:

      Dowser.Elasticsearch.Search.msearch([
        %{},
        %{query: %{match_all: %{}}},
        %{index: "comments"},
        %{query: %{match: %{body: "hello"}}}
      ])

  ## Options

    * `:index` — default index target for searches whose header has none.
  """
  @spec msearch([map()], keyword()) :: result()
  def msearch(searches, opts \\ []) when is_list(searches) do
    {index, opts} = Keyword.pop(opts, :index)
    opts = Helpers.put_default_format(opts, :req_format, :ndjson)

    index
    |> Helpers.path("/_msearch")
    |> Client.post(searches, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `msearch/2`, but returns the body directly or raises the error exception.
  """
  @spec msearch!([map()], keyword()) :: body()
  def msearch!(searches, opts \\ []) do
    searches |> msearch(opts) |> Dowser.unwrap()
  end

  @doc """
  Counts the documents matching a query
  ([Count API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-count)).

  `query` is the count body (query DSL map); pass `%{}` to count everything.

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec count(query(), keyword()) :: result()
  def count(%{} = query, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_count")
    |> Client.post(query, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `count/2`, but returns the body directly or raises the error exception.
  """
  @spec count!(query(), keyword()) :: body()
  def count!(%{} = query, opts \\ []) do
    query |> count(opts) |> Dowser.unwrap()
  end

  @doc """
  Explains whether and how the document `id` in `index` matches a query
  ([Explain API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-explain)).

  `query` is the explain body (query DSL map).
  """
  @spec explain(query(), index(), id(), keyword()) :: result()
  def explain(%{} = query, index, id, opts \\ []) do
    index
    |> Helpers.required_path("/_explain/" <> URI.encode(id))
    |> Client.post(query, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `explain/4`, but returns the body directly or raises the error exception.
  """
  @spec explain!(query(), index(), id(), keyword()) :: body()
  def explain!(%{} = query, index, id, opts \\ []) do
    query |> explain(index, id, opts) |> Dowser.unwrap()
  end

  @doc """
  Returns the capabilities of fields across indices
  ([Field capabilities API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-field-caps)).

  `body` is the request body, e.g.
  `%{fields: ["title"], index_filter: %{...}}`.

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec field_caps(map(), keyword()) :: result()
  def field_caps(%{} = body, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_field_caps")
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `field_caps/2`, but returns the body directly or raises the error
  exception.
  """
  @spec field_caps!(map(), keyword()) :: body()
  def field_caps!(%{} = body, opts \\ []) do
    body |> field_caps(opts) |> Dowser.unwrap()
  end

  @doc """
  Returns the indices and shards a search would run against
  ([Search shards API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-search-shards)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec search_shards(keyword()) :: result()
  def search_shards(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_search_shards")
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `search_shards/1`, but returns the body directly or raises the error
  exception.
  """
  @spec search_shards!(keyword()) :: body()
  def search_shards!(opts \\ []) do
    opts |> search_shards() |> Dowser.unwrap()
  end

  @doc """
  Enumerates the terms of a field that match a partial string
  ([Terms enum API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-terms-enum)).

  `body` is the request body and must include `field`, e.g.
  `%{field: "title", string: "he"}`.
  """
  @spec terms_enum(map(), index(), keyword()) :: result()
  def terms_enum(%{} = body, index, opts \\ []) do
    index
    |> Helpers.required_path("/_terms_enum")
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `terms_enum/3`, but returns the body directly or raises the error
  exception.
  """
  @spec terms_enum!(map(), index(), keyword()) :: body()
  def terms_enum!(%{} = body, index, opts \\ []) do
    body |> terms_enum(index, opts) |> Dowser.unwrap()
  end

  @doc """
  Searches a vector tile for geospatial values
  ([Vector tile search API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-search-mvt)).

  `body` is the request body (e.g. `query`, `fields`, `grid_agg`); pass `%{}`
  to send nothing. Returns the binary Mapbox vector tile, so the response
  format defaults to `:raw` (override with `:resp_format`/`:format`).
  """
  @spec search_mvt(map(), index(), String.t(), integer(), integer(), integer(), keyword()) ::
          result()
  def search_mvt(%{} = body, index, field, zoom, x, y, opts \\ []) do
    opts = Helpers.put_default_format(opts, :resp_format, :raw)

    index
    |> Helpers.required_path("/_mvt/#{URI.encode(field)}/#{zoom}/#{x}/#{y}")
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `search_mvt/7`, but returns the body directly or raises the error
  exception.
  """
  @spec search_mvt!(map(), index(), String.t(), integer(), integer(), integer(), keyword()) ::
          body()
  def search_mvt!(%{} = body, index, field, zoom, x, y, opts \\ []) do
    body |> search_mvt(index, field, zoom, x, y, opts) |> Dowser.unwrap()
  end

  ## Public functions — templates

  @doc """
  Runs a search with a stored or inline search template
  ([Search template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-search-template)).

  `template` is the request body, e.g. `%{id: "my-template", params: %{...}}`
  or `%{source: %{...}, params: %{...}}`.

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec search_template(map(), keyword()) :: result()
  def search_template(%{} = template, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_search/template")
    |> Client.post(template, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `search_template/2`, but returns the body directly or raises the error
  exception.
  """
  @spec search_template!(map(), keyword()) :: body()
  def search_template!(%{} = template, opts \\ []) do
    template |> search_template(opts) |> Dowser.unwrap()
  end

  @doc """
  Runs several template searches in one request
  ([Multi search template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-msearch-template)).

  `searches` is a flat list alternating header and template-body maps, encoded
  as NDJSON (see `msearch/2`).

  ## Options

    * `:index` — default index target for searches whose header has none.
  """
  @spec msearch_template([map()], keyword()) :: result()
  def msearch_template(searches, opts \\ []) when is_list(searches) do
    {index, opts} = Keyword.pop(opts, :index)
    opts = Helpers.put_default_format(opts, :req_format, :ndjson)

    index
    |> Helpers.path("/_msearch/template")
    |> Client.post(searches, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `msearch_template/2`, but returns the body directly or raises the error
  exception.
  """
  @spec msearch_template!([map()], keyword()) :: body()
  def msearch_template!(searches, opts \\ []) do
    searches |> msearch_template(opts) |> Dowser.unwrap()
  end

  @doc """
  Renders the stored search template `id` into an actual search body
  ([Render search template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-render-search-template)).

  `template` is the request body, typically `%{params: %{...}}`.
  """
  @spec render_search_template(map(), id(), keyword()) :: result()
  def render_search_template(%{} = template, id, opts \\ []) do
    ("/_render/template/" <> URI.encode(id))
    |> Client.post(template, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `render_search_template/3`, but returns the body directly or raises the
  error exception.
  """
  @spec render_search_template!(map(), id(), keyword()) :: body()
  def render_search_template!(%{} = template, id, opts \\ []) do
    template |> render_search_template(id, opts) |> Dowser.unwrap()
  end

  @doc """
  Evaluates the quality of ranked search results over a set of typical queries
  ([Ranking evaluation API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-rank-eval)).

  `requests` is the list of rated requests.

  ## Options

    * `:index` — index target; absent for all indices.
    * `:metric` — the evaluation metric, merged into the body alongside
      `requests`.
  """
  @spec rank_eval([map()], keyword()) :: result()
  def rank_eval(requests, opts \\ []) when is_list(requests) do
    {index, opts} = Keyword.pop(opts, :index)
    {metric, opts} = Keyword.pop(opts, :metric)

    body =
      if metric do
        %{requests: requests, metric: metric}
      else
        %{requests: requests}
      end

    index
    |> Helpers.path("/_rank_eval")
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `rank_eval/2`, but returns the body directly or raises the error
  exception.
  """
  @spec rank_eval!([map()], keyword()) :: body()
  def rank_eval!(requests, opts \\ []) do
    requests |> rank_eval(opts) |> Dowser.unwrap()
  end

  ## Public functions — async search

  @doc """
  Submits a search that runs asynchronously
  ([Submit async search API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-async-search-submit)).

  `query` is the search body, exactly as in `search/2`.

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec submit_async_search(query(), keyword()) :: result()
  def submit_async_search(%{} = query, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_async_search")
    |> Client.post(query, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `submit_async_search/2`, but returns the body directly or raises the
  error exception.
  """
  @spec submit_async_search!(query(), keyword()) :: body()
  def submit_async_search!(%{} = query, opts \\ []) do
    query |> submit_async_search(opts) |> Dowser.unwrap()
  end

  @doc """
  Retrieves the results of the async search `id`
  ([Get async search API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-async-search-get)).
  """
  @spec get_async_search(id(), keyword()) :: result()
  def get_async_search(id, opts \\ []) do
    ("/_async_search/" <> URI.encode(id))
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get_async_search/2`, but returns the body directly or raises the error
  exception.
  """
  @spec get_async_search!(id(), keyword()) :: body()
  def get_async_search!(id, opts \\ []) do
    id |> get_async_search(opts) |> Dowser.unwrap()
  end

  @doc """
  Retrieves the status of the async search `id`, without its results
  ([Get async search status API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-async-search-status)).
  """
  @spec get_async_search_status(id(), keyword()) :: result()
  def get_async_search_status(id, opts \\ []) do
    ("/_async_search/status/" <> URI.encode(id))
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get_async_search_status/2`, but returns the body directly or raises the
  error exception.
  """
  @spec get_async_search_status!(id(), keyword()) :: body()
  def get_async_search_status!(id, opts \\ []) do
    id |> get_async_search_status(opts) |> Dowser.unwrap()
  end

  @doc """
  Cancels the async search `id` and deletes its results
  ([Delete async search API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-async-search-delete)).
  """
  @spec delete_async_search(id(), keyword()) :: result()
  def delete_async_search(id, opts \\ []) do
    ("/_async_search/" <> URI.encode(id))
    |> Client.delete(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `delete_async_search/2`, but returns the body directly or raises the
  error exception.
  """
  @spec delete_async_search!(id(), keyword()) :: body()
  def delete_async_search!(id, opts \\ []) do
    id |> delete_async_search(opts) |> Dowser.unwrap()
  end

  ## Public functions — scroll

  @doc """
  Fetches the next page of a scrolling search
  ([Scroll API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-scroll)).

  Sends `scroll_id` in the request body, the form Elasticsearch recommends.

  ## Options

    * `:scroll` — how long to keep the scroll context alive, e.g. `"1m"`;
      merged into the body.
  """
  @spec scroll(id(), keyword()) :: result()
  def scroll(scroll_id, opts \\ []) do
    {keep_alive, opts} = Keyword.pop(opts, :scroll)

    body =
      if keep_alive do
        %{scroll_id: scroll_id, scroll: keep_alive}
      else
        %{scroll_id: scroll_id}
      end

    "/_search/scroll"
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `scroll/2`, but returns the body directly or raises the error exception.
  """
  @spec scroll!(id(), keyword()) :: body()
  def scroll!(scroll_id, opts \\ []) do
    scroll_id |> scroll(opts) |> Dowser.unwrap()
  end

  @doc """
  Releases one or several scroll contexts
  ([Clear scroll API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-clear-scroll)).

  `scroll_id` is a scroll id, a list of scroll ids, or `"_all"`.
  """
  @spec clear_scroll(scroll_id(), keyword()) :: result()
  def clear_scroll(scroll_id, opts \\ []) do
    "/_search/scroll"
    |> Client.delete(%{scroll_id: scroll_id}, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `clear_scroll/2`, but returns the body directly or raises the error
  exception.
  """
  @spec clear_scroll!(scroll_id(), keyword()) :: body()
  def clear_scroll!(scroll_id, opts \\ []) do
    scroll_id |> clear_scroll(opts) |> Dowser.unwrap()
  end

  ## Public functions — point in time

  @doc """
  Opens a point in time over `index` for use in later searches
  ([Open point in time API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-open-point-in-time)).

  `body` is the request body (e.g. `index_filter`); pass `%{}` to send
  nothing. `keep_alive` is how long the point in time is kept alive, e.g.
  `"1m"`; it is sent as the required `keep_alive` query-string parameter.
  """
  @spec open_point_in_time(map(), index(), String.t(), keyword()) :: result()
  def open_point_in_time(%{} = body, index, keep_alive, opts \\ []) do
    opts = Helpers.put_param(opts, :keep_alive, keep_alive)

    index
    |> Helpers.required_path("/_pit")
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `open_point_in_time/4`, but returns the body directly or raises the
  error exception.
  """
  @spec open_point_in_time!(map(), index(), String.t(), keyword()) :: body()
  def open_point_in_time!(%{} = body, index, keep_alive, opts \\ []) do
    body |> open_point_in_time(index, keep_alive, opts) |> Dowser.unwrap()
  end

  @doc """
  Closes the point in time `id`
  ([Close point in time API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-close-point-in-time)).
  """
  @spec close_point_in_time(id(), keyword()) :: result()
  def close_point_in_time(id, opts \\ []) do
    "/_pit"
    |> Client.delete(%{id: id}, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `close_point_in_time/2`, but returns the body directly or raises the
  error exception.
  """
  @spec close_point_in_time!(id(), keyword()) :: body()
  def close_point_in_time!(id, opts \\ []) do
    id |> close_point_in_time(opts) |> Dowser.unwrap()
  end

  ## Repository metadata

  # Index-related functions exposed to `Dowser.Elasticsearch.Repository`:
  # `{index_spec, arity, kind}` where index_spec is :opts (`:index` option) or
  # {:pos, n} (positional index argument), and kind selects the variants
  # (:pair for `!`, :predicate for `?`).
  @doc false
  def __repository__ do
    [
      search: {:opts, 2, :pair},
      msearch: {:opts, 2, :pair},
      count: {:opts, 2, :pair},
      explain: {{:pos, 1}, 4, :pair},
      field_caps: {:opts, 2, :pair},
      search_shards: {:opts, 1, :pair},
      terms_enum: {{:pos, 1}, 3, :pair},
      search_mvt: {{:pos, 1}, 7, :pair},
      search_template: {:opts, 2, :pair},
      msearch_template: {:opts, 2, :pair},
      rank_eval: {:opts, 2, :pair},
      submit_async_search: {:opts, 2, :pair},
      open_point_in_time: {{:pos, 1}, 4, :pair}
    ]
  end
end

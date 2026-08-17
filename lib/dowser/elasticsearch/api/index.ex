defmodule Dowser.Elasticsearch.Index do
  @moduledoc """
  The Elasticsearch indices APIs — every endpoint tagged `indices` in the
  [Elasticsearch OpenAPI specification](https://github.com/elastic/elasticsearch-specification)
  (index management, mappings, settings, aliases, templates, dangling indices,
  …) — plus `segment/1`, the index-target helper used by all API modules.

  Built on `Dowser.Client`. Required Elasticsearch attributes are positional
  arguments; everything optional lives in `opts`.

  ## Shared conventions

    * An *index target* may be `nil` (all indices), a single index/alias/
      data-stream name (string or atom), or a list of them (joined with `,`).
      Endpoints that accept an optional target take it as the `:index` option;
      endpoints that require one take it as the first argument.
    * Path parameters such as `name`, `fields` or `metric` accept the same
      shapes as an index target.
    * Endpoints that accept a request body take it as their first argument,
      required — pass `%{}` to send nothing.
    * `HEAD` existence checks come as a pair where the `?` variant plays the
      bang role: `index_exists/2` returns `{:ok, boolean()}` or
      `{:error, exception}`, `index_exists?/2` returns the bare boolean
      (`404` → `false`) and raises on genuine errors.

  All remaining options are forwarded to `Dowser.Client.request/4`, e.g.
  `:config`, `:params` (query-string parameters), `:format`, `:http_adapter`,
  `:json_adapter` and `:http_opts` (including `:headers`).

  On a 2xx response every function returns `{:ok, body}` with the decoded
  response body. A non-2xx response returns
  `{:error, %Dowser.Elasticsearch.Error{}}`; a transport, encoding or decoding
  failure returns `{:error, exception}` from `Dowser.Client`. Each function has
  a bang variant that returns the body directly or raises the error exception.
  """

  alias Dowser.Client
  alias Dowser.Elasticsearch.Helpers

  ## Typespecs

  @typedoc "No index (all), a single index, or several indices."
  @type t :: nil | String.t() | atom() | [String.t() | atom()]

  @typedoc "A path parameter: a single name, or several (joined with `,`)."
  @type name :: String.t() | atom() | [String.t() | atom()]

  @type body :: term()
  @type result :: {:ok, body()} | {:error, Exception.t()}
  @type exists_result :: {:ok, boolean()} | {:error, Exception.t()}

  ## Public functions — index target helper

  @doc """
  Encodes an index target into a comma-separated, URL-encoded path segment.

  Returns `nil` when the target is empty (`nil`, `""` or `[]`), so callers can
  choose between `/_search` and `/posts/_search`.

  ## Examples

      iex> Dowser.Elasticsearch.Index.segment(nil)
      nil

      iex> Dowser.Elasticsearch.Index.segment("posts")
      "posts"

      iex> Dowser.Elasticsearch.Index.segment(["posts", "my comments"])
      "posts,my%20comments"
  """
  @spec segment(t()) :: String.t() | nil
  def segment(index) when index in [nil, "", []] do
    nil
  end

  def segment(index) when is_atom(index) do
    index
    |> Atom.to_string()
    |> URI.encode()
  end

  def segment(index) when is_binary(index) do
    URI.encode(index)
  end

  def segment(indices) when is_list(indices) do
    Enum.map_join(indices, ",", fn
      index when is_atom(index) and not is_nil(index) ->
        index
        |> Atom.to_string()
        |> URI.encode()

      index when is_binary(index) ->
        URI.encode(index)
    end)
  end

  ## Public functions — index management

  @doc """
  Creates the index `index`
  ([Create index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-create)).

  `body` is the request body (e.g. `settings`, `mappings`, `aliases`); pass
  `%{}` to send nothing.
  """
  @spec create_index(map(), t(), keyword()) :: result()
  def create_index(%{} = body, index, opts \\ []) do
    index
    |> Helpers.required_path("")
    |> Client.put(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `create_index/3`, but returns the body directly or raises the error
  exception.
  """
  @spec create_index!(map(), t(), keyword()) :: body()
  def create_index!(%{} = body, index, opts \\ []) do
    body |> create_index(index, opts) |> Dowser.unwrap()
  end

  @doc """
  Deletes one or several indices
  ([Delete index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-delete)).
  """
  @spec delete_index(t(), keyword()) :: result()
  def delete_index(index, opts \\ []) do
    index
    |> Helpers.required_path("")
    |> Client.delete(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `delete_index/2`, but returns the body directly or raises the error
  exception.
  """
  @spec delete_index!(t(), keyword()) :: body()
  def delete_index!(index, opts \\ []) do
    index |> delete_index(opts) |> Dowser.unwrap()
  end

  @doc """
  Returns information about one or several indices
  ([Get index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-get)).
  """
  @spec get_index(t(), keyword()) :: result()
  def get_index(index, opts \\ []) do
    index
    |> Helpers.required_path("")
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get_index/2`, but returns the body directly or raises the error
  exception.
  """
  @spec get_index!(t(), keyword()) :: body()
  def get_index!(index, opts \\ []) do
    index |> get_index(opts) |> Dowser.unwrap()
  end

  @doc """
  Checks whether one or several indices exist
  ([Exists API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-exists)).

  Returns `{:ok, true}`, `{:ok, false}` or `{:error, exception}`.
  """
  @spec index_exists(t(), keyword()) :: exists_result()
  def index_exists(index, opts \\ []) do
    index
    |> Helpers.required_path("")
    |> exists(opts)
  end

  @doc """
  Like `index_exists/2`, but returns the boolean directly (`404` → `false`) or
  raises the error exception.
  """
  @spec index_exists?(t(), keyword()) :: boolean()
  def index_exists?(index, opts \\ []) do
    index |> index_exists(opts) |> Dowser.unwrap()
  end

  @doc """
  Opens one or several closed indices
  ([Open index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-open)).
  """
  @spec open(t(), keyword()) :: result()
  def open(index, opts \\ []) do
    index
    |> Helpers.required_path("/_open")
    |> Client.post(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `open/2`, but returns the body directly or raises the error exception.
  """
  @spec open!(t(), keyword()) :: body()
  def open!(index, opts \\ []) do
    index |> open(opts) |> Dowser.unwrap()
  end

  @doc """
  Closes one or several indices
  ([Close index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-close)).
  """
  @spec close(t(), keyword()) :: result()
  def close(index, opts \\ []) do
    index
    |> Helpers.required_path("/_close")
    |> Client.post(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `close/2`, but returns the body directly or raises the error exception.
  """
  @spec close!(t(), keyword()) :: body()
  def close!(index, opts \\ []) do
    index |> close(opts) |> Dowser.unwrap()
  end

  @doc """
  Adds the block `block` (e.g. `"write"`, `"read_only"`) to one or several
  indices
  ([Add block API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-add-block)).
  """
  @spec add_block(t(), name(), keyword()) :: result()
  def add_block(index, block, opts \\ []) do
    index
    |> Helpers.required_path("/_block/" <> segment!(block, "block"))
    |> Client.put(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `add_block/3`, but returns the body directly or raises the error
  exception.
  """
  @spec add_block!(t(), name(), keyword()) :: body()
  def add_block!(index, block, opts \\ []) do
    index |> add_block(block, opts) |> Dowser.unwrap()
  end

  @doc """
  Removes the block `block` from one or several indices
  ([Remove block API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-remove-block)).
  """
  @spec remove_block(t(), name(), keyword()) :: result()
  def remove_block(index, block, opts \\ []) do
    index
    |> Helpers.required_path("/_block/" <> segment!(block, "block"))
    |> Client.delete(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `remove_block/3`, but returns the body directly or raises the error
  exception.
  """
  @spec remove_block!(t(), name(), keyword()) :: body()
  def remove_block!(index, block, opts \\ []) do
    index |> remove_block(block, opts) |> Dowser.unwrap()
  end

  ## Public functions — mappings

  @doc """
  Updates the mapping of one or several indices
  ([Put mapping API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-put-mapping)).

  `mapping` is the mapping body, e.g. `%{properties: %{title: %{type: "text"}}}`.
  """
  @spec put_mapping(map(), t(), keyword()) :: result()
  def put_mapping(%{} = mapping, index, opts \\ []) do
    index
    |> Helpers.required_path("/_mapping")
    |> Client.post(mapping, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `put_mapping/3`, but returns the body directly or raises the error
  exception.
  """
  @spec put_mapping!(map(), t(), keyword()) :: body()
  def put_mapping!(%{} = mapping, index, opts \\ []) do
    mapping |> put_mapping(index, opts) |> Dowser.unwrap()
  end

  @doc """
  Returns the mapping of one, several, or all indices
  ([Get mapping API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-get-mapping)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec get_mapping(keyword()) :: result()
  def get_mapping(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_mapping")
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get_mapping/1`, but returns the body directly or raises the error
  exception.
  """
  @spec get_mapping!(keyword()) :: body()
  def get_mapping!(opts \\ []) do
    opts |> get_mapping() |> Dowser.unwrap()
  end

  @doc """
  Returns the mapping of one or several fields
  ([Get field mapping API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-get-field-mapping)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec get_field_mapping(name(), keyword()) :: result()
  def get_field_mapping(fields, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_mapping/field/" <> segment!(fields, "fields"))
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get_field_mapping/2`, but returns the body directly or raises the
  error exception.
  """
  @spec get_field_mapping!(name(), keyword()) :: body()
  def get_field_mapping!(fields, opts \\ []) do
    fields |> get_field_mapping(opts) |> Dowser.unwrap()
  end

  ## Public functions — settings

  @doc """
  Updates the settings of one, several, or all indices
  ([Update index settings API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-put-settings)).

  `settings` is the settings body, e.g. `%{index: %{number_of_replicas: 2}}`.

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec put_settings(map(), keyword()) :: result()
  def put_settings(%{} = settings, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_settings")
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
  Returns the settings of one, several, or all indices
  ([Get index settings API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-get-settings)).

  ## Options

    * `:index` — index target; absent for all indices.
    * `:name` — restrict the result to one or several setting names.
  """
  @spec get_settings(keyword()) :: result()
  def get_settings(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)
    {name, opts} = Keyword.pop(opts, :name)

    suffix =
      if name do
        "/_settings/" <> segment!(name, "name")
      else
        "/_settings"
      end

    index
    |> Helpers.path(suffix)
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

  ## Public functions — aliases

  @doc """
  Applies several alias actions atomically
  ([Update aliases API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-update-aliases)).

  `actions` is the list of actions, sent as `%{actions: actions}`, e.g.
  `[%{add: %{index: "posts", alias: "blog"}}]`.
  """
  @spec update_aliases([map()], keyword()) :: result()
  def update_aliases(actions, opts \\ []) when is_list(actions) do
    "/_aliases"
    |> Client.post(%{actions: actions}, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `update_aliases/2`, but returns the body directly or raises the error
  exception.
  """
  @spec update_aliases!([map()], keyword()) :: body()
  def update_aliases!(actions, opts \\ []) do
    actions |> update_aliases(opts) |> Dowser.unwrap()
  end

  @doc """
  Creates or updates the alias `name` on one or several indices
  ([Create or update alias API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-put-alias)).

  `body` is the request body (e.g. `filter`, `routing`); pass `%{}` to send
  nothing.
  """
  @spec put_alias(map(), t(), name(), keyword()) :: result()
  def put_alias(%{} = body, index, name, opts \\ []) do
    index
    |> Helpers.required_path("/_aliases/" <> segment!(name, "name"))
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `put_alias/4`, but returns the body directly or raises the error
  exception.
  """
  @spec put_alias!(map(), t(), name(), keyword()) :: body()
  def put_alias!(%{} = body, index, name, opts \\ []) do
    body |> put_alias(index, name, opts) |> Dowser.unwrap()
  end

  @doc """
  Deletes the alias `name` from one or several indices
  ([Delete alias API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-delete-alias)).
  """
  @spec delete_alias(t(), name(), keyword()) :: result()
  def delete_alias(index, name, opts \\ []) do
    index
    |> Helpers.required_path("/_aliases/" <> segment!(name, "name"))
    |> Client.delete(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `delete_alias/3`, but returns the body directly or raises the error
  exception.
  """
  @spec delete_alias!(t(), name(), keyword()) :: body()
  def delete_alias!(index, name, opts \\ []) do
    index |> delete_alias(name, opts) |> Dowser.unwrap()
  end

  @doc """
  Returns one, several, or all aliases
  ([Get alias API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-get-alias)).

  ## Options

    * `:index` — index target; absent for all indices.
    * `:name` — restrict the result to one or several alias names.
  """
  @spec get_alias(keyword()) :: result()
  def get_alias(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)
    {name, opts} = Keyword.pop(opts, :name)

    suffix =
      if name do
        "/_alias/" <> segment!(name, "name")
      else
        "/_alias"
      end

    index
    |> Helpers.path(suffix)
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get_alias/1`, but returns the body directly or raises the error
  exception.
  """
  @spec get_alias!(keyword()) :: body()
  def get_alias!(opts \\ []) do
    opts |> get_alias() |> Dowser.unwrap()
  end

  @doc """
  Checks whether one or several aliases exist
  ([Alias exists API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-exists-alias)).

  Returns `{:ok, true}`, `{:ok, false}` or `{:error, exception}`.

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec alias_exists(name(), keyword()) :: exists_result()
  def alias_exists(name, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_alias/" <> segment!(name, "name"))
    |> exists(opts)
  end

  @doc """
  Like `alias_exists/2`, but returns the boolean directly (`404` → `false`) or
  raises the error exception.
  """
  @spec alias_exists?(name(), keyword()) :: boolean()
  def alias_exists?(name, opts \\ []) do
    name |> alias_exists(opts) |> Dowser.unwrap()
  end

  ## Public functions — index templates

  @doc """
  Creates or updates the index template `name`
  ([Create or update index template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-put-index-template)).

  `template` is the request body, e.g. `%{index_patterns: ["posts-*"], template: %{...}}`.
  """
  @spec put_index_template(map(), name(), keyword()) :: result()
  def put_index_template(%{} = template, name, opts \\ []) do
    ("/_index_template/" <> segment!(name, "name"))
    |> Client.post(template, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `put_index_template/3`, but returns the body directly or raises the
  error exception.
  """
  @spec put_index_template!(map(), name(), keyword()) :: body()
  def put_index_template!(%{} = template, name, opts \\ []) do
    template |> put_index_template(name, opts) |> Dowser.unwrap()
  end

  @doc """
  Returns one or several index templates
  ([Get index template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-get-index-template)).
  """
  @spec get_index_template(name(), keyword()) :: result()
  def get_index_template(name, opts \\ []) do
    ("/_index_template/" <> segment!(name, "name"))
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get_index_template/2`, but returns the body directly or raises the
  error exception.
  """
  @spec get_index_template!(name(), keyword()) :: body()
  def get_index_template!(name, opts \\ []) do
    name |> get_index_template(opts) |> Dowser.unwrap()
  end

  @doc """
  Deletes one or several index templates
  ([Delete index template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-delete-index-template)).
  """
  @spec delete_index_template(name(), keyword()) :: result()
  def delete_index_template(name, opts \\ []) do
    ("/_index_template/" <> segment!(name, "name"))
    |> Client.delete(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `delete_index_template/2`, but returns the body directly or raises the
  error exception.
  """
  @spec delete_index_template!(name(), keyword()) :: body()
  def delete_index_template!(name, opts \\ []) do
    name |> delete_index_template(opts) |> Dowser.unwrap()
  end

  @doc """
  Checks whether the index template `name` exists
  ([Index template exists API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-exists-index-template)).

  Returns `{:ok, true}`, `{:ok, false}` or `{:error, exception}`.
  """
  @spec index_template_exists(name(), keyword()) :: exists_result()
  def index_template_exists(name, opts \\ []) do
    ("/_index_template/" <> segment!(name, "name"))
    |> exists(opts)
  end

  @doc """
  Like `index_template_exists/2`, but returns the boolean directly
  (`404` → `false`) or raises the error exception.
  """
  @spec index_template_exists?(name(), keyword()) :: boolean()
  def index_template_exists?(name, opts \\ []) do
    name |> index_template_exists(opts) |> Dowser.unwrap()
  end

  @doc """
  Simulates applying the matching index templates to the index `name`
  ([Simulate index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-simulate-index-template)).

  `body` is an optional template body to simulate alongside the existing
  ones; pass `%{}` to send nothing.
  """
  @spec simulate_index_template(map(), name(), keyword()) :: result()
  def simulate_index_template(%{} = body, name, opts \\ []) do
    ("/_index_template/_simulate_index/" <> segment!(name, "name"))
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `simulate_index_template/3`, but returns the body directly or raises
  the error exception.
  """
  @spec simulate_index_template!(map(), name(), keyword()) :: body()
  def simulate_index_template!(%{} = body, name, opts \\ []) do
    body |> simulate_index_template(name, opts) |> Dowser.unwrap()
  end

  @doc """
  Simulates the resolved composition of the index template `name`
  ([Simulate template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-simulate-template)).

  `body` is an optional template body to simulate instead of a stored one;
  pass `%{}` to send nothing.
  """
  @spec simulate_template(map(), name(), keyword()) :: result()
  def simulate_template(%{} = body, name, opts \\ []) do
    ("/_index_template/_simulate/" <> segment!(name, "name"))
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `simulate_template/3`, but returns the body directly or raises the
  error exception.
  """
  @spec simulate_template!(map(), name(), keyword()) :: body()
  def simulate_template!(%{} = body, name, opts \\ []) do
    body |> simulate_template(name, opts) |> Dowser.unwrap()
  end

  ## Public functions — component templates

  @doc """
  Creates or updates the component template `name`
  ([Create or update component template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-put-component-template)).

  `template` is the request body, e.g. `%{template: %{settings: %{...}}}`.
  """
  @spec put_component_template(map(), name(), keyword()) :: result()
  def put_component_template(%{} = template, name, opts \\ []) do
    ("/_component_template/" <> segment!(name, "name"))
    |> Client.post(template, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `put_component_template/3`, but returns the body directly or raises the
  error exception.
  """
  @spec put_component_template!(map(), name(), keyword()) :: body()
  def put_component_template!(%{} = template, name, opts \\ []) do
    template |> put_component_template(name, opts) |> Dowser.unwrap()
  end

  @doc """
  Returns one or several component templates
  ([Get component template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-get-component-template)).
  """
  @spec get_component_template(name(), keyword()) :: result()
  def get_component_template(name, opts \\ []) do
    ("/_component_template/" <> segment!(name, "name"))
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get_component_template/2`, but returns the body directly or raises the
  error exception.
  """
  @spec get_component_template!(name(), keyword()) :: body()
  def get_component_template!(name, opts \\ []) do
    name |> get_component_template(opts) |> Dowser.unwrap()
  end

  @doc """
  Deletes one or several component templates
  ([Delete component template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-delete-component-template)).
  """
  @spec delete_component_template(name(), keyword()) :: result()
  def delete_component_template(name, opts \\ []) do
    ("/_component_template/" <> segment!(name, "name"))
    |> Client.delete(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `delete_component_template/2`, but returns the body directly or raises
  the error exception.
  """
  @spec delete_component_template!(name(), keyword()) :: body()
  def delete_component_template!(name, opts \\ []) do
    name |> delete_component_template(opts) |> Dowser.unwrap()
  end

  @doc """
  Checks whether the component template `name` exists
  ([Component template exists API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cluster-exists-component-template)).

  Returns `{:ok, true}`, `{:ok, false}` or `{:error, exception}`.
  """
  @spec component_template_exists(name(), keyword()) :: exists_result()
  def component_template_exists(name, opts \\ []) do
    ("/_component_template/" <> segment!(name, "name"))
    |> exists(opts)
  end

  @doc """
  Like `component_template_exists/2`, but returns the boolean directly
  (`404` → `false`) or raises the error exception.
  """
  @spec component_template_exists?(name(), keyword()) :: boolean()
  def component_template_exists?(name, opts \\ []) do
    name |> component_template_exists(opts) |> Dowser.unwrap()
  end

  ## Public functions — legacy templates

  @doc """
  Creates or updates the legacy index template `name`
  ([Create or update template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-put-template)).
  """
  @deprecated "Use put_index_template/3 instead"
  @spec put_template(map(), name(), keyword()) :: result()
  def put_template(%{} = template, name, opts \\ []) do
    ("/_template/" <> segment!(name, "name"))
    |> Client.post(template, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `put_template/3`, but returns the body directly or raises the error
  exception.
  """
  @deprecated "Use put_index_template!/3 instead"
  @spec put_template!(map(), name(), keyword()) :: body()
  def put_template!(%{} = template, name, opts \\ []) do
    template |> put_template(name, opts) |> Dowser.unwrap()
  end

  @doc """
  Returns one or several legacy index templates
  ([Get template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-get-template)).
  """
  @deprecated "Use get_index_template/2 instead"
  @spec get_template(name(), keyword()) :: result()
  def get_template(name, opts \\ []) do
    ("/_template/" <> segment!(name, "name"))
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `get_template/2`, but returns the body directly or raises the error
  exception.
  """
  @deprecated "Use get_index_template!/2 instead"
  @spec get_template!(name(), keyword()) :: body()
  def get_template!(name, opts \\ []) do
    name |> get_template(opts) |> Dowser.unwrap()
  end

  @doc """
  Deletes the legacy index template `name`
  ([Delete template API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-delete-template)).
  """
  @deprecated "Use delete_index_template/2 instead"
  @spec delete_template(name(), keyword()) :: result()
  def delete_template(name, opts \\ []) do
    ("/_template/" <> segment!(name, "name"))
    |> Client.delete(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `delete_template/2`, but returns the body directly or raises the error
  exception.
  """
  @deprecated "Use delete_index_template!/2 instead"
  @spec delete_template!(name(), keyword()) :: body()
  def delete_template!(name, opts \\ []) do
    name |> delete_template(opts) |> Dowser.unwrap()
  end

  @doc """
  Checks whether one or several legacy index templates exist
  ([Template exists API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-exists-template)).

  Returns `{:ok, true}`, `{:ok, false}` or `{:error, exception}`.
  """
  @spec template_exists(name(), keyword()) :: exists_result()
  def template_exists(name, opts \\ []) do
    ("/_template/" <> segment!(name, "name"))
    |> exists(opts)
  end

  @doc """
  Like `template_exists/2`, but returns the boolean directly (`404` → `false`)
  or raises the error exception.
  """
  @spec template_exists?(name(), keyword()) :: boolean()
  def template_exists?(name, opts \\ []) do
    name |> template_exists(opts) |> Dowser.unwrap()
  end

  ## Public functions — resizing & rollover

  @doc """
  Clones the index `index` into `target`
  ([Clone index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-clone)).

  `body` is the request body (e.g. `settings`, `aliases`); pass `%{}` to send
  nothing.
  """
  @spec clone(map(), t(), name(), keyword()) :: result()
  def clone(%{} = body, index, target, opts \\ []) do
    index
    |> Helpers.required_path("/_clone/" <> segment!(target, "target"))
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `clone/4`, but returns the body directly or raises the error exception.
  """
  @spec clone!(map(), t(), name(), keyword()) :: body()
  def clone!(%{} = body, index, target, opts \\ []) do
    body |> clone(index, target, opts) |> Dowser.unwrap()
  end

  @doc """
  Shrinks the index `index` into `target`, with fewer primary shards
  ([Shrink index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-shrink)).

  `body` is the request body (e.g. `settings`, `aliases`); pass `%{}` to send
  nothing.
  """
  @spec shrink(map(), t(), name(), keyword()) :: result()
  def shrink(%{} = body, index, target, opts \\ []) do
    index
    |> Helpers.required_path("/_shrink/" <> segment!(target, "target"))
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `shrink/4`, but returns the body directly or raises the error exception.
  """
  @spec shrink!(map(), t(), name(), keyword()) :: body()
  def shrink!(%{} = body, index, target, opts \\ []) do
    body |> shrink(index, target, opts) |> Dowser.unwrap()
  end

  @doc """
  Splits the index `index` into `target`, with more primary shards
  ([Split index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-split)).

  `body` is the request body (e.g. `settings`, `aliases`); pass `%{}` to send
  nothing.
  """
  @spec split(map(), t(), name(), keyword()) :: result()
  def split(%{} = body, index, target, opts \\ []) do
    index
    |> Helpers.required_path("/_split/" <> segment!(target, "target"))
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `split/4`, but returns the body directly or raises the error exception.
  """
  @spec split!(map(), t(), name(), keyword()) :: body()
  def split!(%{} = body, index, target, opts \\ []) do
    body |> split(index, target, opts) |> Dowser.unwrap()
  end

  @doc """
  Rolls the rollover target `target` (an alias or data stream) over to a new
  index
  ([Rollover API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-rollover)).

  `body` is the request body (e.g. `conditions`, `settings`, `mappings`,
  `aliases`); pass `%{}` to send nothing.

  ## Options

    * `:new_index` — explicit name for the new index; absent to let
      Elasticsearch derive it.
  """
  @spec rollover(map(), name(), keyword()) :: result()
  def rollover(%{} = body, target, opts \\ []) do
    {new_index, opts} = Keyword.pop(opts, :new_index)
    rollover_path = "/" <> segment!(target, "target") <> "/_rollover"

    rollover_path =
      if new_index do
        rollover_path <> "/" <> segment!(new_index, "new_index")
      else
        rollover_path
      end

    rollover_path
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `rollover/3`, but returns the body directly or raises the error
  exception.
  """
  @spec rollover!(map(), name(), keyword()) :: body()
  def rollover!(%{} = body, target, opts \\ []) do
    body |> rollover(target, opts) |> Dowser.unwrap()
  end

  ## Public functions — maintenance

  @doc """
  Refreshes one, several, or all indices
  ([Refresh API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-refresh)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec refresh(keyword()) :: result()
  def refresh(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_refresh")
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `refresh/1`, but returns the body directly or raises the error
  exception.
  """
  @spec refresh!(keyword()) :: body()
  def refresh!(opts \\ []) do
    opts |> refresh() |> Dowser.unwrap()
  end

  @doc """
  Flushes one, several, or all indices
  ([Flush API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-flush)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec flush(keyword()) :: result()
  def flush(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_flush")
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `flush/1`, but returns the body directly or raises the error exception.
  """
  @spec flush!(keyword()) :: body()
  def flush!(opts \\ []) do
    opts |> flush() |> Dowser.unwrap()
  end

  @doc """
  Force-merges the segments of one, several, or all indices
  ([Force merge API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-forcemerge)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec forcemerge(keyword()) :: result()
  def forcemerge(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_forcemerge")
    |> Client.post(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `forcemerge/1`, but returns the body directly or raises the error
  exception.
  """
  @spec forcemerge!(keyword()) :: body()
  def forcemerge!(opts \\ []) do
    opts |> forcemerge() |> Dowser.unwrap()
  end

  @doc """
  Clears the caches of one, several, or all indices
  ([Clear cache API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-clear-cache)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec clear_cache(keyword()) :: result()
  def clear_cache(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_cache/clear")
    |> Client.post(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `clear_cache/1`, but returns the body directly or raises the error
  exception.
  """
  @spec clear_cache!(keyword()) :: body()
  def clear_cache!(opts \\ []) do
    opts |> clear_cache() |> Dowser.unwrap()
  end

  ## Public functions — monitoring

  @doc """
  Returns statistics for one, several, or all indices
  ([Index stats API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-stats)).

  ## Options

    * `:index` — index target; absent for all indices.
    * `:metric` — restrict the result to one or several metrics.
  """
  @spec stats(keyword()) :: result()
  def stats(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)
    {metric, opts} = Keyword.pop(opts, :metric)

    suffix =
      if metric do
        "/_stats/" <> segment!(metric, "metric")
      else
        "/_stats"
      end

    index
    |> Helpers.path(suffix)
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
  Returns the shard segments of one, several, or all indices
  ([Segments API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-segments)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec segments(keyword()) :: result()
  def segments(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_segments")
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
  Returns shard-recovery information for one, several, or all indices
  ([Index recovery API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-recovery)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec recovery(keyword()) :: result()
  def recovery(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_recovery")
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
  Returns shard-store information for one, several, or all indices
  ([Shard stores API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-shard-stores)).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec shard_stores(keyword()) :: result()
  def shard_stores(opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_shard_stores")
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `shard_stores/1`, but returns the body directly or raises the error
  exception.
  """
  @spec shard_stores!(keyword()) :: body()
  def shard_stores!(opts \\ []) do
    opts |> shard_stores() |> Dowser.unwrap()
  end

  @doc """
  Analyzes the disk usage of each field of one or several indices
  ([Disk usage API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-disk-usage)).
  """
  @spec disk_usage(t(), keyword()) :: result()
  def disk_usage(index, opts \\ []) do
    index
    |> Helpers.required_path("/_disk_usage")
    |> Client.post(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `disk_usage/2`, but returns the body directly or raises the error
  exception.
  """
  @spec disk_usage!(t(), keyword()) :: body()
  def disk_usage!(index, opts \\ []) do
    index |> disk_usage(opts) |> Dowser.unwrap()
  end

  @doc """
  Returns field-usage statistics for one or several indices
  ([Field usage stats API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-field-usage-stats)).
  """
  @spec field_usage_stats(t(), keyword()) :: result()
  def field_usage_stats(index, opts \\ []) do
    index
    |> Helpers.required_path("/_field_usage_stats")
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `field_usage_stats/2`, but returns the body directly or raises the
  error exception.
  """
  @spec field_usage_stats!(t(), keyword()) :: body()
  def field_usage_stats!(index, opts \\ []) do
    index |> field_usage_stats(opts) |> Dowser.unwrap()
  end

  ## Public functions — analysis & validation

  @doc """
  Runs text through an analyzer
  ([Analyze API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-analyze)).

  `body` is the request body, e.g. `%{analyzer: "standard", text: "hello"}`.

  ## Options

    * `:index` — index whose analyzers to use; absent for the cluster default.
  """
  @spec analyze(map(), keyword()) :: result()
  def analyze(%{} = body, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_analyze")
    |> Client.post(body, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `analyze/2`, but returns the body directly or raises the error
  exception.
  """
  @spec analyze!(map(), keyword()) :: body()
  def analyze!(%{} = body, opts \\ []) do
    body |> analyze(opts) |> Dowser.unwrap()
  end

  @doc """
  Validates a query without running it
  ([Validate query API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-validate-query)).

  `query` is the validate body (query DSL map).

  ## Options

    * `:index` — index target; absent for all indices.
  """
  @spec validate_query(map(), keyword()) :: result()
  def validate_query(%{} = query, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)

    index
    |> Helpers.path("/_validate/query")
    |> Client.post(query, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `validate_query/2`, but returns the body directly or raises the error
  exception.
  """
  @spec validate_query!(map(), keyword()) :: body()
  def validate_query!(%{} = query, opts \\ []) do
    query |> validate_query(opts) |> Dowser.unwrap()
  end

  @doc """
  Reloads the search analyzers of one or several indices
  ([Reload search analyzers API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-reload-search-analyzers)).
  """
  @spec reload_search_analyzers(t(), keyword()) :: result()
  def reload_search_analyzers(index, opts \\ []) do
    index
    |> Helpers.required_path("/_reload_search_analyzers")
    |> Client.post(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `reload_search_analyzers/2`, but returns the body directly or raises
  the error exception.
  """
  @spec reload_search_analyzers!(t(), keyword()) :: body()
  def reload_search_analyzers!(index, opts \\ []) do
    index |> reload_search_analyzers(opts) |> Dowser.unwrap()
  end

  ## Public functions — dangling indices

  @doc """
  Lists the dangling indices of the cluster
  ([List dangling indices API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-dangling-indices-list-dangling-indices)).
  """
  @spec list_dangling_indices(keyword()) :: result()
  def list_dangling_indices(opts \\ []) do
    "/_dangling"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `list_dangling_indices/1`, but returns the body directly or raises the
  error exception.
  """
  @spec list_dangling_indices!(keyword()) :: body()
  def list_dangling_indices!(opts \\ []) do
    opts |> list_dangling_indices() |> Dowser.unwrap()
  end

  @doc """
  Imports the dangling index `index_uuid`
  ([Import dangling index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-dangling-indices-import-dangling-index)).

  Requires `params: [accept_data_loss: true]`.
  """
  @spec import_dangling_index(id :: String.t(), keyword()) :: result()
  def import_dangling_index(index_uuid, opts \\ []) do
    ("/_dangling/" <> URI.encode(index_uuid))
    |> Client.post(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `import_dangling_index/2`, but returns the body directly or raises the
  error exception.
  """
  @spec import_dangling_index!(id :: String.t(), keyword()) :: body()
  def import_dangling_index!(index_uuid, opts \\ []) do
    index_uuid |> import_dangling_index(opts) |> Dowser.unwrap()
  end

  @doc """
  Deletes the dangling index `index_uuid`
  ([Delete dangling index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-dangling-indices-delete-dangling-index)).

  Requires `params: [accept_data_loss: true]`.
  """
  @spec delete_dangling_index(id :: String.t(), keyword()) :: result()
  def delete_dangling_index(index_uuid, opts \\ []) do
    ("/_dangling/" <> URI.encode(index_uuid))
    |> Client.delete(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `delete_dangling_index/2`, but returns the body directly or raises the
  error exception.
  """
  @spec delete_dangling_index!(id :: String.t(), keyword()) :: body()
  def delete_dangling_index!(index_uuid, opts \\ []) do
    index_uuid |> delete_dangling_index(opts) |> Dowser.unwrap()
  end

  ## Public functions — resolve

  @doc """
  Resolves names (with wildcards) to indices, aliases and data streams
  ([Resolve index API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-resolve-index)).
  """
  @spec resolve_index(name(), keyword()) :: result()
  def resolve_index(name, opts \\ []) do
    ("/_resolve/index/" <> segment!(name, "name"))
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `resolve_index/2`, but returns the body directly or raises the error
  exception.
  """
  @spec resolve_index!(name(), keyword()) :: body()
  def resolve_index!(name, opts \\ []) do
    name |> resolve_index(opts) |> Dowser.unwrap()
  end

  @doc """
  Resolves cluster expressions (for cross-cluster search) and reports each
  remote's availability
  ([Resolve cluster API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-resolve-cluster)).
  """
  @spec resolve_cluster(name(), keyword()) :: result()
  def resolve_cluster(name, opts \\ []) do
    ("/_resolve/cluster/" <> segment!(name, "name"))
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `resolve_cluster/2`, but returns the body directly or raises the error
  exception.
  """
  @spec resolve_cluster!(name(), keyword()) :: body()
  def resolve_cluster!(name, opts \\ []) do
    name |> resolve_cluster(opts) |> Dowser.unwrap()
  end

  ## Public functions — data-stream lifecycle

  @doc """
  Removes the lifecycle from one or several data streams
  ([Delete data lifecycle API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-delete-data-lifecycle)).
  """
  @spec delete_data_lifecycle(name(), keyword()) :: result()
  def delete_data_lifecycle(name, opts \\ []) do
    ("/_data_stream/" <> segment!(name, "name") <> "/_lifecycle")
    |> Client.delete(nil, opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `delete_data_lifecycle/2`, but returns the body directly or raises the
  error exception.
  """
  @spec delete_data_lifecycle!(name(), keyword()) :: body()
  def delete_data_lifecycle!(name, opts \\ []) do
    name |> delete_data_lifecycle(opts) |> Dowser.unwrap()
  end

  ## Repository metadata

  # Index-related functions exposed to `Dowser.Elasticsearch.Repository`:
  # `{index_spec, arity, kind}` where index_spec is :opts (`:index` option) or
  # {:pos, n} (positional index argument), and kind selects the variants
  # (:pair for `!`, :predicate for `?`). Functions that do not target an index
  # (templates, dangling indices, resolve, rollover, `update_aliases`) are not
  # listed.
  @doc false
  def __repository__ do
    [
      create_index: {{:pos, 1}, 3, :pair},
      delete_index: {{:pos, 0}, 2, :pair},
      get_index: {{:pos, 0}, 2, :pair},
      index_exists: {{:pos, 0}, 2, :predicate},
      open: {{:pos, 0}, 2, :pair},
      close: {{:pos, 0}, 2, :pair},
      add_block: {{:pos, 0}, 3, :pair},
      remove_block: {{:pos, 0}, 3, :pair},
      put_mapping: {{:pos, 1}, 3, :pair},
      get_mapping: {:opts, 1, :pair},
      get_field_mapping: {:opts, 2, :pair},
      put_settings: {:opts, 2, :pair},
      get_settings: {:opts, 1, :pair},
      put_alias: {{:pos, 1}, 4, :pair},
      delete_alias: {{:pos, 0}, 3, :pair},
      get_alias: {:opts, 1, :pair},
      alias_exists: {:opts, 2, :predicate},
      clone: {{:pos, 1}, 4, :pair},
      shrink: {{:pos, 1}, 4, :pair},
      split: {{:pos, 1}, 4, :pair},
      refresh: {:opts, 1, :pair},
      flush: {:opts, 1, :pair},
      forcemerge: {:opts, 1, :pair},
      clear_cache: {:opts, 1, :pair},
      stats: {:opts, 1, :pair},
      segments: {:opts, 1, :pair},
      recovery: {:opts, 1, :pair},
      shard_stores: {:opts, 1, :pair},
      disk_usage: {{:pos, 0}, 2, :pair},
      field_usage_stats: {{:pos, 0}, 2, :pair},
      analyze: {:opts, 2, :pair},
      validate_query: {:opts, 2, :pair},
      reload_search_analyzers: {{:pos, 0}, 2, :pair}
    ]
  end

  ## Private functions

  @spec segment!(name(), String.t()) :: String.t()
  defp segment!(value, label) do
    case segment(value) do
      nil ->
        raise ArgumentError, "#{label} is required, got: #{inspect(value)}"

      segment ->
        segment
    end
  end

  # HEAD responses have no body, so the response format defaults to :raw.
  @spec exists(String.t(), keyword()) :: {:ok, boolean()} | {:error, Exception.t()}
  defp exists(path, opts) do
    opts = Helpers.put_default_format(opts, :resp_format, :raw)

    :head
    |> Client.request(path, nil, opts)
    |> Helpers.parse_exists()
  end
end

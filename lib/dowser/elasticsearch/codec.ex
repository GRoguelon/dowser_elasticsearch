defmodule Dowser.Elasticsearch.Codec do
  @moduledoc """
  Casts Elasticsearch documents and search results to and from native Elixir
  terms, based on each document's own index mapping — a `Dowser.Client.Codec`
  implementation, set as `:codec_adapter` (see `Dowser.Client`):

      Dowser.Client.Config.new(
        endpoint: "http://localhost:9200",
        codec_adapter: Dowser.Elasticsearch.Codec
      )

  Once configured, every API function in `Dowser.Elasticsearch.Document` and
  `Dowser.Elasticsearch.Search` casts automatically — no per-call option
  needed. Mappings are fetched (and cached) through
  `Dowser.Elasticsearch.MappingCacher`.

  ## decode/2

  Finds and casts every document in a response body, at any nesting depth:
  a bare document (`Document.get/3`), `hits.hits[]` (`Search.search/2`),
  `responses[].hits.hits[]` (`Search.msearch/2`), and so on — each hit's own
  `_index` selects its mapping, so mixed-index results (e.g. `msearch/2`
  across different indices) are cast correctly. `opts[:source]`, alongside
  `opts[:index]`, casts a bare `_source` document with no `_index` of its own
  (`Document.get_source/3`).

  If no mapping can be found for a document's index (no `Dowser.Elasticsearch.MappingCacher`
  running, or the fetch fails), its values pass through unchanged; keys are
  still cast per `opts[:key_fn]`.

  ## encode/2

  Casts a request body against `opts[:index]`'s mapping — a no-op when
  `opts[:index]` is absent. `opts[:doc_key]` casts only that sub-key instead
  of the whole body (`Document.update/4`'s `%{doc: ...}` shape). A list body
  is treated as a `Document.bulk/2` NDJSON action list: `index`/`create`
  actions cast their whole payload, `update` actions cast only `doc`, and
  `delete` actions (which carry no payload) are left alone; a per-action
  `_index` overrides `opts[:index]`.

  ## Field-level casting

  Per-field casting is dispatched via `load/2`/`dump/2`, built with
  `Dowser.Client.CodecBuilder` from the table below. Only the field types
  JSON can't natively represent are cast; any other mapping entry — and
  `nil` values — fall back to identity.

  | mapping type           | field                                    | Elixir term    |
  | ----------------------- | ----------------------------------------- | -------------- |
  | `date`, `date_nanos`   | `Dowser.Elasticsearch.Fields.Date`       | `DateTime`     |
  | `date_range`           | `Dowser.Elasticsearch.Fields.DateRange`  | `Date.Range`   |
  | `integer_range`        | `Dowser.Elasticsearch.Fields.Range`      | `Range`        |
  | `ip`                   | `Dowser.Elasticsearch.Fields.IP`         | `:inet` tuple  |
  | `binary`               | `Dowser.Elasticsearch.Fields.Binary`     | raw binary     |
  | `geo_point`            | `Dowser.Elasticsearch.Fields.GeoPoint`   | `{lat, lon}`   |

  ## Custom codecs

  Add field types by inheriting the built-in casts:

      defmodule MyApp.Codec do
        use Dowser.Client.CodecBuilder, inherit: Dowser.Elasticsearch.Codec

        cast %{"type" => "scaled_float"}, MyApp.Fields.ScaledFloat
      end

  Inherited casts are matched first, so to *replace* a built-in cast (e.g.
  handle a custom date `format`), declare every cast yourself instead of
  inheriting. A module built this way only gets `load/2`/`dump/2`
  (single-field casting), not `decode/2`/`encode/2` — it can't be set as
  `:codec_adapter` directly; write your own whole-body module modeled on
  this one, dispatching to `MyApp.Codec.load/2`/`dump/2` instead.
  """

  @behaviour Dowser.Client.Codec

  use Dowser.Client.CodecBuilder

  alias Dowser.Elasticsearch.Fields
  alias Dowser.Elasticsearch.Mappable
  alias Dowser.Elasticsearch.MappingCacher

  @bulk_actions [:index, :create, :update, :delete]

  ## Type castings

  cast(%{"type" => "date"}, Fields.Date)
  cast(%{"type" => "date_nanos"}, Fields.Date)
  cast(%{"type" => "date_range"}, Fields.DateRange)
  cast(%{"type" => "integer_range"}, Fields.Range)
  cast(%{"type" => "ip"}, Fields.IP)
  cast(%{"type" => "binary"}, Fields.Binary)
  cast(%{"type" => "geo_point"}, Fields.GeoPoint)

  ## Public functions — whole-body casting

  @impl true
  def decode(term, opts) do
    key_fn = Keyword.fetch!(opts, :key_fn)
    config = Keyword.get(opts, :config)

    if Keyword.get(opts, :source, false) do
      mapping = fetch_mapping(config, Keyword.get(opts, :index))
      {:ok, Mappable.decode(term, mapping, key_fn, &load/2)}
    else
      {:ok, Mappable.decode(term, mapping_fn(config), key_fn, &load/2)}
    end
  end

  @impl true
  def encode(term, opts) when is_list(term) do
    config = Keyword.get(opts, :config)
    index = Keyword.get(opts, :index)

    {:ok, bulk_pairs(term, config, index)}
  end

  def encode(term, opts) do
    config = Keyword.get(opts, :config)
    index = Keyword.get(opts, :index)
    doc_key = Keyword.get(opts, :doc_key)

    cond do
      is_nil(index) ->
        {:ok, term}

      doc_key ->
        {:ok, encode_doc_key(term, doc_key, fetch_mapping(config, index))}

      true ->
        {:ok, Mappable.encode(term, fetch_mapping(config, index), &dump/2, false)}
    end
  end

  ## Private functions — mapping lookup

  defp mapping_fn(config) do
    fn index -> {:ok, fetch_mapping(config, index)} end
  end

  defp fetch_mapping(nil, _index), do: nil
  defp fetch_mapping(_config, nil), do: nil

  defp fetch_mapping(config, index) do
    case MappingCacher.get(config, index) do
      {:ok, mapping} ->
        mapping

      _error ->
        nil
    end
  rescue
    _exception ->
      nil
  catch
    :exit, _reason ->
      nil
  end

  ## Private functions — encode

  defp encode_doc_key(%{} = term, doc_key, mapping) do
    string_key = Atom.to_string(doc_key)
    dump_fn = fn value -> Mappable.encode(value, mapping, &dump/2, false) end

    cond do
      Map.has_key?(term, doc_key) ->
        Map.update!(term, doc_key, dump_fn)

      Map.has_key?(term, string_key) ->
        Map.update!(term, string_key, dump_fn)

      true ->
        term
    end
  end

  # Walks the flat, alternating bulk action list, casting each payload
  # against its action's own index (a per-action `_index` overriding the
  # bulk-level default) — `delete` actions carry no payload to cast.
  defp bulk_pairs(operations, config, default_index) do
    {items, _state} =
      Enum.map_reduce(operations, :header, &bulk_step(&1, &2, config, default_index))

    items
  end

  defp bulk_step(item, :header, _config, default_index) do
    {action, header} = bulk_action(item)
    index = fetch_any(header, :_index) || default_index
    next = if action == :delete, do: :header, else: {:payload, action, index}

    {item, next}
  end

  defp bulk_step(item, {:payload, :update, index}, config, _default_index) do
    {encode_doc_key(item, :doc, fetch_mapping(config, index)), :header}
  end

  defp bulk_step(item, {:payload, _action, index}, config, _default_index) do
    {Mappable.encode(item, fetch_mapping(config, index), &dump/2, false), :header}
  end

  defp bulk_action(header) do
    Enum.find_value(@bulk_actions, {:index, header}, fn action ->
      case fetch_any(header, action) do
        %{} = value ->
          {action, value}

        _other ->
          nil
      end
    end)
  end

  defp fetch_any(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end

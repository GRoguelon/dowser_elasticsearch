defmodule Dowser.Elasticsearch.Encoder do
  @moduledoc """
  Casts a document source from native Elixir terms to what Elasticsearch
  expects on the wire, based on the mapping of the index it is going to — a
  `Dowser.Client` `:encoder` (see `Dowser.Client.Encoder`):

      config :dowser_client,
        contexts: [
          default: [
            endpoint: "http://localhost:9200",
            encoder: Dowser.Elasticsearch.Encoder
          ]
        ]

  Once configured, the writing functions of `Dowser.Elasticsearch.Document`
  name the index each source is going to and where in the body it sits, so
  they cast automatically — no per-call option needed. Mappings are fetched
  (and cached) through `Dowser.Elasticsearch.MappingCacher`.

  Only a document source is ever cast: `Dowser.Client` never hands an encoder a
  query, because a query value has no mapping entry to anchor it. Build queries
  in the shape Elasticsearch expects.

  ## Options

  `Dowser.Client` always supplies `:context` (the resolved
  `Dowser.Client.Context`); `Dowser.Elasticsearch.Document` adds `:index`. The
  rest are this encoder's own, given alongside it as
  `{Dowser.Elasticsearch.Encoder, opts}`:

    * `:codec` — the per-field codec to cast values through, a module
      exporting `encode/2`. Falls back to
      `config :dowser_elasticsearch, codec: ...` and then to
      `Dowser.Elasticsearch.Codec`, whose documentation shows how to write
      your own and how the tiers resolve. An API function's `:codec` option
      lands here.
    * `:index` — the index whose mapping the source is cast against. Without
      it there is no mapping to cast against, and the source passes through
      unchanged.
  """

  alias Dowser.Elasticsearch.Codec
  alias Dowser.Elasticsearch.Mappable
  alias Dowser.Elasticsearch.MappingCacher

  ## Module attributes

  @bulk_actions [:index, :create, :update, :delete]

  # Where an update action's source sits, in both key styles — a path that
  # isn't there is skipped rather than created.
  @update_keys [:doc, :upsert]

  ## Public functions

  @doc """
  Casts `source` against the mapping of `opts[:index]`, returning the encoded
  term.

  See the module documentation for the options.
  """
  @spec encode(term(), keyword()) :: term()
  def encode(source, opts) do
    codec = Keyword.get(opts, :codec) || Application.get_env(:dowser_elasticsearch, :codec, Codec)
    mapping = MappingCacher.fetch(Keyword.get(opts, :context), Keyword.get(opts, :index))

    Mappable.encode(source, mapping, &codec.encode/2, false)
  end

  @doc """
  Casts the payloads of a `Dowser.Elasticsearch.Document.bulk/2` operation list.

  A bulk body is a flat list alternating action and payload maps, so a payload
  only knows which index it is going to from the action line above it — which
  is why it is cast here, over the whole list, rather than line by line through
  `Dowser.Client`'s `:encode`.

  `fun` is the resolved encoder (`encode/2` or a custom one) and `opts` its
  options; `opts[:index]` is the bulk-level default index, which a per-action
  `_index` overrides. `index`/`create` actions have their whole payload cast,
  `update` actions only their `doc`/`upsert` source, and `delete` actions carry
  no payload to cast.
  """
  @spec encode_bulk([map()], (term(), keyword() -> term()), keyword()) :: [map()]
  def encode_bulk(operations, fun, opts) when is_list(operations) do
    default_index = Keyword.get(opts, :index)

    {items, _state} =
      Enum.map_reduce(operations, :header, &bulk_step(&1, &2, fun, opts, default_index))

    items
  end

  ## Private functions — bulk

  defp bulk_step(item, :header, _fun, _opts, default_index) do
    {action, header} = bulk_action(item)
    index = fetch_any(header, :_index) || default_index
    next = if action == :delete, do: :header, else: {:payload, action, index}

    {item, next}
  end

  defp bulk_step(item, {:payload, :update, index}, fun, opts, _default_index) do
    opts = Keyword.put(opts, :index, index)

    {Enum.reduce(@update_keys, item, &encode_key(&2, &1, fun, opts)), :header}
  end

  defp bulk_step(item, {:payload, _action, index}, fun, opts, _default_index) do
    {fun.(item, Keyword.put(opts, :index, index)), :header}
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

  # A bulk payload may be written with atom or string keys, so both are tried.
  defp encode_key(%{} = term, key, fun, opts) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(term, key) ->
        Map.update!(term, key, &fun.(&1, opts))

      Map.has_key?(term, string_key) ->
        Map.update!(term, string_key, &fun.(&1, opts))

      true ->
        term
    end
  end

  defp fetch_any(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end

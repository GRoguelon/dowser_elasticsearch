defmodule Dowser.Elasticsearch.Codec do
  @moduledoc """
  Casts Elasticsearch documents and search results to and from native Elixir
  terms, based on each document's own index mapping — a `Dowser.Client`
  `:decoder` *and* `:encoder`:

      config :dowser_client,
        contexts: [
          default: [
            endpoint: "http://localhost:9200",
            decoder: Dowser.Elasticsearch.Codec,
            encoder: Dowser.Elasticsearch.Codec
          ]
        ]

  Once configured, every API function in `Dowser.Elasticsearch.Document` and
  `Dowser.Elasticsearch.Search` casts automatically — no per-call option
  needed. Mappings are fetched (and cached) through
  `Dowser.Elasticsearch.MappingCacher`.

  The module works at two levels, and its two pairs of functions say which:

    * `decode/2` and `encode/2` take a **whole body**, and are what
      `dowser_client` calls.
    * `load/2` and `dump/2` take **one value** and the mapping entry that
      describes it, and are what the body pass dispatches into, field by
      field. They are also this module's behaviour.

  ## decode/2

  Finds and casts every document in a response body, at any nesting depth:
  a bare document (`Dowser.Elasticsearch.Document.get/3`), `hits.hits[]`
  (`Dowser.Elasticsearch.Search.search/2`), `responses[].hits.hits[]`
  (`Dowser.Elasticsearch.Search.msearch/2`), and so on — each hit's own
  `_index` selects its mapping, so mixed-index results are cast correctly.

  A hit's `inner_hits` are cast too. They carry no `_index` of their own, so
  their mapping comes from the hit they belong to: `_nested.field` names the
  path into it, and an inner hit with no `_nested` (a `has_child` or
  `has_parent` join) is cast against the index mapping itself. The rest of a
  hit's envelope — `fields`, `highlight`, `sort` — has no mapping entry to be
  cast against, and only has its keys run through `opts[:key_fn]`.

  If no mapping can be found for a document's index (no
  `Dowser.Elasticsearch.MappingCacher` running, or the fetch fails), its values
  pass through unchanged; keys are still cast per `opts[:key_fn]`.

  ### Subtrees the mapping declares opaque

  A `flattened` field, and an object mapped `"enabled": false`, hold whatever
  the document put in them — the mapping enumerates none of it. Both are
  returned exactly as they arrived: values uncast, and keys left as strings
  rather than run through `opts[:key_fn]`.

  That last part matters under `keys: :atoms`. Atoms are never garbage
  collected and the table is capped (`:erlang.system_info(:atom_limit)`, a
  little over a million by default); atomizing keys that come from document
  content rather than from the mapping turns any writer into a way to exhaust
  it and bring the node down. A mapped field's name is one of a finite set, so
  casting it is safe; a `flattened` field's keys are not.

  A mixed result is the price: `%{title: "hi", roster: %{"Managed Care Biller"
  => "Sam"}}`. The alternative is a cast that is unsafe by construction.

  Note that this is narrower than the whole risk. `keys: :atoms` also casts
  keys the mapping simply doesn't mention — an unmapped field under
  `"dynamic": false`, or one added since the mapping was cached. Where a body
  is wholly untrusted, `keys: :atoms!` (`String.to_existing_atom/1`) is the
  option that cannot grow the table at all.

  ## encode/2

  Casts one **document source** against the mapping of `opts[:index]` — never a
  query. `dowser_client` only hands an encoder a source, because a query value
  has no mapping entry to anchor it: the same value can appear in a range
  clause, a script parameter or an aggregation boundary, each wanting a
  different shape. Build queries in the shape Elasticsearch expects.

  `encode_bulk/3` is the exception to one-source-at-a-time: a bulk payload is
  cast against the index named on the action line above it, which no per-line
  pass can see.

  ## load/2 and dump/2

  The mapping entry's `"type"` selects the field codec that handles it; only
  the types JSON can't natively represent are cast, and any other entry — like
  a `nil` value — falls back to identity.

  | mapping type           | field codec                              | Elixir term    |
  | ---------------------- | ---------------------------------------- | -------------- |
  | `date`, `date_nanos`   | `Dowser.Elasticsearch.Codec.Date`        | `DateTime`     |
  | `date_range`           | `Dowser.Elasticsearch.Codec.DateRange`   | `Date.Range`   |
  | `integer_range`        | `Dowser.Elasticsearch.Codec.Range`       | `Range`        |
  | `ip`                   | `Dowser.Elasticsearch.Codec.IP`          | `:inet` tuple  |
  | `binary`               | `Dowser.Elasticsearch.Codec.Binary`      | raw binary     |
  | `geo_point`            | `Dowser.Elasticsearch.Codec.GeoPoint`    | `{lat, lon}`   |

      iex> Dowser.Elasticsearch.Codec.load("127.0.0.1", %{"type" => "ip"})
      {127, 0, 0, 1}

      iex> Dowser.Elasticsearch.Codec.dump({127, 0, 0, 1}, %{"type" => "ip"})
      "127.0.0.1"

  ## The behaviour

  `load/2` and `dump/2` are the callbacks each field codec in the table
  implements: two functions over one value and the mapping entry describing it
  (`field`), returning the cast term directly. A value a codec doesn't
  recognize should pass through unchanged rather than raise, so a bad cast
  degrades to identity instead of failing the whole document.

  ## Adding mapping types

  A codec is a plain module, so covering one more type is a clause per
  direction and a delegation back here for everything else:

      defmodule MyApp.Codec do
        @behaviour Dowser.Elasticsearch.Codec

        @impl true
        def load(value, %{"type" => "my_type"} = field) do
          # ...
        end

        def load(value, field), do: Dowser.Elasticsearch.Codec.load(value, field)

        @impl true
        def dump(value, %{"type" => "my_type"} = field) do
          # ...
        end

        def dump(value, field), do: Dowser.Elasticsearch.Codec.dump(value, field)
      end

  Delegating last inherits the built-in casts — including the `nil`
  short-circuit and the fall-through to identity, so neither needs restating.
  Matching a type this module already handles *replaces* that cast (e.g. to
  handle a custom date `format`), since your clause comes first.

  A module like that only needs `load/2` and `dump/2`: the envelope walking
  stays here, and `:codec` points `decode/2`/`encode/2` at it. It resolves
  most-specific-first, like every other option in this package:

    1. **Per request** — `:codec` alongside any other option:

           Dowser.Elasticsearch.Document.get("posts", "1", codec: MyApp.Codec)

    2. **Per context** — named alongside the pass it belongs to:

           decoder: {Dowser.Elasticsearch.Codec, codec: MyApp.Codec},
           encoder: {Dowser.Elasticsearch.Codec, codec: MyApp.Codec}

    3. **Globally** — the usual place for an application with one codec, and
       the only tier that needs no tuple:

           config :dowser_elasticsearch, codec: MyApp.Codec

    4. This module, when none of the above is set.

  ## Options

  `dowser_client` always supplies `:context` (the resolved
  `Dowser.Client.Context`), and a decoder also gets `:key_fn` (the function
  `:keys` resolved to). The rest are this module's own, given alongside it as
  `{Dowser.Elasticsearch.Codec, opts}`:

    * `:codec` — the field codec `load/2`/`dump/2` are dispatched through, as
      above.
    * `:index` — the index whose mapping `encode/2` casts a source against, and
      that `decode/2` casts a `:source` body against. Set by the API function
      itself.
    * `:source` — `true` when a response body is a bare `_source` document with
      no `_index` of its own (`Dowser.Elasticsearch.Document.get_source/3`).
      Set by the API function itself.
  """

  alias Dowser.Elasticsearch.Bulk
  alias Dowser.Elasticsearch.Mappable
  alias Dowser.Elasticsearch.MappingCacher

  ## Behaviour callbacks

  @doc "Casts `value` from its Elasticsearch representation into a richer term."
  @callback load(value :: term(), field :: term()) :: term()

  @doc "Casts `value` back into its Elasticsearch representation."
  @callback dump(value :: term(), field :: term()) :: term()

  # This module dispatches to the field codecs in the table below, and is
  # itself one — which is what makes it the default `:codec`.
  @behaviour __MODULE__

  ## Module attributes

  @codecs %{
    "binary" => Dowser.Elasticsearch.Codec.Binary,
    "date" => Dowser.Elasticsearch.Codec.Date,
    "date_nanos" => Dowser.Elasticsearch.Codec.Date,
    "date_range" => Dowser.Elasticsearch.Codec.DateRange,
    "geo_point" => Dowser.Elasticsearch.Codec.GeoPoint,
    "integer_range" => Dowser.Elasticsearch.Codec.Range,
    "ip" => Dowser.Elasticsearch.Codec.IP
  }

  # Where an update action's source sits, in both key styles — a key that isn't
  # there is skipped rather than created.
  @update_keys [:doc, :upsert]

  ## Public functions — whole bodies

  @doc """
  Casts every document found in `body`, returning the decoded term.

  See the module documentation for the options; `:key_fn` is required, and
  `dowser_client` always supplies it.
  """
  @spec decode(term(), keyword()) :: term()
  def decode(body, opts) do
    key_fn = Keyword.fetch!(opts, :key_fn)
    context = Keyword.get(opts, :context)
    codec = codec(opts)
    load = &codec.load/2

    if Keyword.get(opts, :source, false) do
      mapping = MappingCacher.fetch(context, Keyword.get(opts, :index))

      Mappable.decode(body, mapping, key_fn, load)
    else
      Mappable.decode(body, mapping_fn(context), key_fn, load)
    end
  end

  @doc """
  Casts `source` against the mapping of `opts[:index]`, returning the encoded
  term.

  Without an `:index` there is no mapping to cast against, and the source
  passes through unchanged. See the module documentation for the options.
  """
  @spec encode(term(), keyword()) :: term()
  def encode(source, opts) do
    codec = codec(opts)
    mapping = MappingCacher.fetch(Keyword.get(opts, :context), Keyword.get(opts, :index))

    Mappable.encode(source, mapping, &codec.dump/2, false)
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

  ## Public functions — one value

  @doc """
  Casts `value` from Elasticsearch's representation, dispatching on `field`'s
  `"type"`.

  A `nil` value, a mapping entry with no known `"type"`, or no mapping entry at
  all, all return `value` untouched — so a missing mapping degrades a cast to
  identity rather than failing.
  """
  @impl true
  def load(value, field)

  def load(nil, _field), do: nil

  def load(value, %{"type" => type} = field) do
    case Map.fetch(@codecs, type) do
      {:ok, codec} ->
        codec.load(value, field)

      :error ->
        value
    end
  end

  def load(value, _field), do: value

  @doc """
  Casts `value` back into Elasticsearch's representation, dispatching on
  `field`'s `"type"`.

  The mirror image of `load/2`, with the same fallbacks.
  """
  @impl true
  def dump(value, field)

  def dump(nil, _field), do: nil

  def dump(value, %{"type" => type} = field) do
    case Map.fetch(@codecs, type) do
      {:ok, codec} ->
        codec.dump(value, field)

      :error ->
        value
    end
  end

  def dump(value, _field), do: value

  ## Private functions — the field codec

  defp codec(opts) do
    Keyword.get(opts, :codec) || Application.get_env(:dowser_elasticsearch, :codec, __MODULE__)
  end

  # A hit carries the index it came from, so its mapping is resolved lazily,
  # per document, as the envelope is walked.
  defp mapping_fn(context) do
    fn index -> {:ok, MappingCacher.fetch(context, index)} end
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

  defp bulk_action(header), do: Bulk.action(header)

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

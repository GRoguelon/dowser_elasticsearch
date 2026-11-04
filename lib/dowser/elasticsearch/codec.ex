defmodule Dowser.Elasticsearch.Codec do
  @moduledoc """
  Casts Elasticsearch documents and search results to and from native Elixir
  terms, based on each document's own index mapping — a `Dowser.Client`
  `:decoder` *and* `:encoder`:

      config :my_app, MyApp.Search,
        endpoint: "http://localhost:9200",
        decoder: Dowser.Elasticsearch.Codec,
        encoder: Dowser.Elasticsearch.Codec

  Once configured, every API function in `Dowser.Elasticsearch.Document` and
  `Dowser.Elasticsearch.Search` casts automatically — no per-call option needed.
  Mappings are fetched (and cached) through `Dowser.Elasticsearch.MappingCacher`.

  The casting itself is `dowser_client`'s, shared with `dowser_opensearch`:
  `Dowser.Codec` documents the options (`:codec`, `:mapping`,
  `:mapping_failure`, …) and what happens when a mapping can't be fetched,
  `Dowser.Source` how a document is walked, and `Dowser.Type` how each value is
  cast. This module is Elasticsearch's configuration of it:

    * mappings come from `Dowser.Elasticsearch.MappingCacher`;
    * `:codec` and `:mapping_failure` default to the `:dowser_elasticsearch`
      application environment
      (`config :dowser_elasticsearch, codec: MyApp.Type, mapping_failure: :warn`);
    * a failed fetch emits `[:dowser_elasticsearch, :mapping, :failure]`;
    * a `flattened` field is opaque — see below.

  ## Subtrees the mapping declares opaque

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

  ## Casting a type of your own

  `:codec` names the `Dowser.Type` module every leaf value is cast through —
  see `Dowser.Type` for writing one. It resolves most-specific-first:

    1. **Per request** — `:codec` alongside any other option:

           Dowser.Elasticsearch.Document.get("posts", "1", codec: MyApp.Type)

    2. **Per repo** — named alongside the pass it belongs to:

           decoder: {Dowser.Elasticsearch.Codec, codec: MyApp.Type},
           encoder: {Dowser.Elasticsearch.Codec, codec: MyApp.Type}

    3. **Globally**:

           config :dowser_elasticsearch, codec: MyApp.Type

    4. `Dowser.Type`, when none of the above is set.
  """

  ## Module attributes

  @config %{
    otp_app: :dowser_elasticsearch,
    cacher: Dowser.Elasticsearch.MappingCacher,
    opaque: ["flattened"]
  }

  ## Public functions

  @doc """
  Casts every document found in `body`, returning the decoded term; see
  `Dowser.Codec.decode/3`.
  """
  @spec decode(term(), keyword()) :: term()
  def decode(body, opts) do
    Dowser.Codec.decode(body, opts, @config)
  end

  @doc """
  Casts `source` against the mapping of `opts[:index]`, returning the encoded
  term; see `Dowser.Codec.encode/3`.
  """
  @spec encode(term(), keyword()) :: term()
  def encode(source, opts) do
    Dowser.Codec.encode(source, opts, @config)
  end

  @doc """
  Casts the payloads of a `Dowser.Elasticsearch.Document.bulk/2` operation list;
  see `Dowser.Codec.encode_bulk/3`.
  """
  @spec encode_bulk([map()], (term(), keyword() -> term()), keyword()) :: [map()]
  def encode_bulk(operations, fun, opts) do
    Dowser.Codec.encode_bulk(operations, fun, opts)
  end
end

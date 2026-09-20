defmodule Dowser.Elasticsearch.Decoder do
  @moduledoc """
  Casts the documents in an Elasticsearch response body to native Elixir terms,
  based on each document's own index mapping — a `Dowser.Client` `:decoder`
  (see `Dowser.Client.Decoder`):

      config :dowser_client,
        contexts: [
          default: [
            endpoint: "http://localhost:9200",
            decoder: Dowser.Elasticsearch.Decoder
          ]
        ]

  Once configured, every API function in `Dowser.Elasticsearch.Document` and
  `Dowser.Elasticsearch.Search` casts automatically — no per-call option
  needed. Mappings are fetched (and cached) through
  `Dowser.Elasticsearch.MappingCacher`.

  ## decode/2

  Finds and casts every document in a response body, at any nesting depth:
  a bare document (`Dowser.Elasticsearch.Document.get/3`), `hits.hits[]`
  (`Dowser.Elasticsearch.Search.search/2`), `responses[].hits.hits[]`
  (`Dowser.Elasticsearch.Search.msearch/2`), and so on — each hit's own
  `_index` selects its mapping, so mixed-index results (e.g. `msearch/2`
  across different indices) are cast correctly.

  If no mapping can be found for a document's index (no
  `Dowser.Elasticsearch.MappingCacher` running, or the fetch fails), its values
  pass through unchanged; keys are still cast per `opts[:key_fn]`.

  ## Options

  `Dowser.Client` always supplies `:key_fn` (the function `:keys` resolved to)
  and `:context` (the resolved `Dowser.Client.Context`). The rest are this
  decoder's own, given alongside it as `{Dowser.Elasticsearch.Decoder, opts}`:

    * `:codec` — the per-field codec to cast values through, a module
      exporting `decode/2`. Falls back to
      `config :dowser_elasticsearch, codec: ...` and then to
      `Dowser.Elasticsearch.Codec`, whose documentation shows how to write
      your own and how the tiers resolve. An API function's `:codec` option
      lands here.
    * `:source` — `true` when the body is a bare `_source` document with no
      `_index` of its own (`Dowser.Elasticsearch.Document.get_source/3`), in
      which case `:index` names the index to cast it against. Both are set by
      the API function itself.
    * `:index` — the index whose mapping casts a `:source` body.
  """

  alias Dowser.Elasticsearch.Codec
  alias Dowser.Elasticsearch.Mappable
  alias Dowser.Elasticsearch.MappingCacher

  ## Public functions

  @doc """
  Casts every document found in `body`, returning the decoded term.

  See the module documentation for the options; `:key_fn` is required, and
  `Dowser.Client` always supplies it.
  """
  @spec decode(term(), keyword()) :: term()
  def decode(body, opts) do
    key_fn = Keyword.fetch!(opts, :key_fn)
    context = Keyword.get(opts, :context)
    codec = Keyword.get(opts, :codec) || Application.get_env(:dowser_elasticsearch, :codec, Codec)
    decode = &codec.decode/2

    if Keyword.get(opts, :source, false) do
      mapping = MappingCacher.fetch(context, Keyword.get(opts, :index))

      Mappable.decode(body, mapping, key_fn, decode)
    else
      Mappable.decode(body, mapping_fn(context), key_fn, decode)
    end
  end

  ## Private functions

  # A hit carries the index it came from, so its mapping is resolved lazily,
  # per document, as the envelope is walked.
  defp mapping_fn(context) do
    fn index -> {:ok, MappingCacher.fetch(context, index)} end
  end
end

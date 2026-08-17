defprotocol Dowser.Elasticsearch.Mappable do
  @moduledoc false

  @fallback_to_any true
  def encode(term, mapping, value_fn, strip_blank)

  @fallback_to_any true
  def decode(term, mapping_fn, key_fn, value_fn)
end

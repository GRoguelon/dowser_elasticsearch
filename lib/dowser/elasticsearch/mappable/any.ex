defimpl Dowser.Elasticsearch.Mappable, for: Any do
  def encode(value, mapping, value_fn, _strip_blank) do
    value_fn.(value, mapping)
  end

  def decode(value, mapping, _key_fn, value_fn) do
    value_fn.(value, mapping)
  end
end

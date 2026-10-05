defimpl Dowser.Elasticsearch.Mappable, for: Any do
  # A struct mapped as an object is a document (or a part of one), not a leaf
  # value: it is walked as a map. Under a leaf field (`date`, `date_range`...)
  # it is left to `value_fn`, which knows how to dump `Date`, `Range` and such.
  defguardp object?(mapping)
            when is_map_key(mapping, "properties") or
                   :erlang.map_get("type", mapping) in ["object", "nested"]

  def encode(%_{} = value, mapping, value_fn, strip_blank)
      when is_map(mapping) and object?(mapping) do
    value
    |> Map.from_struct()
    |> @protocol.encode(mapping, value_fn, strip_blank)
  end

  def encode(value, mapping, value_fn, _strip_blank) do
    value_fn.(value, mapping)
  end

  def decode(value, mapping, _key_fn, value_fn) do
    value_fn.(value, mapping)
  end
end

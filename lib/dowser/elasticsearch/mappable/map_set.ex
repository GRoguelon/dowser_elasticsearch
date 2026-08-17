defimpl Dowser.Elasticsearch.Mappable, for: MapSet do
  import Dowser.Blank, only: [blank?: 1]

  ## Public functions

  def encode(values, mapping, value_fn, strip_blank) do
    Enum.reduce(values, MapSet.new(), fn value, acc ->
      encoded_value = @protocol.encode(value, mapping, value_fn, strip_blank)

      if strip_blank and blank?(encoded_value) do
        acc
      else
        MapSet.put(acc, encoded_value)
      end
    end)
  end

  def decode(values, mapping, key_fn, value_fn) do
    MapSet.new(values, &@protocol.decode(&1, mapping, key_fn, value_fn))
  end
end

defimpl Dowser.Elasticsearch.Mappable, for: List do
  import Dowser.Blank, only: [blank?: 1]

  ## Public functions

  def encode(values, mapping, value_fn, strip_blank) do
    values
    |> Enum.reduce([], fn value, acc ->
      encoded_value = @protocol.encode(value, mapping, value_fn, strip_blank)

      if strip_blank and blank?(encoded_value) do
        acc
      else
        [encoded_value | acc]
      end
    end)
    |> Enum.reverse()
  end

  def decode(values, mapping, key_fn, value_fn) do
    Enum.map(values, &@protocol.decode(&1, mapping, key_fn, value_fn))
  end
end

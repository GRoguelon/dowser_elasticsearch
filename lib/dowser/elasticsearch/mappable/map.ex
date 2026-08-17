defimpl Dowser.Elasticsearch.Mappable, for: Map do
  import Dowser.Blank, only: [blank?: 1]

  ## Public functions

  def encode(value, mapping, value_fn, strip_blank) do
    fields = mapping_fields(mapping)

    Enum.reduce(value, %{}, fn {key, value}, acc ->
      field = field_for(fields, key)
      encoded_value = @protocol.encode(value, field, value_fn, strip_blank)

      if strip_blank and blank?(encoded_value) do
        acc
      else
        Map.put(acc, key, encoded_value)
      end
    end)
  end

  def decode(
        %{"_index" => <<_::binary>> = index, "_source" => %{}} = value,
        mapping_fn,
        key_fn,
        value_fn
      )
      when is_function(mapping_fn, 1) do
    {:ok, mapping} = mapping_fn.(index)

    decode(value, mapping, key_fn, value_fn)
  end

  def decode(%{"_index" => <<_::binary>>, "_source" => %{}} = value, mapping, key_fn, value_fn) do
    Map.new(value, fn
      {"_source" = key, value} ->
        {key_fn.(key), @protocol.decode(value, mapping, key_fn, value_fn)}

      {key, value} ->
        {key_fn.(key), value}
    end)
  end

  def decode(value, mapping_fn, key_fn, value_fn) when is_function(mapping_fn, 1) do
    Map.new(value, fn {key, value} ->
      {key_fn.(key), @protocol.decode(value, mapping_fn, key_fn, value_fn)}
    end)
  end

  def decode(value, %{"properties" => mapping}, key_fn, value_fn) do
    Map.new(value, fn
      {key, %{"gte" => _, "lte" => _} = value} when map_size(value) == 2 ->
        {key_fn.(key), value_fn.(value, mapping[key])}

      {key, value} ->
        {key_fn.(key), @protocol.decode(value, mapping[key], key_fn, value_fn)}
    end)
  end

  def decode(value, _mapping, key_fn, value_fn) do
    Map.new(value, fn {key, value} ->
      {key_fn.(key), @protocol.decode(value, nil, key_fn, value_fn)}
    end)
  end

  ## Private functions

  defp mapping_fields(%{"properties" => fields}) do
    fields
  end

  defp mapping_fields(fields) do
    fields
  end

  defp field_for(fields, _key) when not is_map(fields) do
    fields
  end

  defp field_for(fields, key) do
    Map.get(fields, to_string(key)) || fields
  end
end

defimpl Dowser.Elasticsearch.Mappable, for: Map do
  import Dowser.Blank, only: [blank?: 1]

  alias Dowser.CoreExt.Keyable

  # Mapping entries that describe a subtree without enumerating what is in it:
  # a `flattened` field holds one opaque object, and an `enabled: false` object
  # is kept in `_source` but never indexed. Either way the keys inside are
  # whatever the document put there — so they are neither cast nor, crucially,
  # run through `key_fn`, which under `keys: :atoms` would turn unbounded
  # document content into permanent entries in a table that is never collected.
  defguardp opaque?(mapping)
            when is_map(mapping) and
                   (:erlang.map_get("type", mapping) == "flattened" or
                      :erlang.map_get("enabled", mapping) == false)

  ## Public functions

  def encode(value, mapping, _value_fn, _strip_blank) when opaque?(mapping) do
    value
  end

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

  # Ahead of every other clause: an opaque subtree is returned exactly as it
  # arrived, whatever it happens to contain.
  def decode(value, mapping, _key_fn, _value_fn) when opaque?(mapping) do
    value
  end

  # A range object whose own mapping entry is in hand. The `"properties"`
  # clause below catches a range that is a direct child of an object, but
  # Elasticsearch lets any field hold an array, and a range reached through
  # one arrives here with the field's entry as its mapping rather than the
  # parent's. Without this it would fall through to the generic clause, which
  # casts the keys and never calls `value_fn` — leaving `%{gte: _, lte: _}`
  # where a `Date.Range` was expected.
  def decode(%{"gte" => _, "lte" => _} = value, %{"type" => _} = mapping, _key_fn, value_fn)
      when map_size(value) == 2 do
    value_fn.(value, mapping)
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

      # The rest of a hit is envelope, not document: `inner_hits`, `fields`,
      # `highlight` and friends. There is no mapping entry to cast them
      # against — an inner hit is a nested document, and carries no `_index`
      # of its own — but their keys are part of the same response, so they
      # follow the same `:keys`. Renaming only the outer key would leave a
      # caller reading `hit.inner_hits` a string-keyed map inside an
      # otherwise atom-keyed one.
      {key, value} ->
        {key_fn.(key), Keyable.transform_keys(value, key_fn)}
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

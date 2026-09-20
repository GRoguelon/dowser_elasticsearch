defmodule Dowser.Elasticsearch.Codec.Range do
  @moduledoc """
  `integer_range` — the `%{"gte" => _, "lte" => _}` object form <-> an Elixir
  `Range`.

  Only integer bounds are cast; any other shape passes through untouched.
  """

  ## Behaviours

  @behaviour Dowser.Elasticsearch.Codec

  ## Public functions

  @impl true
  def decode(%{"gte" => gte, "lte" => lte}, _field) when is_integer(gte) and is_integer(lte) do
    Range.new(gte, lte)
  end

  def decode(value, _field) do
    value
  end

  @impl true
  def encode(%Range{} = range, _field) do
    %{"gte" => range.first, "lte" => range.last}
  end

  def encode(value, _field) do
    value
  end
end

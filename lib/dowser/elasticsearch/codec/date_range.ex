defmodule Dowser.Elasticsearch.Codec.DateRange do
  @moduledoc """
  `date_range` — the `%{"gte" => _, "lte" => _}` object form <-> a `Date.Range`.

  Bounds are cast through `Dowser.Elasticsearch.Codec.Date`, so they follow
  the same mapping `"format"` (or Elasticsearch's own default when absent).
  """

  alias Dowser.Elasticsearch.Codec.Date, as: DateCodec

  ## Behaviours

  @behaviour Dowser.Elasticsearch.Codec

  ## Public functions

  @impl true
  def load(%{"gte" => gte, "lte" => lte}, field) do
    first = DateCodec.load(gte, field)
    last = DateCodec.load(lte, field)

    Date.range(first, last)
  end

  def load(value, _field) do
    value
  end

  @impl true
  def dump(%Date.Range{} = date_range, field) do
    gte = DateCodec.dump(date_range.first, field)
    lte = DateCodec.dump(date_range.last, field)

    %{"gte" => gte, "lte" => lte}
  end

  def dump(value, _field) do
    value
  end
end

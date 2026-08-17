defmodule Dowser.Elasticsearch.Fields.DateRange do
  @moduledoc """
  `date_range` — the `%{"gte" => _, "lte" => _}` object form <-> a `Date.Range`.

  Bounds are cast through `Dowser.Elasticsearch.Fields.Date`, so they follow
  the same mapping `"format"` (or Elasticsearch's own default when absent).
  """

  alias Dowser.Elasticsearch.Fields.Date, as: DateField

  ## Behaviours

  @behaviour Dowser.Client.Field

  ## Public functions

  @impl Dowser.Client.Field
  def load(%{"gte" => gte, "lte" => lte}, field) do
    first = DateField.load(gte, field)
    last = DateField.load(lte, field)

    Date.range(first, last)
  end

  def load(value, _field) do
    value
  end

  @impl Dowser.Client.Field
  def dump(%Date.Range{} = date_range, field) do
    gte = DateField.dump(date_range.first, field)
    lte = DateField.dump(date_range.last, field)

    %{"gte" => gte, "lte" => lte}
  end

  def dump(value, _field) do
    value
  end
end

defmodule Dowser.Elasticsearch.Fields.Range do
  @moduledoc """
  `integer_range` — the `%{"gte" => _, "lte" => _}` object form <-> an Elixir
  `Range`.

  Only integer bounds are cast; any other shape passes through untouched.
  """

  ## Behaviours

  @behaviour Dowser.Client.Field

  ## Public functions

  @impl Dowser.Client.Field
  def load(%{"gte" => gte, "lte" => lte}, _field) when is_integer(gte) and is_integer(lte) do
    Range.new(gte, lte)
  end

  def load(value, _field) do
    value
  end

  @impl Dowser.Client.Field
  def dump(%Range{} = range, _field) do
    %{"gte" => range.first, "lte" => range.last}
  end

  def dump(value, _field) do
    value
  end
end

defmodule Dowser.Elasticsearch.Fields.GeoPoint do
  @moduledoc """
  `geo_point` — the `%{"lat" => _, "lon" => _}` object form <-> a `{lat, lon}`
  tuple.

  Other Elasticsearch forms (string `"lat,lon"`, `[lon, lat]`, geohash) pass
  through untouched — cast your own field over `geo_point` to handle them.
  """

  @behaviour Dowser.Client.Field

  @impl Dowser.Client.Field
  def load(%{"lat" => lat, "lon" => lon}, _field) do
    {lat, lon}
  end

  def load(value, _field) do
    value
  end

  @impl Dowser.Client.Field
  def dump({lat, lon}, _field) do
    %{"lat" => lat, "lon" => lon}
  end

  def dump(value, _field) do
    value
  end
end

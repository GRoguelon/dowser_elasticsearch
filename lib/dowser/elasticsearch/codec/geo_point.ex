defmodule Dowser.Elasticsearch.Codec.GeoPoint do
  @moduledoc """
  `geo_point` — the `%{"lat" => _, "lon" => _}` object form <-> a `{lat, lon}`
  tuple.

  Other Elasticsearch forms (string `"lat,lon"`, `[lon, lat]`, geohash) pass
  through untouched — write your own codec over `geo_point` to handle them.
  """

  @behaviour Dowser.Elasticsearch.Codec

  @impl true
  def load(%{"lat" => lat, "lon" => lon}, _field) do
    {lat, lon}
  end

  def load(value, _field) do
    value
  end

  @impl true
  def dump({lat, lon}, _field) do
    %{"lat" => lat, "lon" => lon}
  end

  def dump(value, _field) do
    value
  end
end

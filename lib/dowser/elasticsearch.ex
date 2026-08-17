defmodule Dowser.Elasticsearch do
  @moduledoc """
  Elasticsearch client, built on `Dowser.Client`.

  Each Elasticsearch endpoint lives in its own module under this namespace, so
  the API stays organized as more endpoints are added. This module exposes no
  functions itself: call the endpoint's module directly, e.g.
  `Dowser.Elasticsearch.Search.search/2`.
  """
end

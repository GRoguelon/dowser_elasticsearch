defmodule Dowser.Elasticsearch.MappingCacher do
  @moduledoc """
  Per-node cache of Elasticsearch index mappings, read by
  `Dowser.Elasticsearch.Codec`.

  The cache is `dowser_client`'s `Dowser.MappingCacher` — see it for how
  entries are keyed, fetched and expired, and for the `start_link/1` options.
  This module is Elasticsearch's own instance of it: its own process and ETS
  table, configured from the `:dowser_elasticsearch` application environment.

  This package doesn't start it. An application that casts documents against
  the cluster's mappings — the default mapping source — starts it in its own
  supervision tree, with its options (see `Dowser.MappingCacher`):

      children = [MyApp.Search, {Dowser.Elasticsearch.MappingCacher, ttl: :timer.minutes(10)}]

  Asked without having been started, it reports `{:not_started, cacher}`, which
  `Dowser.Elasticsearch.Codec` turns into a `Dowser.MappingError` by default. An
  application that only casts with `:struct`, or with mappings of its own
  (`config :dowser_elasticsearch, mapping: MyApp.Mappings`), doesn't need it.

  ## Mappings that are never fetched

  A mapping given in the application environment answers for its index without
  any request at all — and so can never fail to be fetched:

      config :dowser_elasticsearch,
        mappings: %{
          "posts" => %{
            "properties" => %{"published_at" => %{"type" => "date", "format" => "strict_date_time"}}
          }
        }

  It wins over the cache. Use it for an index whose mapping is pinned, and in
  test suites, where it makes casting behave as it does in production without
  a cluster to ask (`put/3` does the same through a running cacher).
  """

  use Dowser.MappingCacher, otp_app: :dowser_elasticsearch
end

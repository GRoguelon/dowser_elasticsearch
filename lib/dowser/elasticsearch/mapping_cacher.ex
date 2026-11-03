defmodule Dowser.Elasticsearch.MappingCacher do
  @moduledoc """
  Per-node cache of Elasticsearch index mappings, read by
  `Dowser.Elasticsearch.Codec`.

  The cache is `dowser_client`'s `Dowser.MappingCacher` — see it for how
  entries are keyed, fetched and expired, and for the `start_link/1` options.
  This module is Elasticsearch's own instance of it: its own process and ETS
  table, configured from the `:dowser_elasticsearch` application environment.

  Whether the cacher is started at all (and with which options) is decided by
  the application — see `config :dowser_elasticsearch, mapping_cacher_opts: [...]`.

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

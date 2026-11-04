# `iex -S mix` against a local cluster: a development repo, made the default so
# calls need no `:repo`, casting against the cluster's mappings.
defmodule Dev.Search do
  use Dowser.Elasticsearch.Repo, otp_app: :dowser_elasticsearch
end

if is_nil(Application.get_env(:dowser_elasticsearch, Dev.Search)) do
  Application.put_env(:dowser_elasticsearch, Dev.Search,
    endpoint: "http://localhost:9200",
    auth: {:basic, "elastic", "elastic"},
    http_opts: [ssl: [insecure: true]],
    decoder: Dowser.Elasticsearch.Codec,
    encoder: Dowser.Elasticsearch.Codec
  )
end

Application.put_env(:dowser_elasticsearch, :default_repo, Dev.Search)

# Already running when this file is evaluated again in the same session.
_ = Dowser.Elasticsearch.MappingCacher.start_link()

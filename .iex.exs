if is_nil(Application.get_env(:dowser_client, :contexts)) do
  Application.put_env(:dowser_client, :contexts,
    default: [
      endpoint: "http://localhost:9200",
      auth: {:basic, "elastic", "elastic"},
      http_opts: [ssl: [insecure: true]],
      decoder: Dowser.Elasticsearch.Codec,
      encoder: Dowser.Elasticsearch.Codec
    ]
  )
end

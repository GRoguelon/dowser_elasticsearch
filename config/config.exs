import Config

# `dowser_client` 0.2.0 has no adapters to select: HTTP is OTP's `:httpc` and
# JSON is Elixir's `JSON`. Point it at a cluster — and, optionally, at this
# package's casting — with `contexts:`; see the README.
#
#     config :dowser_client,
#       contexts: [
#         default: [
#           endpoint: "http://localhost:9200",
#           decoder: Dowser.Elasticsearch.Decoder,
#           encoder: Dowser.Elasticsearch.Encoder
#         ]
#       ]
#
# The per-field codec those two dispatch into defaults to
# `Dowser.Elasticsearch.Codec`, and is overridable globally here, on a context,
# or per request:
#
#     config :dowser_elasticsearch, codec: MyApp.Codec

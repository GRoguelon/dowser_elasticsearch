import Config

# This package needs no configuration of its own. An application defines a
# repo per cluster, configured under its own application, and names the one
# a call without `:repo` goes to; see the README:
#
#     config :my_app, MyApp.Search,
#       endpoint: "http://localhost:9200",
#       decoder: Dowser.Elasticsearch.Codec,
#       encoder: Dowser.Elasticsearch.Codec
#
#     config :dowser_elasticsearch, default_repo: MyApp.Search
#
# The casting options default from here too — the mapping source, the type
# module leaf values go through, what to do with an unknown field:
#
#     config :dowser_elasticsearch, mapping: MyApp.Mappings, types: MyApp.Types

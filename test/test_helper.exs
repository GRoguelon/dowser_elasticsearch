ExUnit.start()

# The application permanently supervises a `Dowser.Elasticsearch.MappingCacher`
# under its own registered name; tests that need one (with a custom `:fetch`)
# start their own via `start_supervised!/1` under the same name, which
# collides with the app-managed instance still running. Stop the app once so
# every test starts from a clean slate.
Application.stop(:dowser_elasticsearch)

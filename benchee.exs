Benchee.run(
  %{
    "multiple" => fn ->
      Dowser.Elasticsearch.Fields.Date.load("2026-08-14T17:09:34.437Z", %{
        "format" => "strict_date_optional_time||date_optional_time"
      })
    end,
    "single" => fn ->
      Dowser.Elasticsearch.Fields.Date.load("2026-08-14T17:09:34.437Z", %{
        "format" => "strict_date_optional_time"
      })
    end
  },
  time: 10,
  memory_time: 2
)

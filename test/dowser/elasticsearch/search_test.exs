defmodule Dowser.Elasticsearch.SearchTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Error
  alias Dowser.Elasticsearch.HTTPStub
  alias Dowser.Elasticsearch.Search

  @hits ~s({"hits":{"total":{"value":1},"hits":[{"_id":"1"}]}})
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@hits)}\r\n\r\n" <>
              @hits

  @not_found ~s({"error":{"type":"index_not_found_exception","reason":"no such index [missing]"},"status":404})
  @not_found_response "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@not_found)}\r\n\r\n" <>
                        @not_found

  @server_error ~s({"message":"boom"})
  @server_error_response "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@server_error)}\r\n\r\n" <>
                           @server_error

  describe "search/2" do
    test "POSTs the query to /_search and decodes the response" do
      {port, server} = start_server()

      assert {:ok, body} =
               Search.search(%{"query" => %{"match_all" => %{}}}, config: config(port))

      assert body["hits"]["total"]["value"] == 1

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_search"
      assert req.body == ~s({"query":{"match_all":{}}})
      assert req.headers["content-type"] == "application/json"
    end

    test "targets a single index" do
      {port, server} = start_server()

      assert {:ok, _} = Search.search(%{}, index: "posts", config: config(port))
      assert Task.await(server).path == "/posts/_search"
    end

    test "joins several indices with commas" do
      {port, server} = start_server()

      assert {:ok, _} = Search.search(%{}, index: ["posts", "comments"], config: config(port))
      assert Task.await(server).path == "/posts,comments/_search"
    end

    test "forwards url params" do
      {port, server} = start_server()

      assert {:ok, _} =
               Search.search(%{}, index: "posts", params: [routing: "u1"], config: config(port))

      assert Task.await(server).path == "/posts/_search?routing=u1"
    end

    test "wraps a 404 in a Dowser.Elasticsearch.Error with type and reason" do
      {port, server} = start_server(@not_found_response)

      assert {:error, error} = Search.search(%{}, index: "missing", config: config(port))

      assert %Error{
               status: 404,
               type: "index_not_found_exception",
               reason: "no such index [missing]"
             } = error

      Task.await(server)
    end

    test "wraps any other non-2xx status, even without a standard error body" do
      {port, server} = start_server(@server_error_response)

      assert {:error, %Error{status: 500, type: nil, reason: nil, body: %{"message" => "boom"}}} =
               Search.search(%{}, config: config(port))

      Task.await(server)
    end
  end

  describe "search!/2" do
    test "returns the decoded body directly" do
      {port, server} = start_server()

      assert %{"hits" => %{"total" => %{"value" => 1}}} =
               Search.search!(%{}, config: config(port))

      Task.await(server)
    end

    test "raises the Dowser.Elasticsearch.Error on a non-2xx response" do
      {port, server} = start_server(@not_found_response)

      assert_raise Error, ~r/HTTP 404.*no such index/, fn ->
        Search.search!(%{}, index: "missing", config: config(port))
      end

      Task.await(server)
    end
  end

  describe "msearch/2" do
    test "POSTs NDJSON to /_msearch" do
      {port, server} = start_server()

      searches = [%{}, %{"query" => %{"match_all" => %{}}}]
      assert {:ok, _} = Search.msearch(searches, config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_msearch"
      assert req.headers["content-type"] == "application/x-ndjson"
      assert req.body == ~s({}\n{"query":{"match_all":{}}}\n)
    end

    test "targets an index" do
      {port, server} = start_server()

      assert {:ok, _} = Search.msearch([%{}, %{}], index: "posts", config: config(port))
      assert Task.await(server).path == "/posts/_msearch"
    end
  end

  describe "count/2" do
    test "POSTs the query to /_count" do
      {port, server} = start_server()

      assert {:ok, _} =
               Search.count(%{"query" => %{"match_all" => %{}}}, config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_count"
      assert req.body == ~s({"query":{"match_all":{}}})
    end

    test "targets an index" do
      {port, server} = start_server()

      assert {:ok, _} = Search.count(%{}, index: "posts", config: config(port))
      assert Task.await(server).path == "/posts/_count"
    end
  end

  describe "explain/4" do
    test "POSTs the query to /{index}/_explain/{id}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Search.explain(%{"query" => %{"match_all" => %{}}}, "posts", "1",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_explain/1"
      assert req.body == ~s({"query":{"match_all":{}}})
    end
  end

  describe "field_caps/2" do
    test "POSTs the body to /_field_caps" do
      {port, server} = start_server()

      assert {:ok, _} = Search.field_caps(%{"fields" => ["title"]}, config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_field_caps"
      assert req.body == ~s({"fields":["title"]})
    end

    test "targets an index" do
      {port, server} = start_server()

      assert {:ok, _} =
               Search.field_caps(%{"fields" => ["title"]}, index: "posts", config: config(port))

      assert Task.await(server).path == "/posts/_field_caps"
    end
  end

  describe "search_shards/1" do
    test "GETs /{index}/_search_shards" do
      {port, server} = start_server()

      assert {:ok, _} = Search.search_shards(index: "posts", config: config(port))

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/posts/_search_shards"
    end
  end

  describe "terms_enum/3" do
    test "POSTs the body to /{index}/_terms_enum" do
      {port, server} = start_server()

      assert {:ok, _} =
               Search.terms_enum(%{"field" => "title", "string" => "he"}, "posts",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_terms_enum"
      assert req.body =~ ~s("field":"title")
      assert req.body =~ ~s("string":"he")
    end

    test "requires an index" do
      assert_raise ArgumentError, ~r/requires an index/, fn ->
        Search.terms_enum(%{"field" => "title"}, nil)
      end
    end
  end

  describe "search_mvt/7" do
    test "POSTs the tile path and returns the raw binary" do
      tile = <<26, 5, 120, 2, 0>>

      response =
        "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.mapbox-vector-tile\r\nContent-Length: #{byte_size(tile)}\r\n\r\n" <>
          tile

      {port, server} = start_server(response)

      assert {:ok, ^tile} =
               Search.search_mvt(%{}, "posts", "location", 2, 1, 3, config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_mvt/location/2/1/3"
    end
  end

  describe "search_template/2" do
    test "POSTs the template body to /{index}/_search/template" do
      {port, server} = start_server()

      assert {:ok, _} =
               Search.search_template(%{"id" => "tpl", "params" => %{"q" => "hi"}},
                 index: "posts",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_search/template"
      assert req.body =~ ~s("id":"tpl")
    end
  end

  describe "msearch_template/2" do
    test "POSTs NDJSON to /_msearch/template" do
      {port, server} = start_server()

      searches = [%{}, %{"id" => "tpl", "params" => %{}}]
      assert {:ok, _} = Search.msearch_template(searches, config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_msearch/template"
      assert req.headers["content-type"] == "application/x-ndjson"
    end
  end

  describe "render_search_template/3" do
    test "POSTs the params to /_render/template/{id}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Search.render_search_template(%{"params" => %{"q" => "hi"}}, "tpl",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_render/template/tpl"
      assert req.body == ~s({"params":{"q":"hi"}})
    end
  end

  describe "rank_eval/2" do
    test "POSTs requests and metric to /{index}/_rank_eval" do
      {port, server} = start_server()

      assert {:ok, _} =
               Search.rank_eval([%{"id" => "q1"}],
                 index: "posts",
                 metric: %{"precision" => %{"k" => 10}},
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_rank_eval"
      assert req.body =~ ~s("requests":[{"id":"q1"}])
      assert req.body =~ ~s("metric":{"precision":{"k":10}})
    end
  end

  describe "async search" do
    test "submit_async_search/2 POSTs the query to /{index}/_async_search" do
      {port, server} = start_server()

      assert {:ok, _} =
               Search.submit_async_search(%{"query" => %{"match_all" => %{}}},
                 index: "posts",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_async_search"
    end

    test "get_async_search/2 GETs /_async_search/{id}" do
      {port, server} = start_server()

      assert {:ok, _} = Search.get_async_search("abc123", config: config(port))

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/_async_search/abc123"
    end

    test "get_async_search_status/2 GETs /_async_search/status/{id}" do
      {port, server} = start_server()

      assert {:ok, _} = Search.get_async_search_status("abc123", config: config(port))
      assert Task.await(server).path == "/_async_search/status/abc123"
    end

    test "delete_async_search/2 DELETEs /_async_search/{id}" do
      {port, server} = start_server()

      assert {:ok, _} = Search.delete_async_search("abc123", config: config(port))

      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.path == "/_async_search/abc123"
    end
  end

  describe "scroll" do
    test "scroll/2 POSTs the scroll id in the body" do
      {port, server} = start_server()

      assert {:ok, _} = Search.scroll("c2Nhbg==", scroll: "1m", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_search/scroll"
      assert req.body =~ ~s("scroll_id":"c2Nhbg==")
      assert req.body =~ ~s("scroll":"1m")
    end

    test "clear_scroll/2 DELETEs with the scroll ids in the body" do
      {port, server} = start_server()

      assert {:ok, _} = Search.clear_scroll(["a", "b"], config: config(port))

      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.path == "/_search/scroll"
      assert req.body == ~s({"scroll_id":["a","b"]})
    end
  end

  describe "point in time" do
    test "open_point_in_time/4 POSTs /{index}/_pit with keep_alive" do
      {port, server} = start_server()

      assert {:ok, _} = Search.open_point_in_time(%{}, "posts", "1m", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_pit?keep_alive=1m"
    end

    test "open_point_in_time/4 requires an index" do
      assert_raise ArgumentError, ~r/requires an index/, fn ->
        Search.open_point_in_time(%{}, nil, "1m")
      end
    end

    test "close_point_in_time/2 DELETEs /_pit with the id in the body" do
      {port, server} = start_server()

      assert {:ok, _} = Search.close_point_in_time("pit-id", config: config(port))

      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.path == "/_pit"
      assert req.body == ~s({"id":"pit-id"})
    end
  end

  describe "type casting via :type_codec" do
    test "each hit's _source is cast against its own index mapping, at any nesting depth" do
      mapping = %{
        "properties" => %{
          "published_at" => %{"type" => "date", "format" => "strict_date_optional_time"}
        }
      }

      HTTPStub.start_mapping_cacher!(mapping)

      hits =
        ~s({"took":1,"hits":{"total":{"value":1},"hits":[{"_index":"posts","_id":"1","_source":{"published_at":"2026-08-11T00:00:00.000Z"}}]}})

      response =
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(hits)}\r\n\r\n" <>
          hits

      {port, server} = start_server(response)

      assert {:ok, body} =
               Search.search(%{}, config: HTTPStub.config_with_codec_adapter(port))

      [hit] = body["hits"]["hits"]
      assert hit["_source"]["published_at"] == ~U[2026-08-11 00:00:00.000Z]

      Task.await(server)
    end
  end

  defp config(port), do: HTTPStub.config(port)

  defp start_server(response \\ @response), do: HTTPStub.start_server(response)
end

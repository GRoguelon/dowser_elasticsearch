defmodule Dowser.Elasticsearch.DocumentTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Document
  alias Dowser.Elasticsearch.HTTPStub

  defp config(port), do: HTTPStub.config(port)
  defp start_server(response \\ HTTPStub.ok_response()), do: HTTPStub.start_server(response)

  defp json_response(body) do
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
      body
  end

  describe "single documents" do
    test "index/3 POSTs the document to /{index}/_doc" do
      {port, server} = start_server()

      assert {:ok, _} = Document.index(%{"title" => "hi"}, "posts", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_doc"
      assert req.body == ~s({"title":"hi"})
    end

    test "index/3 targets /{index}/_doc/{id} when an id is given" do
      {port, server} = start_server()

      assert {:ok, _} =
               Document.index(%{"title" => "hi"}, "posts", id: "1", config: config(port))

      assert Task.await(server).path == "/posts/_doc/1"
    end

    test "index/3 requires an index" do
      assert_raise ArgumentError, ~r/requires an index/, fn ->
        Document.index(%{}, nil)
      end
    end

    test "create/4 POSTs the document to /{index}/_create/{id}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Document.create(%{"title" => "hi"}, "posts", "1", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_create/1"
      assert req.body == ~s({"title":"hi"})
    end

    test "get/3 GETs /{index}/_doc/{id}" do
      {port, server} = start_server()

      assert {:ok, _} = Document.get("posts", "1", config: config(port))

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/posts/_doc/1"
    end

    test "delete/3 DELETEs /{index}/_doc/{id}" do
      {port, server} = start_server()

      assert {:ok, _} = Document.delete("posts", "1", config: config(port))

      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.path == "/posts/_doc/1"
    end

    test "exists/3 HEADs /{index}/_doc/{id} and returns result tuples" do
      {port, server} = start_server(HTTPStub.head_response(200))
      assert {:ok, true} = Document.exists("posts", "1", config: config(port))

      req = Task.await(server)
      assert req.method == "HEAD"
      assert req.path == "/posts/_doc/1"

      {port, server} = start_server(HTTPStub.head_response(404))
      assert {:ok, false} = Document.exists("posts", "1", config: config(port))
      Task.await(server)
    end

    test "exists?/3 returns the bare boolean" do
      {port, server} = start_server(HTTPStub.head_response(200))
      assert Document.exists?("posts", "1", config: config(port)) == true
      Task.await(server)
    end

    test "get_source/3 GETs /{index}/_source/{id}" do
      {port, server} = start_server()

      assert {:ok, _} = Document.get_source("posts", "1", config: config(port))
      assert Task.await(server).path == "/posts/_source/1"
    end

    test "source_exists/3 HEADs /{index}/_source/{id}" do
      {port, server} = start_server(HTTPStub.head_response(404))

      assert {:ok, false} = Document.source_exists("posts", "1", config: config(port))

      req = Task.await(server)
      assert req.method == "HEAD"
      assert req.path == "/posts/_source/1"
    end

    test "update/4 POSTs the body to /{index}/_update/{id}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Document.update(%{"doc" => %{"title" => "hi"}}, "posts", "1", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_update/1"
      assert req.body == ~s({"doc":{"title":"hi"}})
    end
  end

  describe "type casting via :type_codec" do
    @mapping %{
      "properties" => %{
        "published_at" => %{"type" => "date", "format" => "strict_date_optional_time"}
      }
    }

    test "get/3 casts the response _source against the index mapping" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body =
        ~s({"_index":"posts","_id":"1","_source":{"published_at":"2026-08-11T00:00:00.000Z","title":"hi"}})

      {port, server} = start_server(json_response(body))

      assert {:ok, doc} =
               Document.get("posts", "1", config: HTTPStub.config_with_codec_adapter(port))

      assert doc["_source"]["published_at"] == ~U[2026-08-11 00:00:00.000Z]
      assert doc["_source"]["title"] == "hi"

      Task.await(server)
    end

    test "get_source/3 casts the bare source against the index mapping" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = ~s({"published_at":"2026-08-11T00:00:00.000Z","title":"hi"})
      {port, server} = start_server(json_response(body))

      assert {:ok, source} =
               Document.get_source("posts", "1", config: HTTPStub.config_with_codec_adapter(port))

      assert source["published_at"] == ~U[2026-08-11 00:00:00.000Z]
      assert source["title"] == "hi"

      Task.await(server)
    end

    test "mget/2 casts every doc's _source" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body =
        ~s({"docs":[{"_index":"posts","_id":"1","_source":{"published_at":"2026-08-11T00:00:00.000Z"}}]})

      {port, server} = start_server(json_response(body))

      assert {:ok, %{"docs" => [doc]}} =
               Document.mget(%{"ids" => ["1"]},
                 index: "posts",
                 config: HTTPStub.config_with_codec_adapter(port)
               )

      assert doc["_source"]["published_at"] == ~U[2026-08-11 00:00:00.000Z]

      Task.await(server)
    end

    test "index/3 casts the document's values before sending" do
      HTTPStub.start_mapping_cacher!(@mapping)
      {port, server} = start_server()

      document = %{"published_at" => ~U[2026-08-11 00:00:00Z], "title" => "hi"}

      assert {:ok, _} =
               Document.index(document, "posts", config: HTTPStub.config_with_codec_adapter(port))

      assert Task.await(server).body ==
               ~s({"published_at":"2026-08-11T00:00:00Z","title":"hi"})
    end

    test "update/4 casts only the doc sub-map" do
      HTTPStub.start_mapping_cacher!(@mapping)
      {port, server} = start_server()

      body = %{"doc" => %{"published_at" => ~U[2026-08-11 00:00:00Z]}}

      assert {:ok, _} =
               Document.update(body, "posts", "1",
                 config: HTTPStub.config_with_codec_adapter(port)
               )

      assert Task.await(server).body == ~s({"doc":{"published_at":"2026-08-11T00:00:00Z"}})
    end

    test "bulk/2 casts request payload values and response item _source values" do
      HTTPStub.start_mapping_cacher!(@mapping)

      response_body =
        ~s({"items":[{"index":{"_index":"posts","_id":"1"}}]})

      {port, server} = start_server(json_response(response_body))

      operations = [
        %{"index" => %{"_id" => "1"}},
        %{"published_at" => ~U[2026-08-11 00:00:00Z]}
      ]

      assert {:ok, _} =
               Document.bulk(operations,
                 index: "posts",
                 config: HTTPStub.config_with_codec_adapter(port)
               )

      req = Task.await(server)
      assert req.body == ~s({"index":{"_id":"1"}}\n{"published_at":"2026-08-11T00:00:00Z"}\n)
    end
  end

  describe "multi-document" do
    test "bulk/2 POSTs NDJSON to /_bulk" do
      {port, server} = start_server()

      operations = [%{"index" => %{"_id" => "1"}}, %{"title" => "hi"}]
      assert {:ok, _} = Document.bulk(operations, config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_bulk"
      assert req.headers["content-type"] == "application/x-ndjson"
      assert req.body == ~s({"index":{"_id":"1"}}\n{"title":"hi"}\n)
    end

    test "bulk/2 targets an index" do
      {port, server} = start_server()

      assert {:ok, _} = Document.bulk([%{}, %{}], index: "posts", config: config(port))
      assert Task.await(server).path == "/posts/_bulk"
    end

    test "mget/2 POSTs the body to /{index}/_mget" do
      {port, server} = start_server()

      assert {:ok, _} =
               Document.mget(%{"ids" => ["1", "2"]}, index: "posts", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_mget"
      assert req.body == ~s({"ids":["1","2"]})
    end
  end

  describe "by-query operations" do
    test "delete_by_query/3 POSTs the query to /{index}/_delete_by_query" do
      {port, server} = start_server()

      assert {:ok, _} =
               Document.delete_by_query(%{"query" => %{"match_all" => %{}}}, "posts",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_delete_by_query"
      assert req.body == ~s({"query":{"match_all":{}}})
    end

    test "update_by_query/3 POSTs the body to /{index}/_update_by_query" do
      {port, server} = start_server()

      assert {:ok, _} = Document.update_by_query(%{}, "posts", config: config(port))

      req = Task.await(server)
      assert req.path == "/posts/_update_by_query"
      assert req.body == "{}"
    end

    test "reindex/2 POSTs the body to /_reindex" do
      {port, server} = start_server()

      body = %{"source" => %{"index" => "old"}, "dest" => %{"index" => "new"}}
      assert {:ok, _} = Document.reindex(body, config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_reindex"
      assert req.body =~ ~s("source":{"index":"old"})
    end
  end

  describe "rethrottling" do
    test "delete_by_query_rethrottle/3 POSTs with requests_per_second" do
      {port, server} = start_server()

      assert {:ok, _} = Document.delete_by_query_rethrottle("t:1", 10, config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_delete_by_query/t:1/_rethrottle?requests_per_second=10"
    end

    test "update_by_query_rethrottle/3 POSTs with requests_per_second" do
      {port, server} = start_server()

      assert {:ok, _} = Document.update_by_query_rethrottle("t:1", -1, config: config(port))
      assert Task.await(server).path == "/_update_by_query/t:1/_rethrottle?requests_per_second=-1"
    end

    test "reindex_rethrottle/3 POSTs with requests_per_second" do
      {port, server} = start_server()

      assert {:ok, _} = Document.reindex_rethrottle("t:1", 10, config: config(port))
      assert Task.await(server).path == "/_reindex/t:1/_rethrottle?requests_per_second=10"
    end
  end

  describe "term vectors" do
    test "termvectors/3 POSTs the body to /{index}/_termvectors" do
      {port, server} = start_server()

      assert {:ok, _} =
               Document.termvectors(%{"doc" => %{"title" => "hi"}}, "posts", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_termvectors"
    end

    test "termvectors/3 targets /{index}/_termvectors/{id} when an id is given" do
      {port, server} = start_server()

      assert {:ok, _} = Document.termvectors(%{}, "posts", id: "1", config: config(port))
      assert Task.await(server).path == "/posts/_termvectors/1"
    end

    test "mtermvectors/2 POSTs the body to /{index}/_mtermvectors" do
      {port, server} = start_server()

      assert {:ok, _} =
               Document.mtermvectors(%{"ids" => ["1"]}, index: "posts", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_mtermvectors"
      assert req.body == ~s({"ids":["1"]})
    end
  end
end

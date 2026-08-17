defmodule Dowser.Elasticsearch.IndexTest do
  use ExUnit.Case, async: true
  doctest Dowser.Elasticsearch.Index

  alias Dowser.Elasticsearch.HTTPStub
  alias Dowser.Elasticsearch.Index

  defp config(port), do: HTTPStub.config(port)
  defp start_server(response \\ HTTPStub.ok_response()), do: HTTPStub.start_server(response)

  describe "segment/1" do
    test "returns nil for empty targets" do
      assert Index.segment(nil) == nil
      assert Index.segment("") == nil
      assert Index.segment([]) == nil
    end

    test "url-encodes a single index" do
      assert Index.segment("posts") == "posts"
      assert Index.segment("my index") == "my%20index"
    end

    test "joins and url-encodes several indices" do
      assert Index.segment(["posts", "comments"]) == "posts,comments"
      assert Index.segment(["a b", "c"]) == "a%20b,c"
    end
  end

  describe "index management" do
    test "create_index/3 PUTs the body to /{index}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.create_index(%{"settings" => %{"number_of_shards" => 1}}, "posts",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "PUT"
      assert req.path == "/posts"
      assert req.body == ~s({"settings":{"number_of_shards":1}})
    end

    test "create_index/3 PUTs an empty object when there is nothing to send" do
      {port, server} = start_server()

      assert {:ok, _} = Index.create_index(%{}, "posts", config: config(port))

      req = Task.await(server)
      assert req.method == "PUT"
      assert req.body == "{}"
    end

    test "create_index/3 requires an index" do
      assert_raise ArgumentError, ~r/requires an index/, fn ->
        Index.create_index(%{}, nil)
      end
    end

    test "delete_index/2 DELETEs /{index}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.delete_index("posts", config: config(port))

      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.path == "/posts"
    end

    test "get_index/2 GETs /{index}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.get_index(["posts", "comments"], config: config(port))

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/posts,comments"
    end

    test "index_exists/2 HEADs /{index} and returns result tuples" do
      {port, server} = start_server(HTTPStub.head_response(200))
      assert {:ok, true} = Index.index_exists("posts", config: config(port))
      assert Task.await(server).method == "HEAD"

      {port, server} = start_server(HTTPStub.head_response(404))
      assert {:ok, false} = Index.index_exists("posts", config: config(port))
      Task.await(server)
    end

    test "index_exists?/2 returns the bare boolean" do
      {port, server} = start_server(HTTPStub.head_response(200))
      assert Index.index_exists?("posts", config: config(port)) == true
      Task.await(server)

      {port, server} = start_server(HTTPStub.head_response(404))
      assert Index.index_exists?("posts", config: config(port)) == false
      Task.await(server)
    end

    test "open/2 POSTs /{index}/_open with an empty body" do
      {port, server} = start_server()

      assert {:ok, _} = Index.open("posts", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_open"
      assert req.body == ""
    end

    test "close/2 POSTs /{index}/_close" do
      {port, server} = start_server()

      assert {:ok, _} = Index.close("posts", config: config(port))
      assert Task.await(server).path == "/posts/_close"
    end

    test "add_block/3 PUTs /{index}/_block/{block}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.add_block("posts", "write", config: config(port))

      req = Task.await(server)
      assert req.method == "PUT"
      assert req.path == "/posts/_block/write"
    end

    test "remove_block/3 DELETEs /{index}/_block/{block}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.remove_block("posts", :write, config: config(port))

      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.path == "/posts/_block/write"
    end
  end

  describe "mappings" do
    test "put_mapping/3 POSTs the mapping to /{index}/_mapping" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.put_mapping(%{"properties" => %{}}, "posts", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_mapping"
      assert req.body == ~s({"properties":{}})
    end

    test "get_mapping/1 GETs /_mapping or /{index}/_mapping" do
      {port, server} = start_server()
      assert {:ok, _} = Index.get_mapping(config: config(port))
      assert Task.await(server).path == "/_mapping"

      {port, server} = start_server()
      assert {:ok, _} = Index.get_mapping(index: "posts", config: config(port))
      assert Task.await(server).path == "/posts/_mapping"
    end

    test "get_field_mapping/2 GETs /{index}/_mapping/field/{fields}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.get_field_mapping([:title, :body], index: "posts", config: config(port))

      assert Task.await(server).path == "/posts/_mapping/field/title,body"
    end
  end

  describe "settings" do
    test "put_settings/2 PUTs the settings to /{index}/_settings" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.put_settings(%{"index" => %{"number_of_replicas" => 2}},
                 index: "posts",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "PUT"
      assert req.path == "/posts/_settings"
    end

    test "get_settings/1 GETs /{index}/_settings/{name}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.get_settings(index: "posts", name: "index.blocks.*", config: config(port))

      assert Task.await(server).path == "/posts/_settings/index.blocks.*"
    end
  end

  describe "aliases" do
    test "update_aliases/2 POSTs the actions to /_aliases" do
      {port, server} = start_server()

      actions = [%{"add" => %{"index" => "posts", "alias" => "blog"}}]
      assert {:ok, _} = Index.update_aliases(actions, config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_aliases"
      assert req.body == ~s({"actions":[{"add":{"alias":"blog","index":"posts"}}]})
    end

    test "put_alias/4 POSTs /{index}/_aliases/{name}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.put_alias(%{}, "posts", "blog", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_aliases/blog"
    end

    test "delete_alias/3 DELETEs /{index}/_aliases/{name}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.delete_alias("posts", "blog", config: config(port))

      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.path == "/posts/_aliases/blog"
    end

    test "get_alias/1 GETs the /_alias variants" do
      {port, server} = start_server()
      assert {:ok, _} = Index.get_alias(config: config(port))
      assert Task.await(server).path == "/_alias"

      {port, server} = start_server()
      assert {:ok, _} = Index.get_alias(index: "posts", name: "blog", config: config(port))
      assert Task.await(server).path == "/posts/_alias/blog"
    end

    test "alias_exists/2 HEADs /_alias/{name}" do
      {port, server} = start_server(HTTPStub.head_response(200))

      assert {:ok, true} = Index.alias_exists("blog", config: config(port))

      req = Task.await(server)
      assert req.method == "HEAD"
      assert req.path == "/_alias/blog"
    end
  end

  describe "index templates" do
    test "put_index_template/3 POSTs the template to /_index_template/{name}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.put_index_template(%{"index_patterns" => ["posts-*"]}, "tpl",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_index_template/tpl"
      assert req.body == ~s({"index_patterns":["posts-*"]})
    end

    test "get_index_template/2 GETs /_index_template/{name}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.get_index_template("tpl", config: config(port))
      assert Task.await(server).path == "/_index_template/tpl"
    end

    test "delete_index_template/2 DELETEs /_index_template/{name}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.delete_index_template("tpl", config: config(port))
      assert Task.await(server).method == "DELETE"
    end

    test "index_template_exists/2 HEADs /_index_template/{name}" do
      {port, server} = start_server(HTTPStub.head_response(404))

      assert {:ok, false} = Index.index_template_exists("tpl", config: config(port))
      assert Task.await(server).path == "/_index_template/tpl"
    end

    test "simulate_index_template/3 POSTs /_index_template/_simulate_index/{name}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.simulate_index_template(%{}, "posts", config: config(port))
      assert Task.await(server).path == "/_index_template/_simulate_index/posts"
    end

    test "simulate_template/3 POSTs the body to /_index_template/_simulate/{name}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.simulate_template(%{"index_patterns" => ["posts-*"]}, "tpl",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.path == "/_index_template/_simulate/tpl"
      assert req.body == ~s({"index_patterns":["posts-*"]})
    end
  end

  describe "component templates" do
    test "put_component_template/3 POSTs the template to /_component_template/{name}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.put_component_template(%{"template" => %{}}, "ct", config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_component_template/ct"
    end

    test "get_component_template/2 GETs /_component_template/{name}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.get_component_template("ct", config: config(port))
      assert Task.await(server).path == "/_component_template/ct"
    end

    test "delete_component_template/2 DELETEs /_component_template/{name}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.delete_component_template("ct", config: config(port))
      assert Task.await(server).method == "DELETE"
    end

    test "component_template_exists/2 HEADs /_component_template/{name}" do
      {port, server} = start_server(HTTPStub.head_response(200))

      assert {:ok, true} = Index.component_template_exists("ct", config: config(port))
      Task.await(server)
    end

    test "template_exists/2 HEADs /_template/{name}" do
      {port, server} = start_server(HTTPStub.head_response(200))

      assert {:ok, true} = Index.template_exists("tpl", config: config(port))
      assert Task.await(server).path == "/_template/tpl"
    end
  end

  describe "resizing & rollover" do
    test "clone/4 POSTs /{index}/_clone/{target}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.clone(%{}, "posts", "posts2", config: config(port))
      assert Task.await(server).path == "/posts/_clone/posts2"
    end

    test "shrink/4 POSTs the body to /{index}/_shrink/{target}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.shrink(%{"settings" => %{"index.number_of_shards" => 1}}, "posts", "posts2",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.path == "/posts/_shrink/posts2"
      assert req.body =~ "number_of_shards"
    end

    test "split/4 POSTs /{index}/_split/{target}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.split(%{}, "posts", "posts2", config: config(port))
      assert Task.await(server).path == "/posts/_split/posts2"
    end

    test "rollover/3 POSTs /{target}/_rollover, with an optional new index" do
      {port, server} = start_server()
      assert {:ok, _} = Index.rollover(%{}, "blog", config: config(port))
      assert Task.await(server).path == "/blog/_rollover"

      {port, server} = start_server()

      assert {:ok, _} =
               Index.rollover(%{}, "blog", new_index: "posts-000002", config: config(port))

      assert Task.await(server).path == "/blog/_rollover/posts-000002"
    end
  end

  describe "maintenance" do
    test "refresh/1 GETs /{index}/_refresh" do
      {port, server} = start_server()

      assert {:ok, _} = Index.refresh(index: "posts", config: config(port))

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/posts/_refresh"
    end

    test "flush/1 GETs /_flush" do
      {port, server} = start_server()

      assert {:ok, _} = Index.flush(config: config(port))
      assert Task.await(server).path == "/_flush"
    end

    test "forcemerge/1 POSTs /_forcemerge with an empty body" do
      {port, server} = start_server()

      assert {:ok, _} = Index.forcemerge(config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_forcemerge"
      assert req.body == ""
    end

    test "clear_cache/1 POSTs /{index}/_cache/clear" do
      {port, server} = start_server()

      assert {:ok, _} = Index.clear_cache(index: "posts", config: config(port))
      assert Task.await(server).path == "/posts/_cache/clear"
    end
  end

  describe "monitoring" do
    test "stats/1 GETs the /_stats variants" do
      {port, server} = start_server()
      assert {:ok, _} = Index.stats(config: config(port))
      assert Task.await(server).path == "/_stats"

      {port, server} = start_server()

      assert {:ok, _} =
               Index.stats(index: "posts", metric: [:docs, :store], config: config(port))

      assert Task.await(server).path == "/posts/_stats/docs,store"
    end

    test "segments/1 GETs /{index}/_segments" do
      {port, server} = start_server()

      assert {:ok, _} = Index.segments(index: "posts", config: config(port))
      assert Task.await(server).path == "/posts/_segments"
    end

    test "recovery/1 GETs /{index}/_recovery" do
      {port, server} = start_server()

      assert {:ok, _} = Index.recovery(index: "posts", config: config(port))
      assert Task.await(server).path == "/posts/_recovery"
    end

    test "shard_stores/1 GETs /{index}/_shard_stores" do
      {port, server} = start_server()

      assert {:ok, _} = Index.shard_stores(index: "posts", config: config(port))
      assert Task.await(server).path == "/posts/_shard_stores"
    end

    test "disk_usage/2 POSTs /{index}/_disk_usage" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.disk_usage("posts",
                 params: [run_expensive_tasks: true],
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/posts/_disk_usage?run_expensive_tasks=true"
    end

    test "field_usage_stats/2 GETs /{index}/_field_usage_stats" do
      {port, server} = start_server()

      assert {:ok, _} = Index.field_usage_stats("posts", config: config(port))
      assert Task.await(server).path == "/posts/_field_usage_stats"
    end
  end

  describe "analysis & validation" do
    test "analyze/2 POSTs the body to /_analyze" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.analyze(%{"analyzer" => "standard", "text" => "hi"}, config: config(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_analyze"
      assert req.body == ~s({"analyzer":"standard","text":"hi"})
    end

    test "validate_query/2 POSTs the query to /{index}/_validate/query" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.validate_query(%{"query" => %{"match_all" => %{}}},
                 index: "posts",
                 config: config(port)
               )

      req = Task.await(server)
      assert req.path == "/posts/_validate/query"
      assert req.body == ~s({"query":{"match_all":{}}})
    end

    test "reload_search_analyzers/2 POSTs /{index}/_reload_search_analyzers" do
      {port, server} = start_server()

      assert {:ok, _} = Index.reload_search_analyzers("posts", config: config(port))
      assert Task.await(server).path == "/posts/_reload_search_analyzers"
    end
  end

  describe "dangling indices" do
    test "list_dangling_indices/1 GETs /_dangling" do
      {port, server} = start_server()

      assert {:ok, _} = Index.list_dangling_indices(config: config(port))

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/_dangling"
    end

    test "import_dangling_index/2 POSTs /_dangling/{index_uuid}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.import_dangling_index("uuid-1",
                 params: [accept_data_loss: true],
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_dangling/uuid-1?accept_data_loss=true"
    end

    test "delete_dangling_index/2 DELETEs /_dangling/{index_uuid}" do
      {port, server} = start_server()

      assert {:ok, _} =
               Index.delete_dangling_index("uuid-1",
                 params: [accept_data_loss: true],
                 config: config(port)
               )

      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.path == "/_dangling/uuid-1?accept_data_loss=true"
    end
  end

  describe "resolve & data-stream lifecycle" do
    test "resolve_index/2 GETs /_resolve/index/{name}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.resolve_index("posts-*", config: config(port))

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/_resolve/index/posts-*"
    end

    test "resolve_cluster/2 GETs /_resolve/cluster/{name}" do
      {port, server} = start_server()

      assert {:ok, _} = Index.resolve_cluster("remote1:*", config: config(port))
      assert Task.await(server).path == "/_resolve/cluster/remote1:*"
    end

    test "delete_data_lifecycle/2 DELETEs /_data_stream/{name}/_lifecycle" do
      {port, server} = start_server()

      assert {:ok, _} = Index.delete_data_lifecycle("logs", config: config(port))

      req = Task.await(server)
      assert req.method == "DELETE"
      assert req.path == "/_data_stream/logs/_lifecycle"
    end
  end
end

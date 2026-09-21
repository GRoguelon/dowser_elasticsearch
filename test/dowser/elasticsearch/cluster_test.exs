defmodule Dowser.Elasticsearch.ClusterTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Cluster
  alias Dowser.Elasticsearch.Error
  alias Dowser.Elasticsearch.HTTPStub

  @body ~s({"cluster_name":"docker-cluster","status":"green"})
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@body)}\r\n\r\n" <>
              @body

  @server_error ~s({"message":"boom"})
  @server_error_response "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@server_error)}\r\n\r\n" <>
                           @server_error

  # {function, args, expected method, expected path} — the whole cluster surface.
  @endpoints [
    {:health, [[]], "GET", "/_cluster/health"},
    {:health, [[index: "posts"]], "GET", "/_cluster/health/posts"},
    {:info, ["_all", []], "GET", "/_info/_all"},
    {:info, [["http", "ingest"], []], "GET", "/_info/http,ingest"},
    {:remote_info, [[]], "GET", "/_remote/info"},
    {:get_settings, [[]], "GET", "/_cluster/settings"},
    {:put_settings, [%{persistent: %{}}, []], "PUT", "/_cluster/settings"},
    {:state, [[]], "GET", "/_cluster/state"},
    {:state, [[metric: "metadata"]], "GET", "/_cluster/state/metadata"},
    {:state, [[metric: "metadata", index: "posts"]], "GET", "/_cluster/state/metadata/posts"},
    {:stats, [[]], "GET", "/_cluster/stats"},
    {:stats, [[node_id: "node-1"]], "GET", "/_cluster/stats/nodes/node-1"},
    {:pending_tasks, [[]], "GET", "/_cluster/pending_tasks"},
    {:allocation_explain, [%{}, []], "POST", "/_cluster/allocation/explain"},
    {:reroute, [%{}, []], "POST", "/_cluster/reroute"},
    {:update_voting_config_exclusions, [[]], "POST", "/_cluster/voting_config_exclusions"},
    {:clear_voting_config_exclusions, [[]], "DELETE", "/_cluster/voting_config_exclusions"},
    {:nodes_info, [[]], "GET", "/_nodes"},
    {:nodes_info, [[node_id: "node-1"]], "GET", "/_nodes/node-1"},
    {:nodes_info, [[metric: "jvm"]], "GET", "/_nodes/jvm"},
    {:nodes_info, [[node_id: "node-1", metric: ["jvm", "os"]]], "GET", "/_nodes/node-1/jvm,os"},
    {:nodes_stats, [[]], "GET", "/_nodes/stats"},
    {:nodes_stats, [[node_id: "node-1"]], "GET", "/_nodes/node-1/stats"},
    {:nodes_stats, [[metric: "indices"]], "GET", "/_nodes/stats/indices"},
    {:nodes_stats, [[metric: "indices", index_metric: "docs"]], "GET",
     "/_nodes/stats/indices/docs"},
    {:nodes_usage, [[]], "GET", "/_nodes/usage"},
    {:nodes_usage, [[node_id: "node-1", metric: "rest_actions"]], "GET",
     "/_nodes/node-1/usage/rest_actions"},
    {:nodes_reload_secure_settings, [%{}, []], "POST", "/_nodes/reload_secure_settings"},
    {:nodes_reload_secure_settings, [%{}, [node_id: "node-1"]], "POST",
     "/_nodes/node-1/reload_secure_settings"},
    {:nodes_get_repositories_metering_info, ["node-1", []], "GET",
     "/_nodes/node-1/_repositories_metering"},
    {:nodes_clear_repositories_metering_archive, ["node-1", 7, []], "DELETE",
     "/_nodes/node-1/_repositories_metering/7"}
  ]

  for {fun, args, method, path} <- @endpoints do
    test "#{fun}/#{length(args)} #{method}s #{path}" do
      {port, server} = start_server()

      args = unquote(Macro.escape(args))
      {opts, args} = List.pop_at(args, -1)

      assert {:ok, _body} =
               apply(Cluster, unquote(fun), args ++ [opts ++ [context: context(port)]])

      req = Task.await(server)
      assert req.method == unquote(method)
      assert req.path == unquote(path)
    end
  end

  describe "health/1" do
    test "forwards url params" do
      {port, server} = start_server()

      assert {:ok, _} =
               Cluster.health(params: [wait_for_status: "yellow"], context: context(port))

      assert Task.await(server).path == "/_cluster/health?wait_for_status=yellow"
    end

    test "wraps a non-2xx response in a Dowser.Elasticsearch.Error" do
      {port, server} = start_server(@server_error_response)

      assert {:error, %Error{status: 500}} = Cluster.health(context: context(port))

      Task.await(server)
    end

    test "health!/1 raises the error exception" do
      {port, server} = start_server(@server_error_response)

      assert_raise Error, fn ->
        Cluster.health!(context: context(port))
      end

      Task.await(server)
    end
  end

  describe "info/2" do
    test "requires a target" do
      assert {:error, %ArgumentError{} = error} = Cluster.info(nil)
      assert Exception.message(error) =~ "target is required"
    end

    test "info!/2 raises when the target is missing" do
      assert_raise ArgumentError, ~r/target is required/, fn ->
        Cluster.info!(nil)
      end
    end
  end

  describe "state/1" do
    test "refuses an :index without a :metric" do
      assert {:error, %ArgumentError{} = error} = Cluster.state(index: "posts")
      assert Exception.message(error) =~ ":index needs :metric"
    end
  end

  describe "nodes_stats/1" do
    test "refuses an :index_metric without a :metric" do
      assert {:error, %ArgumentError{} = error} = Cluster.nodes_stats(index_metric: "docs")
      assert Exception.message(error) =~ ":index_metric needs :metric"
    end
  end

  describe "nodes_hot_threads/1" do
    test "GETs the plain text body undecoded" do
      text = "::: {node-1}\n   Hot threads at 2026-09-21\n"

      response =
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{byte_size(text)}\r\n\r\n" <>
          text

      {port, server} = start_server(response)

      assert {:ok, ^text} = Cluster.nodes_hot_threads(context: context(port))

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/_nodes/hot_threads"
    end

    test "targets a single node" do
      text = "::: {node-1}\n"

      response =
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{byte_size(text)}\r\n\r\n" <>
          text

      {port, server} = start_server(response)

      assert {:ok, _} = Cluster.nodes_hot_threads(node_id: "node-1", context: context(port))
      assert Task.await(server).path == "/_nodes/node-1/hot_threads"
    end
  end

  describe "ping/1" do
    test "returns true on a 2xx" do
      {port, server} = start_server(HTTPStub.head_response(200))

      assert {:ok, true} = Cluster.ping(context: context(port))

      req = Task.await(server)
      assert req.method == "HEAD"
      assert req.path == "/"
    end

    test "returns false on a 404" do
      {port, server} = start_server(HTTPStub.head_response(404))

      assert {:ok, false} = Cluster.ping(context: context(port))

      Task.await(server)
    end

    test "ping?/1 returns the bare boolean" do
      {port, server} = start_server(HTTPStub.head_response(200))

      assert Cluster.ping?(context: context(port))

      Task.await(server)
    end
  end

  describe "put_settings/2" do
    test "sends the settings as the request body" do
      {port, server} = start_server()

      assert {:ok, _} =
               Cluster.put_settings(
                 %{"persistent" => %{"indices.recovery.max_bytes_per_sec" => "50mb"}},
                 context: context(port)
               )

      req = Task.await(server)
      assert req.body == ~s({"persistent":{"indices.recovery.max_bytes_per_sec":"50mb"}})
    end
  end

  defp context(port), do: HTTPStub.context(port)

  defp start_server(response \\ @response), do: HTTPStub.start_server(response)
end

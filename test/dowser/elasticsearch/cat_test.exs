defmodule Dowser.Elasticsearch.CatTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Cat
  alias Dowser.Elasticsearch.Error
  alias Dowser.Elasticsearch.HTTPStub

  @rows ~s([{"index":"posts","health":"green","docs.count":"42"}])
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@rows)}\r\n\r\n" <>
              @rows

  @server_error ~s({"message":"boom"})
  @server_error_response "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@server_error)}\r\n\r\n" <>
                           @server_error

  # {function, opts, expected path} — the whole cat surface, one row each.
  @endpoints [
    {:help, [], "/_cat"},
    {:indices, [], "/_cat/indices"},
    {:indices, [index: ["posts", "comments"]], "/_cat/indices/posts,comments"},
    {:count, [], "/_cat/count"},
    {:count, [index: "posts"], "/_cat/count/posts"},
    {:aliases, [], "/_cat/aliases"},
    {:aliases, [name: "latest"], "/_cat/aliases/latest"},
    {:shards, [], "/_cat/shards"},
    {:shards, [index: "posts"], "/_cat/shards/posts"},
    {:segments, [], "/_cat/segments"},
    {:segments, [index: "posts"], "/_cat/segments/posts"},
    {:recovery, [], "/_cat/recovery"},
    {:recovery, [index: "posts"], "/_cat/recovery/posts"},
    {:fielddata, [], "/_cat/fielddata"},
    {:fielddata, [fields: ["title", "body"]], "/_cat/fielddata/title,body"},
    {:health, [], "/_cat/health"},
    {:nodes, [], "/_cat/nodes"},
    {:nodeattrs, [], "/_cat/nodeattrs"},
    {:master, [], "/_cat/master"},
    {:allocation, [], "/_cat/allocation"},
    {:allocation, [node_id: "node-1"], "/_cat/allocation/node-1"},
    {:circuit_breaker, [], "/_cat/circuit_breaker"},
    {:circuit_breaker, [circuit_breaker_patterns: "request"], "/_cat/circuit_breaker/request"},
    {:thread_pool, [], "/_cat/thread_pool"},
    {:thread_pool, [thread_pool_patterns: "search"], "/_cat/thread_pool/search"},
    {:pending_tasks, [], "/_cat/pending_tasks"},
    {:tasks, [], "/_cat/tasks"},
    {:plugins, [], "/_cat/plugins"},
    {:templates, [], "/_cat/templates"},
    {:templates, [name: "posts-*"], "/_cat/templates/posts-*"},
    {:component_templates, [], "/_cat/component_templates"},
    {:component_templates, [name: "logs"], "/_cat/component_templates/logs"},
    {:repositories, [], "/_cat/repositories"},
    {:snapshots, [], "/_cat/snapshots"},
    {:snapshots, [repository: "backups"], "/_cat/snapshots/backups"},
    {:transforms, [], "/_cat/transforms"},
    {:transforms, [transform_id: "t1"], "/_cat/transforms/t1"},
    {:ml_jobs, [], "/_cat/ml/anomaly_detectors"},
    {:ml_jobs, [job_id: "j1"], "/_cat/ml/anomaly_detectors/j1"},
    {:ml_datafeeds, [], "/_cat/ml/datafeeds"},
    {:ml_datafeeds, [datafeed_id: "d1"], "/_cat/ml/datafeeds/d1"},
    {:ml_data_frame_analytics, [], "/_cat/ml/data_frame/analytics"},
    {:ml_data_frame_analytics, [id: "a1"], "/_cat/ml/data_frame/analytics/a1"},
    {:ml_trained_models, [], "/_cat/ml/trained_models"},
    {:ml_trained_models, [model_id: "m1"], "/_cat/ml/trained_models/m1"}
  ]

  for {fun, opts, path} <- @endpoints do
    test "#{fun}/1 GETs #{path}" do
      {port, server} = start_server()

      assert {:ok, _body} = apply(Cat, unquote(fun), [unquote(opts) ++ [context: context(port)]])

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == unquote(path)
    end
  end

  describe "help/1" do
    test "parses the plain text body into the list of endpoints" do
      text = "=^.^=\n/_cat/allocation\n/_cat/shards\n/_cat/shards/{index}\n"

      response =
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: #{byte_size(text)}\r\n\r\n" <>
          text

      {port, server} = start_server(response)

      assert {:ok, endpoints} = Cat.help(context: context(port))
      assert endpoints == ["/_cat/allocation", "/_cat/shards", "/_cat/shards/{index}"]

      Task.await(server)
    end
  end

  describe "indices/1" do
    test "decodes the rows" do
      {port, server} = start_server()

      assert {:ok, [row]} = Cat.indices(context: context(port))
      assert row["docs.count"] == "42"

      Task.await(server)
    end

    test "forwards url params" do
      {port, server} = start_server()

      assert {:ok, _} =
               Cat.indices(params: [v: true, s: "docs.count:desc"], context: context(port))

      assert Task.await(server).path == "/_cat/indices?v=true&s=docs.count%3Adesc"
    end

    test "wraps a non-2xx response in a Dowser.Elasticsearch.Error" do
      {port, server} = start_server(@server_error_response)

      assert {:error, %Error{status: 500}} = Cat.indices(context: context(port))

      Task.await(server)
    end
  end

  describe "indices!/1" do
    test "returns the body directly" do
      {port, server} = start_server()

      assert [%{"index" => "posts"}] = Cat.indices!(context: context(port))

      Task.await(server)
    end

    test "raises the error exception" do
      {port, server} = start_server(@server_error_response)

      assert_raise Error, fn ->
        Cat.indices!(context: context(port))
      end

      Task.await(server)
    end
  end

  defp context(port), do: HTTPStub.context(port)

  defp start_server(response \\ @response), do: HTTPStub.start_server(response)
end

defmodule Dowser.Elasticsearch.ReindexTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Error
  alias Dowser.Elasticsearch.HTTPStub
  alias Dowser.Elasticsearch.Reindex

  @task ~s({"completed":false,"task":{"id":"node-1:12345","status":{"created":42}}})
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@task)}\r\n\r\n" <>
              @task

  @server_error ~s({"message":"boom"})
  @server_error_response "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@server_error)}\r\n\r\n" <>
                           @server_error

  describe "list/1" do
    test "GETs /_reindex" do
      {port, server} = start_server()

      assert {:ok, body} = Reindex.list(context: context(port))
      assert body["task"]["id"] == "node-1:12345"

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/_reindex"
    end

    test "forwards url params" do
      {port, server} = start_server()

      assert {:ok, _} = Reindex.list(params: [detailed: true], context: context(port))
      assert Task.await(server).path == "/_reindex?detailed=true"
    end

    test "wraps a non-2xx response in a Dowser.Elasticsearch.Error" do
      {port, server} = start_server(@server_error_response)

      assert {:error, %Error{status: 500}} = Reindex.list(context: context(port))

      Task.await(server)
    end
  end

  describe "get/2" do
    test "GETs /_reindex/{task_id}" do
      {port, server} = start_server()

      assert {:ok, _} = Reindex.get("node-1:12345", context: context(port))

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/_reindex/node-1:12345"
    end

    test "forwards url params" do
      {port, server} = start_server()

      assert {:ok, _} =
               Reindex.get("node-1:12345",
                 params: [wait_for_completion: true, timeout: "30s"],
                 context: context(port)
               )

      assert Task.await(server).path ==
               "/_reindex/node-1:12345?wait_for_completion=true&timeout=30s"
    end

    test "requires a task id" do
      assert {:error, %ArgumentError{} = error} = Reindex.get(nil)
      assert Exception.message(error) =~ "task_id is required"
    end

    test "get!/2 raises when the task id is missing" do
      assert_raise ArgumentError, ~r/task_id is required/, fn ->
        Reindex.get!(nil)
      end
    end
  end

  describe "cancel/2" do
    test "POSTs /_reindex/{task_id}/_cancel" do
      {port, server} = start_server()

      assert {:ok, _} = Reindex.cancel("node-1:12345", context: context(port))

      req = Task.await(server)
      assert req.method == "POST"
      assert req.path == "/_reindex/node-1:12345/_cancel"
    end

    test "requires a task id" do
      assert {:error, %ArgumentError{} = error} = Reindex.cancel("")
      assert Exception.message(error) =~ "task_id is required"
    end

    test "cancel!/2 returns the body directly" do
      {port, server} = start_server()

      assert %{"completed" => false} = Reindex.cancel!("node-1:12345", context: context(port))

      Task.await(server)
    end

    test "cancel!/2 raises the error exception" do
      {port, server} = start_server(@server_error_response)

      assert_raise Error, fn ->
        Reindex.cancel!("node-1:12345", context: context(port))
      end

      Task.await(server)
    end
  end

  defp context(port), do: HTTPStub.context(port)

  defp start_server(response \\ @response), do: HTTPStub.start_server(response)
end

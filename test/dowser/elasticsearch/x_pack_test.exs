defmodule Dowser.Elasticsearch.XPackTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Error
  alias Dowser.Elasticsearch.HTTPStub
  alias Dowser.Elasticsearch.XPack

  @body ~s({"license":{"type":"basic"},"features":{"ml":{"available":true}},"watcher":{"count":{"active":2}}})
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@body)}\r\n\r\n" <>
              @body

  @server_error ~s({"message":"boom"})
  @server_error_response "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@server_error)}\r\n\r\n" <>
                           @server_error

  describe "info/1" do
    test "GETs /_xpack and decodes the response" do
      {port, server} = start_server()

      assert {:ok, body} = XPack.info(context: context(port))
      assert body["license"]["type"] == "basic"

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/_xpack"
    end

    test "forwards url params" do
      {port, server} = start_server()

      assert {:ok, _} =
               XPack.info(params: [categories: "license,features"], context: context(port))

      assert Task.await(server).path == "/_xpack?categories=license%2Cfeatures"
    end

    test "wraps a non-2xx response in a Dowser.Elasticsearch.Error" do
      {port, server} = start_server(@server_error_response)

      assert {:error, %Error{status: 500}} = XPack.info(context: context(port))

      Task.await(server)
    end

    test "info!/1 raises the error exception" do
      {port, server} = start_server(@server_error_response)

      assert_raise Error, fn ->
        XPack.info!(context: context(port))
      end

      Task.await(server)
    end
  end

  describe "usage/1" do
    test "GETs /_xpack/usage" do
      {port, server} = start_server()

      assert {:ok, body} = XPack.usage(context: context(port))
      assert body["watcher"]["count"]["active"] == 2

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/_xpack/usage"
    end

    test "forwards url params" do
      {port, server} = start_server()

      assert {:ok, _} = XPack.usage(params: [master_timeout: "30s"], context: context(port))
      assert Task.await(server).path == "/_xpack/usage?master_timeout=30s"
    end

    test "usage!/1 returns the body directly" do
      {port, server} = start_server()

      assert %{"license" => _} = XPack.usage!(context: context(port))

      Task.await(server)
    end
  end

  defp context(port), do: HTTPStub.context(port)

  defp start_server(response \\ @response), do: HTTPStub.start_server(response)
end

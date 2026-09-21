defmodule Dowser.Elasticsearch.InfoTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Error
  alias Dowser.Elasticsearch.HTTPStub
  alias Dowser.Elasticsearch.Info

  @info ~s({"name":"node-1","cluster_name":"docker-cluster","version":{"number":"8.13.4"},"tagline":"You Know, for Search"})
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@info)}\r\n\r\n" <>
              @info

  @server_error ~s({"message":"boom"})
  @server_error_response "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@server_error)}\r\n\r\n" <>
                           @server_error

  describe "info/1" do
    test "GETs / and decodes the response" do
      {port, server} = start_server()

      assert {:ok, body} = Info.info(context: context(port))
      assert body["version"]["number"] == "8.13.4"

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/"
    end

    test "forwards url params" do
      {port, server} = start_server()

      assert {:ok, _} = Info.info(params: [human: true], context: context(port))
      assert Task.await(server).path == "/?human=true"
    end

    test "wraps a non-2xx response in a Dowser.Elasticsearch.Error" do
      {port, server} = start_server(@server_error_response)

      assert {:error, %Error{status: 500}} = Info.info(context: context(port))

      Task.await(server)
    end
  end

  describe "info!/1" do
    test "returns the body directly" do
      {port, server} = start_server()

      assert %{"name" => "node-1"} = Info.info!(context: context(port))

      Task.await(server)
    end

    test "raises the error exception" do
      {port, server} = start_server(@server_error_response)

      assert_raise Error, fn ->
        Info.info!(context: context(port))
      end

      Task.await(server)
    end
  end

  defp context(port), do: HTTPStub.context(port)

  defp start_server(response \\ @response), do: HTTPStub.start_server(response)
end

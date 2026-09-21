defmodule Dowser.Elasticsearch.HealthReportTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Error
  alias Dowser.Elasticsearch.HealthReport
  alias Dowser.Elasticsearch.HTTPStub

  @report ~s({"status":"green","cluster_name":"docker-cluster","indicators":{"master_is_stable":{"status":"green"}}})
  @response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@report)}\r\n\r\n" <>
              @report

  @server_error ~s({"message":"boom"})
  @server_error_response "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@server_error)}\r\n\r\n" <>
                           @server_error

  describe "health_report/1" do
    test "GETs /_health_report and decodes the response" do
      {port, server} = start_server()

      assert {:ok, body} = HealthReport.health_report(context: context(port))
      assert body["status"] == "green"

      req = Task.await(server)
      assert req.method == "GET"
      assert req.path == "/_health_report"
    end

    test "targets a single feature" do
      {port, server} = start_server()

      assert {:ok, _} =
               HealthReport.health_report(feature: "shards_availability", context: context(port))

      assert Task.await(server).path == "/_health_report/shards_availability"
    end

    test "unwraps a one-element feature list" do
      {port, server} = start_server()

      assert {:ok, _} = HealthReport.health_report(feature: ["disk"], context: context(port))
      assert Task.await(server).path == "/_health_report/disk"
    end

    test "refuses several features, which Elasticsearch answers with a 404" do
      assert {:error, %ArgumentError{} = error} =
               HealthReport.health_report(feature: ["disk", "master_is_stable"])

      assert Exception.message(error) =~ "single indicator name"
    end

    test "forwards url params" do
      {port, server} = start_server()

      assert {:ok, _} =
               HealthReport.health_report(
                 params: [verbose: false, size: 10],
                 context: context(port)
               )

      assert Task.await(server).path == "/_health_report?verbose=false&size=10"
    end

    test "wraps a non-2xx response in a Dowser.Elasticsearch.Error" do
      {port, server} = start_server(@server_error_response)

      assert {:error, %Error{status: 500}} = HealthReport.health_report(context: context(port))

      Task.await(server)
    end
  end

  describe "health_report!/1" do
    test "returns the body directly" do
      {port, server} = start_server()

      assert %{"status" => "green"} = HealthReport.health_report!(context: context(port))

      Task.await(server)
    end

    test "raises the error exception" do
      {port, server} = start_server(@server_error_response)

      assert_raise Error, fn ->
        HealthReport.health_report!(context: context(port))
      end

      Task.await(server)
    end

    test "raises on several features" do
      assert_raise ArgumentError, ~r/single indicator name/, fn ->
        HealthReport.health_report!(feature: ["disk", "master_is_stable"])
      end
    end
  end

  defp context(port), do: HTTPStub.context(port)

  defp start_server(response \\ @response), do: HTTPStub.start_server(response)
end

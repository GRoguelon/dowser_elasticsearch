defmodule Dowser.Elasticsearch.HTTPStub do
  @moduledoc """
  One-shot TCP server for tests: accepts a single HTTP request, replies with a
  canned response, and hands the parsed request back through a `Task`.
  """

  @ok_body ~s({"acknowledged":true})
  @ok_response "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(@ok_body)}\r\n\r\n" <>
                 @ok_body

  @doc "A canned `200` JSON response (`#{@ok_body}`)."
  def ok_response, do: @ok_response

  @doc "A canned body-less response with the given status (for `HEAD` checks)."
  def head_response(200), do: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
  def head_response(404), do: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"

  @doc "Config options pointing at the stub server."
  def config(port), do: [endpoint: "http://127.0.0.1:#{port}"]

  @doc """
  Config options pointing at the stub server, with
  `Dowser.Elasticsearch.Codec` set as `:codec_adapter`.
  """
  def config_with_codec_adapter(port) do
    [endpoint: "http://127.0.0.1:#{port}", codec_adapter: Dowser.Elasticsearch.Codec]
  end

  @doc """
  Starts `Dowser.Elasticsearch.MappingCacher` for the duration of the calling
  test (via `start_supervised!/1`), returning `mapping` for every
  `{config, index}` lookup.
  """
  def start_mapping_cacher!(mapping) do
    ExUnit.Callbacks.start_supervised!(
      {Dowser.Elasticsearch.MappingCacher, fetch: fn _config, _index -> {:ok, mapping} end}
    )
  end

  @doc """
  Starts the server; returns `{port, task}`. Await the task to get the parsed
  request as `%{method: ..., path: ..., headers: ..., body: ...}`.
  """
  def start_server(response \\ @ok_response) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5000)
        raw = recv_until(socket, "", "\r\n\r\n")
        [head, rest] = String.split(raw, "\r\n\r\n", parts: 2)
        body = rest <> recv_exact(socket, content_length(head) - byte_size(rest))
        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        parse(head, body)
      end)

    {port, server}
  end

  defp recv_until(socket, acc, marker) do
    if String.contains?(acc, marker) do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 5000)
      recv_until(socket, acc <> data, marker)
    end
  end

  defp recv_exact(_socket, n) when n <= 0, do: ""

  defp recv_exact(socket, n) do
    {:ok, data} = :gen_tcp.recv(socket, n, 5000)
    data
  end

  defp content_length(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          if String.downcase(String.trim(key)) == "content-length" do
            String.to_integer(String.trim(value))
          end

        _other ->
          nil
      end
    end)
  end

  defp parse(head, body) do
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, path, _version] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        {String.downcase(String.trim(key)), String.trim(value)}
      end)

    %{method: method, path: path, headers: headers, body: body}
  end
end

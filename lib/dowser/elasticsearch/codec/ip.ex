defmodule Dowser.Elasticsearch.Codec.IP do
  @moduledoc "`ip` — a string <-> an `:inet` address tuple (`{1, 2, 3, 4}`)."

  require Logger

  @behaviour Dowser.Elasticsearch.Codec

  @impl true
  def decode(value, _field) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, address} ->
        address

      {:error, error} ->
        Logger.error("Unknown error while decoding Dowser.Elasticsearch.Codec.IP: #{error}")

        value
    end
  end

  def decode(value, _field) do
    value
  end

  @impl true
  def encode(address, _field) when is_tuple(address) do
    case :inet.ntoa(address) do
      {:error, error} ->
        Logger.error("Unknown error while encoding Dowser.Elasticsearch.Codec.IP: #{error}")

        address

      charlist ->
        to_string(charlist)
    end
  end

  def encode(value, _field) do
    value
  end
end

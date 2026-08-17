defmodule Dowser.Elasticsearch.Fields.IP do
  @moduledoc "`ip` — a string <-> an `:inet` address tuple (`{1, 2, 3, 4}`)."

  require Logger

  @behaviour Dowser.Client.Field

  @impl Dowser.Client.Field
  def load(value, _field) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, address} ->
        address

      {:error, error} ->
        Logger.error("Unknown error while loading Dowser.Elasticsearch.Fields.IP: #{error}")

        value
    end
  end

  def load(value, _field) do
    value
  end

  @impl Dowser.Client.Field
  def dump(address, _field) when is_tuple(address) do
    case :inet.ntoa(address) do
      {:error, error} ->
        Logger.error("Unknown error while dumping Dowser.Elasticsearch.Fields.IP: #{error}")

        address

      charlist ->
        to_string(charlist)
    end
  end

  def dump(value, _field) do
    value
  end
end

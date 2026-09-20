defmodule Dowser.Elasticsearch.Codec.Binary do
  @moduledoc """
  `binary` — a Base64 string <-> a raw binary.

  `encode/2` assumes it receives the raw binary (what `decode/2` produced) and
  Base64-encodes it.
  """

  require Logger

  @behaviour Dowser.Elasticsearch.Codec

  @impl true
  def decode(value, _field) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} ->
        decoded

      :error ->
        Logger.error(
          "Unknown error while decoding Dowser.Elasticsearch.Codec.Binary: invalid Base64"
        )

        value
    end
  end

  def decode(value, _field) do
    value
  end

  @impl true
  def encode(value, _field) when is_binary(value) do
    Base.encode64(value)
  end

  def encode(value, _field) do
    value
  end
end

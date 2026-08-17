defmodule Dowser.Elasticsearch.Fields.Binary do
  @moduledoc """
  `binary` — a Base64 string <-> a raw binary.

  `dump/2` assumes it receives the raw binary (what `load/2` produced) and
  Base64-encodes it.
  """

  require Logger

  @behaviour Dowser.Client.Field

  @impl Dowser.Client.Field
  def load(value, _field) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} ->
        decoded

      :error ->
        Logger.error(
          "Unknown error while loading Dowser.Elasticsearch.Fields.Binary: invalid Base64"
        )

        value
    end
  end

  def load(value, _field) do
    value
  end

  @impl Dowser.Client.Field
  def dump(value, _field) when is_binary(value) do
    Base.encode64(value)
  end

  def dump(value, _field) do
    value
  end
end

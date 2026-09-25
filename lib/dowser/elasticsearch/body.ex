defmodule Dowser.Elasticsearch.Body do
  @moduledoc false

  # A response body reaches the library after `Dowser.Client` has applied the
  # configured `:keys`, so a map the library has to read itself — an error
  # object, a bulk item — may be string- or atom-keyed. Reading it by literal
  # string key works under the default `keys: :strings` only, and silently
  # finds nothing under `:atoms`/`:atoms!`; these helpers match by name
  # instead.
  #
  # Bodies the library reads through a request of its own
  # (`Dowser.Elasticsearch.Streamer`, `Dowser.Elasticsearch.MappingCacher`)
  # force `keys: :strings` and don't need this.

  @doc "The value held under `name`, whatever shape that key has, or `default`."
  @spec value(term(), String.t(), term()) :: term()
  def value(map, name, default \\ nil)

  def value(map, name, default) when is_map(map) and not is_struct(map) do
    case Enum.find(map, fn {key, _value} -> named?(key, name) end) do
      {_key, value} ->
        value

      nil ->
        default
    end
  end

  def value(_map, _name, default), do: default

  @doc """
  The first of `names` the map holds a value for, as `{name, value}`, or `nil`.

  Used where a map is keyed by *which* thing it is rather than by a fixed name
  — a bulk item, keyed by its action.
  """
  @spec first(term(), [String.t()]) :: {String.t(), term()} | nil
  def first(map, names) when is_map(map) do
    Enum.find_value(names, fn name ->
      case value(map, name, :__missing__) do
        :__missing__ ->
          nil

        value ->
          {name, value}
      end
    end)
  end

  def first(_map, _names), do: nil

  defp named?(key, name) when is_binary(key) or is_atom(key), do: to_string(key) == name
  defp named?(_key, _name), do: false
end

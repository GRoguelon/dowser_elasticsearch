defmodule Dowser.Elasticsearch.Error do
  @moduledoc """
  An error response returned by Elasticsearch — a non-2xx HTTP status.

  `:status` is the HTTP status code and `:body` the (decoded) response body.
  When the body is a standard Elasticsearch error object
  (`%{"error" => %{"type" => ..., "reason" => ...}}`), `:type` and `:reason` are
  extracted for convenience.

  The body reaches this module after `Dowser.Client` has applied the configured
  `:keys` option, so its keys may be strings (the default) or atoms
  (`keys: :atoms`/`:atoms!`); both shapes are recognised. When the error object
  carries a `root_cause`/`caused_by` entry whose reason adds something — the
  case with `search_phase_execution_exception`, whose own reason is just
  `"all shards failed"` — that nested reason is appended to `:reason`.
  """

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          body: term(),
          type: String.t() | nil,
          reason: String.t() | nil
        }

  defexception [:status, :body, :type, :reason]

  @doc """
  Builds an error from a response status and body, extracting `:type`/`:reason`
  from a standard Elasticsearch error body when present.
  """
  @spec new(non_neg_integer(), term()) :: t()
  def new(status, body) do
    {type, reason} = extract(body)
    %__MODULE__{status: status, body: body, type: type, reason: reason}
  end

  @impl true
  def message(%__MODULE__{status: status, type: type, reason: reason}) do
    case Enum.reject([type && "[#{type}]", reason], &is_nil/1) do
      [] ->
        "Elasticsearch responded with HTTP #{status}"

      detail ->
        "Elasticsearch responded with HTTP #{status}: #{Enum.join(detail, " ")}"
    end
  end

  defp extract(%{} = body) when not is_struct(body) do
    case value(body, "error") do
      %{} = error ->
        {value(error, "type"), reason(error)}

      error when is_binary(error) ->
        {nil, error}

      _other ->
        {nil, nil}
    end
  end

  defp extract(_body), do: {nil, nil}

  defp reason(error) do
    case {value(error, "reason"), nested_reason(error)} do
      {reason, nested} when is_binary(reason) and is_binary(nested) ->
        if String.contains?(reason, nested) do
          reason
        else
          reason <> ": " <> nested
        end

      {reason, _nested} when is_binary(reason) ->
        reason

      {_reason, nested} ->
        nested
    end
  end

  defp nested_reason(error) do
    cause =
      case value(error, "root_cause") do
        [first | _] ->
          first

        _other ->
          value(error, "caused_by")
      end

    with %{} = cause <- cause,
         reason when is_binary(reason) <- value(cause, "reason") do
      reason
    else
      _other ->
        nil
    end
  end

  # Keys come out of the client as strings or atoms, depending on its `:keys`
  # option, so they are matched by name rather than by shape.
  defp value(map, name) when is_map(map) do
    case Enum.find(map, fn {key, _value} -> named?(key, name) end) do
      {_key, value} ->
        value

      nil ->
        nil
    end
  end

  defp value(_map, _name), do: nil

  defp named?(key, name) when is_binary(key) or is_atom(key), do: to_string(key) == name
  defp named?(_key, _name), do: false
end

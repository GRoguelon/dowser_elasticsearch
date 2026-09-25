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

  alias Dowser.Elasticsearch.Body

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          body: term(),
          type: String.t() | nil,
          reason: String.t() | nil
        }

  defexception [:status, :body, :type, :reason]

  @doc """
  Builds an error from a response status and body, extracting `:type`/`:reason`
  from a standard Elasticsearch error body when present.

  `status` may be `nil` for an error that is not a response of its own — one
  bulk item's, which `Dowser.Elasticsearch.BulkError` reports per item.
  """
  @spec new(non_neg_integer() | nil, term()) :: t()
  def new(status, body) do
    {type, reason} = extract(body)
    %__MODULE__{status: status, body: body, type: type, reason: reason}
  end

  @impl true
  def message(%__MODULE__{status: status, type: type, reason: reason}) do
    prefix =
      if status do
        "Elasticsearch responded with HTTP #{status}"
      else
        "Elasticsearch reported an error"
      end

    case Enum.reject([type && "[#{type}]", reason], &is_nil/1) do
      [] ->
        prefix

      detail ->
        "#{prefix}: #{Enum.join(detail, " ")}"
    end
  end

  defp extract(body) do
    case value(body, "error") do
      %{} = error ->
        {value(error, "type"), reason(error)}

      error when is_binary(error) ->
        {nil, error}

      _other ->
        {nil, nil}
    end
  end

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

  defp value(map, name), do: Body.value(map, name)
end

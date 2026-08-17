defmodule Dowser.Elasticsearch.Error do
  @moduledoc """
  An error response returned by Elasticsearch — a non-2xx HTTP status.

  `:status` is the HTTP status code and `:body` the (decoded) response body.
  When the body is a standard Elasticsearch error object
  (`%{"error" => %{"type" => ..., "reason" => ...}}`), `:type` and `:reason` are
  extracted for convenience.
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

  defp extract(%{"error" => %{} = error}), do: {Map.get(error, "type"), Map.get(error, "reason")}
  defp extract(%{"error" => error}) when is_binary(error), do: {nil, error}
  defp extract(_body), do: {nil, nil}
end

defmodule Dowser.Elasticsearch.BulkError do
  @moduledoc """
  The partial failure of a `Dowser.Elasticsearch.Document.bulk/2` request.

  A bulk request is never all-or-nothing: Elasticsearch answers `200 OK` with
  `"errors" => true` and reports the outcome of each action separately, so a
  request in which half the documents were rejected looks, at the HTTP level,
  exactly like one in which every document was indexed. `bulk/2` therefore
  returns `{:error, %#{inspect(__MODULE__)}{}}` whenever any item failed, and
  this exception carries what failed and what did not:

    * `:items` — every item of the response, in request order.
    * `:failed` — one entry per failed item (see below).
    * `:succeeded` — how many items were applied.
    * `:retryable` — the operations of the items Elasticsearch *rejected*
      (per-item `429`/`503`), as a flat list ready to hand back to `bulk/2`.
      Resubmitting these re-applies only what was never applied, where
      resending the whole payload would write the successful items twice.
    * `:took` and `:body` — the response's `took` and the whole decoded body.

  Each `:failed` entry is a map:

      %{
        position: 3,              # 0-based index into the response items
        action: "index",          # "index" | "create" | "update" | "delete"
        index: "posts",
        id: "42",
        status: 429,
        operation: [%{index: %{_index: "posts", _id: "42"}}, %{title: "hi"}],
        error: %Dowser.Elasticsearch.Error{}
      }

  `:operation` holds the action line and its payload as they were given to
  `bulk/2` — `nil` when the response has more items than the request had
  actions, which shouldn't happen but isn't worth crashing over.

  ## Example

      case Dowser.Elasticsearch.Document.bulk(operations, index: "posts") do
        {:ok, _body} ->
          :ok

        {:error, %Dowser.Elasticsearch.BulkError{retryable: [_ | _] = operations}} ->
          # Elasticsearch rejected some items under load: resubmit just those,
          # after backing off.
          Dowser.Elasticsearch.Document.bulk(operations, index: "posts")

        {:error, error} ->
          {:error, error}
      end
  """

  alias Dowser.Elasticsearch.Error

  @type failure :: %{
          position: non_neg_integer(),
          action: String.t(),
          index: String.t() | nil,
          id: String.t() | nil,
          status: non_neg_integer() | nil,
          operation: [map()] | nil,
          error: Error.t()
        }

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          took: non_neg_integer() | nil,
          items: [map()],
          failed: [failure()],
          succeeded: non_neg_integer(),
          retryable: [map()],
          body: term()
        }

  defexception status: 200,
               took: nil,
               items: [],
               failed: [],
               succeeded: 0,
               retryable: [],
               body: nil

  @impl true
  def message(%__MODULE__{failed: failed, succeeded: succeeded}) do
    total = length(failed) + succeeded

    "#{length(failed)} of #{total} bulk items failed#{summary(failed)}"
  end

  defp summary([]), do: ""

  defp summary(failed) do
    detail =
      failed
      |> Enum.map(fn %{error: %Error{type: type}} -> type || "unknown" end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_type, count} -> -count end)
      |> Enum.map_join(", ", fn {type, count} -> "#{count} × #{type}" end)

    ": " <> detail
  end
end

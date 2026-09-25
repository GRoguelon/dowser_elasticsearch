defmodule Dowser.Elasticsearch.Bulk do
  @moduledoc false

  # Request- and response-side helpers for `Dowser.Elasticsearch.Document.bulk/2`:
  # which action an action line names, how the flat operation list pairs up, and
  # how a `200 OK` body reporting per-item failures becomes a
  # `Dowser.Elasticsearch.BulkError`.

  alias Dowser.Elasticsearch.Body
  alias Dowser.Elasticsearch.BulkError
  alias Dowser.Elasticsearch.Error

  @actions [:index, :create, :update, :delete]

  # Statuses Elasticsearch uses for an item it *rejected* rather than tried:
  # resubmitting those writes nothing twice. A 409 (version conflict) or a 400
  # (mapping failure) is deliberate and would fail again.
  @retryable_statuses [429, 503]

  @doc """
  The action an action line names, as `{action, its value}` — `{:index, line}`
  when it names none, which is what Elasticsearch assumes too.
  """
  @spec action(map()) :: {atom(), map()}
  def action(header) do
    Enum.find_value(@actions, {:index, header}, fn action ->
      case Body.value(header, Atom.to_string(action)) do
        %{} = value ->
          {action, value}

        _other ->
          nil
      end
    end)
  end

  @doc """
  Whether re-sending this operation list after an ambiguous failure — a
  timeout, a dropped connection — can do anything the first attempt may
  already have done.

  True only when every action is an `index` or a `delete` naming its own
  `_id`: replacing a document at a known id, or deleting it, gives the same
  result however many times it happens. An auto-id `index` writes a new
  document each attempt, a `create` fails with a `409` once the first attempt
  landed, and an `update` may run a script that counts.
  """
  @spec idempotent?([map()]) :: boolean()
  def idempotent?(operations) do
    operations
    |> chunks()
    |> Enum.all?(fn [header | _payload] ->
      case action(header) do
        {action, value} when action in [:index, :delete] ->
          Body.value(value, "_id") != nil

        _other ->
          false
      end
    end)
  end

  @doc """
  Groups a flat operation list into one chunk per action: `[action, payload]`,
  or `[action]` for a `delete` (which carries no payload).

  The chunks line up one-for-one with the response's `items`, which is what
  lets a failed item name the operation that caused it.
  """
  @spec chunks([map()]) :: [[map()]]
  def chunks(operations) do
    {chunks, pending} = Enum.reduce(operations, {[], nil}, &chunk_step/2)

    chunks =
      if pending do
        [Enum.reverse(pending) | chunks]
      else
        chunks
      end

    Enum.reverse(chunks)
  end

  @doc """
  Turns a bulk result into `{:error, %Dowser.Elasticsearch.BulkError{}}` when
  the response reports any failed item, and passes everything else through.

  `operations` is the operation list as it was given to `bulk/2`, so the error
  can hand back the failed operations themselves.
  """
  @spec check({:ok, term()} | {:error, Exception.t()}, [map()]) ::
          {:ok, term()} | {:error, Exception.t()}
  def check({:ok, body}, operations) do
    items = body |> Body.value("items", []) |> List.wrap()
    failed = failures(items, chunks(operations))

    if failed == [] and Body.value(body, "errors") != true do
      {:ok, body}
    else
      {:error, error(body, items, failed)}
    end
  end

  def check(result, _operations), do: result

  ## Private functions — request side

  defp chunk_step(item, {chunks, nil}) do
    case action(item) do
      {:delete, _value} ->
        {[[item] | chunks], nil}

      _other ->
        {chunks, [item]}
    end
  end

  defp chunk_step(item, {chunks, pending}) do
    {[Enum.reverse([item | pending]) | chunks], nil}
  end

  ## Private functions — response side

  defp failures(items, chunks) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, position} ->
      case failure(item, position, Enum.at(chunks, position)) do
        nil ->
          []

        failure ->
          [failure]
      end
    end)
  end

  defp failure(item, position, operation) do
    {action, result} = item_result(item)
    status = Body.value(result, "status")
    error = Body.value(result, "error")

    if error || failed_status?(status) do
      %{
        position: position,
        action: action,
        index: Body.value(result, "_index"),
        id: Body.value(result, "_id"),
        status: status,
        operation: operation,
        error: Error.new(status, %{"error" => error})
      }
    end
  end

  defp item_result(item) do
    case Body.first(item, Enum.map(@actions, &Atom.to_string/1)) do
      {action, %{} = result} ->
        {action, result}

      _other ->
        {"index", item}
    end
  end

  defp failed_status?(status), do: is_integer(status) and status >= 300

  defp error(body, items, failed) do
    %BulkError{
      status: 200,
      took: Body.value(body, "took"),
      items: items,
      failed: failed,
      succeeded: length(items) - length(failed),
      retryable: retryable(failed),
      body: body
    }
  end

  defp retryable(failed) do
    Enum.flat_map(failed, fn
      %{status: status, operation: operation} when is_list(operation) ->
        if status in @retryable_statuses do
          operation
        else
          []
        end

      _other ->
        []
    end)
  end
end

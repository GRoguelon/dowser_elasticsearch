defmodule Dowser.Elasticsearch.Reindex do
  @moduledoc """
  The Elasticsearch reindex task APIs — every endpoint tagged `reindex` in the
  [Elasticsearch OpenAPI specification](https://github.com/elastic/elasticsearch-specification):
  listing the reindex tasks that are running, following one, and cancelling
  one.

  These track a reindex; they don't start one. The reindex itself is
  `Dowser.Elasticsearch.Document.reindex/2` (`POST /_reindex`), which the
  specification tags `document`, and so is its
  `Dowser.Elasticsearch.Document.reindex_rethrottle/3`. Run it with
  `params: [wait_for_completion: false]` to get back the `task` these
  functions take.

  A task is followed by its id across node-shutdown relocations, so the id the
  reindex returned stays the one to ask about for the lifetime of the
  operation.

  Built on `Dowser.Client`. The task id is a positional argument where the
  endpoint requires one; everything optional lives in `opts`.

  All options are forwarded to `Dowser.Client.request/4`, e.g. `:context`,
  `:params` (query-string parameters), `:format`, `:keys` and `:http_opts`
  (including `:headers`).

  On a 2xx response every function returns `{:ok, body}` with the decoded
  response body. A non-2xx response returns
  `{:error, %Dowser.Elasticsearch.Error{}}`; a transport, encoding or decoding
  failure returns `{:error, exception}` from `Dowser.Client`. A required
  argument that is missing or empty is reported the same way, before any
  request is made: `{:error, %ArgumentError{}}`. Each function has a bang
  variant that returns the body directly or raises the error exception.
  """

  alias Dowser.Elasticsearch.Client
  alias Dowser.Elasticsearch.Helpers

  ## Typespecs

  @typedoc "A reindex task id, as returned by `POST /_reindex`."
  @type task_id :: String.t() | atom()

  @type body :: term()
  @type result :: {:ok, body()} | {:error, Exception.t()}

  ## Public functions

  @doc """
  Lists the reindex tasks currently running — `GET /_reindex`
  ([List reindex tasks API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-list-reindex)).

  A task mid-relocation between nodes is reported once, under its original id,
  so a relocation never shows up as a duplicate.

  ## Options

    * `:params` — `detailed: true` adds each task's progress and sub-tasks.
  """
  @spec list(keyword()) :: result()
  def list(opts \\ []) do
    "/_reindex"
    |> Client.get(opts)
    |> Helpers.parse_result()
  end

  @doc """
  Like `list/1`, but returns the body directly or raises the error exception.
  """
  @spec list!(keyword()) :: body()
  def list!(opts \\ []) do
    opts |> list() |> Dowser.unwrap()
  end

  @doc """
  Returns the status and progress of the reindex task `task_id` — `GET
  /_reindex/{task_id}`
  ([Get reindex task API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-get-reindex)).

      {:ok, task} = Dowser.Elasticsearch.Reindex.get("node-1:12345")
      task["completed"]
      #=> false

  ## Options

    * `:params` — `wait_for_completion: true` waits for the task to finish
      before answering, `timeout` caps that wait.
  """
  @spec get(task_id(), keyword()) :: result()
  def get(task_id, opts \\ []) do
    with {:ok, task_segment} <- Helpers.required_segment(task_id, "task_id") do
      ("/_reindex/" <> task_segment)
      |> Client.get(opts)
      |> Helpers.parse_result()
    end
  end

  @doc """
  Like `get/2`, but returns the body directly or raises the error exception.
  """
  @spec get!(task_id(), keyword()) :: body()
  def get!(task_id, opts \\ []) do
    task_id |> get(opts) |> Dowser.unwrap()
  end

  @doc """
  Cancels the reindex task `task_id` — `POST /_reindex/{task_id}/_cancel`
  ([Cancel reindex task API](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-cancel-reindex)).

  The documents already reindexed stay where they are; cancelling stops the
  task from writing any more.

  ## Options

    * `:params` — `wait_for_completion` is `true` by default, and the response
      is the task's final state after cancellation; `false` answers
      `acknowledged: true` right away.
  """
  @spec cancel(task_id(), keyword()) :: result()
  def cancel(task_id, opts \\ []) do
    with {:ok, task_segment} <- Helpers.required_segment(task_id, "task_id") do
      ("/_reindex/" <> task_segment <> "/_cancel")
      |> Client.post(nil, opts)
      |> Helpers.parse_result()
    end
  end

  @doc """
  Like `cancel/2`, but returns the body directly or raises the error
  exception.
  """
  @spec cancel!(task_id(), keyword()) :: body()
  def cancel!(task_id, opts \\ []) do
    task_id |> cancel(opts) |> Dowser.unwrap()
  end
end

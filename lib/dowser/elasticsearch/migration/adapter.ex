defmodule Dowser.Elasticsearch.Migration.Adapter do
  @moduledoc """
  Runs `Dowser.Migration`s against Elasticsearch — the `Dowser.Migration.Adapter`
  every `use Dowser.Elasticsearch.Repo` names, so `mix dowser.migrate` works on
  an Elasticsearch repo without configuration.

  It keeps the migrations run, and the migration lock, in the
  `dowser_schema_migrations` index, created on the first run: one document per
  migration (its version as id), and one `lock` document — created with
  `op_type=create`, so only one migrator can hold it.

  Responses are read as the cluster sends them: the repo's decoder, which
  casts documents, never sees them.
  """

  use Dowser.Migration.Adapter

  alias Dowser.Elasticsearch.Helpers
  alias Dowser.Migration.Settings

  @tracking "dowser_schema_migrations"
  @lock "lock"

  @tracking_body %{
    "settings" => %{"index.number_of_shards" => 1, "index.auto_expand_replicas" => "0-1"},
    "mappings" => %{
      "dynamic" => false,
      "properties" => %{
        "type" => %{"type" => "keyword"},
        "version" => %{"type" => "long"},
        "name" => %{"type" => "keyword"},
        "indices" => %{"type" => "keyword"},
        "dropped" => %{"type" => "keyword"},
        "separators" => %{"type" => "object", "enabled" => false},
        "owner" => %{"type" => "keyword"},
        "acquired_at" => %{"type" => "date"},
        "state" => %{"type" => "object", "enabled" => false}
      }
    }
  }

  ## Tracking

  @impl true
  def ensure_tracking(repo) do
    case request(repo, :head, "/#{@tracking}") do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 404}} ->
        case request(repo, :put, "/#{@tracking}", @tracking_body) |> result() do
          {:error, %{type: "resource_already_exists_exception"}} ->
            :ok

          other ->
            ok(other)
        end

      other ->
        other |> result() |> ok()
    end
  end

  @impl true
  def applied(repo) do
    query = %{
      "query" => %{"term" => %{"type" => "migration"}},
      "size" => 10_000,
      "sort" => [%{"version" => "asc"}]
    }

    case request(repo, :post, "/#{@tracking}/_search", query) |> result() do
      {:ok, %{"hits" => %{"hits" => hits}}} ->
        {:ok, Enum.map(hits, &Map.delete(&1["_source"], "type"))}

      {:error, %{status: 404}} ->
        {:ok, []}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def record(repo, record) do
    repo
    |> request(
      :put,
      "/#{@tracking}/_doc/#{record["version"]}",
      Map.put(record, "type", "migration"),
      params: [refresh: true]
    )
    |> result()
    |> ok()
  end

  @impl true
  def unrecord(repo, version) do
    repo
    |> request(:delete, "/#{@tracking}/_doc/#{version}", nil, params: [refresh: true])
    |> result()
    |> ok(:not_found)
  end

  ## The lock

  @impl true
  def lock(repo, lock) do
    path = "/#{@tracking}/_create/#{@lock}"

    case request(repo, :put, path, Map.put(lock, "type", "lock"), params: [refresh: true])
         |> result() do
      {:ok, _body} ->
        :ok

      {:error, %{status: 409}} ->
        case get_lock(repo) do
          {:ok, held} ->
            {:error, {:locked, held || %{}}}

          error ->
            error
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def get_lock(repo) do
    case request(repo, :get, "/#{@tracking}/_doc/#{@lock}") |> result() do
      {:ok, %{"_source" => source}} ->
        {:ok, Map.delete(source, "type")}

      {:error, %{status: 404}} ->
        {:ok, nil}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def update_lock(repo, lock) do
    with {:ok, held} <- get_lock(repo) do
      lock = Map.merge(held || %{}, lock)

      repo
      |> request(:put, "/#{@tracking}/_doc/#{@lock}", Map.put(lock, "type", "lock"),
        params: [refresh: true]
      )
      |> result()
      |> ok()
    end
  end

  @impl true
  def unlock(repo) do
    repo
    |> request(:delete, "/#{@tracking}/_doc/#{@lock}", nil, params: [refresh: true])
    |> result()
    |> ok(:not_found)
  end

  ## Indices

  @impl true
  def get_indices(repo, names) do
    params = [flat_settings: true, ignore_unavailable: true, allow_no_indices: true]

    case request(repo, :get, "/" <> Enum.join(names, ","), nil, params: params) |> result() do
      {:ok, indices} ->
        {:ok,
         Map.new(indices, fn {name, index} ->
           {name,
            %{
              "aliases" => index |> Map.get("aliases", %{}) |> Map.keys(),
              "mappings" => Map.get(index, "mappings", %{}),
              "settings" => index |> Map.get("settings", %{}) |> Settings.flatten()
            }}
         end)}

      {:error, %{status: 404}} ->
        {:ok, %{}}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def create_index(repo, index, body),
    do: repo |> request(:put, "/#{index}", body) |> result() |> ok()

  @impl true
  def delete_index(repo, index), do: repo |> request(:delete, "/#{index}") |> result() |> ok()

  @impl true
  def put_mapping(repo, index, body) do
    repo |> request(:put, "/#{index}/_mapping", body) |> result() |> ok()
  end

  @impl true
  def put_settings(repo, index, settings) do
    repo |> request(:put, "/#{index}/_settings", settings) |> result() |> ok()
  end

  @impl true
  def add_write_block(repo, index) do
    repo |> request(:put, "/#{index}/_block/write") |> result() |> ok()
  end

  @impl true
  def remove_write_block(repo, index) do
    put_settings(repo, index, %{"index.blocks.write" => nil})
  end

  @impl true
  def swap_alias(repo, name, from, to) do
    actions = [
      %{"remove" => %{"index" => from, "alias" => name}},
      %{"add" => %{"index" => to, "alias" => name}}
    ]

    repo |> request(:post, "/_aliases", %{"actions" => actions}) |> result() |> ok()
  end

  @impl true
  def reindex(repo, source, dest, script) do
    body = %{"source" => %{"index" => source}, "dest" => %{"index" => dest}}
    body = if script, do: Map.put(body, "script", script), else: body

    case request(repo, :post, "/_reindex", body, params: [wait_for_completion: false])
         |> result() do
      {:ok, %{"task" => task}} ->
        {:ok, task}

      {:ok, body} ->
        {:error, {:unexpected_response, body}}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def get_task(repo, task), do: repo |> request(:get, "/_tasks/#{task}") |> result()

  ## Private functions

  defp request(repo, method, path, body \\ nil, opts \\ []) do
    Dowser.Repo.request(repo, method, path, body, [keys: :strings, decoder: &raw/2] ++ opts)
  end

  # What the cluster says about its indices and tasks, not documents: nothing
  # the repo's decoder should cast.
  defp raw(body, _opts), do: body

  defp result(result), do: Helpers.parse_result(result)

  defp ok(result, tolerated \\ nil)
  defp ok({:ok, _body}, _tolerated), do: :ok
  defp ok({:error, %{status: 404}}, :not_found), do: :ok
  defp ok({:error, error}, _tolerated), do: {:error, error}
end

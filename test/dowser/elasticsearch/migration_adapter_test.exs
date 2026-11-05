defmodule Dowser.Elasticsearch.Migration.AdapterTest do
  use ExUnit.Case, async: true

  alias Dowser.Client.HTTP.Stub
  alias Dowser.Elasticsearch.Migration.Adapter

  @repo [endpoint: "http://es:9200"]

  # Answers with `fun.(method, path_and_query, body)` — `{status, body}` — and
  # records each request.
  defp stub(fun) do
    Stub.stub(fn method, url, _headers, body, _opts ->
      %URI{path: path, query: query} = URI.parse(url)
      target = if query, do: path <> "?" <> query, else: path

      body =
        if body in [nil, "", []], do: nil, else: body |> IO.iodata_to_binary() |> JSON.decode!()

      send(self(), {:request, method, target, body})

      case fun.(method, target, body) do
        {status, nil} ->
          Stub.json(status, %{})

        {status, response} ->
          Stub.json(status, response)
      end
    end)
  end

  defp not_found,
    do: {404, %{"error" => %{"type" => "index_not_found_exception", "reason" => "no such index"}}}

  test "the Elasticsearch repo names it" do
    defmodule Search do
      use Dowser.Elasticsearch.Repo, otp_app: :dowser_elasticsearch
    end

    assert Search.__migration_adapter__() == Adapter
  end

  describe "tracking" do
    test "creates the tracking index when missing" do
      stub(fn
        :head, "/dowser_schema_migrations", _body ->
          {404, nil}

        :put, "/dowser_schema_migrations", _body ->
          {200, %{"acknowledged" => true}}
      end)

      assert Adapter.ensure_tracking(@repo) == :ok

      assert_received {:request, :put, "/dowser_schema_migrations",
                       %{"mappings" => %{"dynamic" => false}}}
    end

    test "leaves an existing tracking index alone" do
      stub(fn :head, "/dowser_schema_migrations", _body -> {200, nil} end)

      assert Adapter.ensure_tracking(@repo) == :ok
      refute_received {:request, :put, _path, _body}
    end

    test "lists the records, none before the first run" do
      stub(fn :post, "/dowser_schema_migrations/_search", _body -> not_found() end)
      assert Adapter.applied(@repo) == {:ok, []}

      stub(fn :post,
              "/dowser_schema_migrations/_search",
              %{"query" => %{"term" => %{"type" => "migration"}}} ->
        {200,
         %{
           "hits" => %{
             "hits" => [%{"_source" => %{"type" => "migration", "version" => 1, "name" => "a"}}]
           }
         }}
      end)

      assert Adapter.applied(@repo) == {:ok, [%{"version" => 1, "name" => "a"}]}
    end

    test "records and unrecords, refreshing" do
      stub(fn
        :put, "/dowser_schema_migrations/_doc/1?refresh=true", _body ->
          {201, %{}}

        :delete, "/dowser_schema_migrations/_doc/1?refresh=true", _body ->
          {404, %{}}
      end)

      assert Adapter.record(@repo, %{"version" => 1, "name" => "a"}) == :ok

      assert_received {:request, :put, _path,
                       %{"type" => "migration", "version" => 1, "name" => "a"}}

      assert Adapter.unrecord(@repo, 1) == :ok
    end
  end

  describe "the lock" do
    test "is created once" do
      stub(fn
        :put, "/dowser_schema_migrations/_create/lock?refresh=true", _body ->
          {409,
           %{"error" => %{"type" => "version_conflict_engine_exception", "reason" => "exists"}}}

        :get, "/dowser_schema_migrations/_doc/lock", _body ->
          {200, %{"_source" => %{"type" => "lock", "owner" => "other", "state" => nil}}}
      end)

      assert Adapter.lock(@repo, %{"owner" => "me"}) ==
               {:error, {:locked, %{"owner" => "other", "state" => nil}}}
    end

    test "is updated by merging into the one in place" do
      stub(fn
        :get, "/dowser_schema_migrations/_doc/lock", _body ->
          {200, %{"_source" => %{"type" => "lock", "owner" => "me", "acquired_at" => "t"}}}

        :put, "/dowser_schema_migrations/_doc/lock?refresh=true", _body ->
          {200, %{}}
      end)

      assert Adapter.update_lock(@repo, %{"state" => %{"phase" => "copy"}}) == :ok

      assert_received {:request, :put, _path,
                       %{
                         "type" => "lock",
                         "owner" => "me",
                         "acquired_at" => "t",
                         "state" => %{"phase" => "copy"}
                       }}
    end

    test "reads none when there is none" do
      stub(fn :get, "/dowser_schema_migrations/_doc/lock", _body ->
        {404, %{"found" => false}}
      end)

      assert Adapter.get_lock(@repo) == {:ok, nil}
    end
  end

  describe "indices" do
    test "reads them flat, aliases as names" do
      stub(fn :get,
              "/events,events_*?flat_settings=true&ignore_unavailable=true&allow_no_indices=true",
              _body ->
        {200,
         %{
           "events_1" => %{
             "aliases" => %{"events" => %{}},
             "mappings" => %{"_meta" => %{"dowser_version" => 1}},
             "settings" => %{"index.number_of_replicas" => "1"}
           }
         }}
      end)

      assert Adapter.get_indices(@repo, ["events", "events_*"]) ==
               {:ok,
                %{
                  "events_1" => %{
                    "aliases" => ["events"],
                    "mappings" => %{"_meta" => %{"dowser_version" => 1}},
                    "settings" => %{"number_of_replicas" => "1"}
                  }
                }}
    end

    test "sends the index requests" do
      stub(fn _method, _path, _body -> {200, %{"acknowledged" => true}} end)

      assert Adapter.create_index(@repo, "events_2", %{"mappings" => %{}}) == :ok
      assert_received {:request, :put, "/events_2", %{"mappings" => %{}}}

      assert Adapter.put_mapping(@repo, "events_2", %{"_meta" => %{}}) == :ok
      assert_received {:request, :put, "/events_2/_mapping", %{"_meta" => %{}}}

      assert Adapter.add_write_block(@repo, "events_1") == :ok
      assert_received {:request, :put, "/events_1/_block/write", nil}

      assert Adapter.remove_write_block(@repo, "events_1") == :ok
      assert_received {:request, :put, "/events_1/_settings", %{"index.blocks.write" => nil}}

      assert Adapter.swap_alias(@repo, "events", "events_1", "events_2") == :ok

      assert_received {:request, :post, "/_aliases",
                       %{
                         "actions" => [
                           %{"remove" => %{"index" => "events_1", "alias" => "events"}},
                           %{"add" => %{"index" => "events_2", "alias" => "events"}}
                         ]
                       }}

      assert Adapter.delete_index(@repo, "events_1") == :ok
      assert_received {:request, :delete, "/events_1", nil}
    end

    test "reports a failed request" do
      stub(fn :delete, "/events_1", _body -> not_found() end)

      assert {:error, %Dowser.Elasticsearch.Error{status: 404, type: "index_not_found_exception"}} =
               Adapter.delete_index(@repo, "events_1")
    end
  end

  describe "copies" do
    test "start in the background and are followed through the tasks API" do
      stub(fn
        :post, "/_reindex?wait_for_completion=false", _body ->
          {200, %{"task" => "node:1"}}

        :get, "/_tasks/node:1", _body ->
          {200, %{"completed" => true, "response" => %{"failures" => []}}}
      end)

      script = %{"lang" => "painless", "source" => "x", "params" => %{}}

      assert Adapter.reindex(@repo, "events_1", "events_2", script) == {:ok, "node:1"}

      assert_received {:request, :post, _path,
                       %{
                         "source" => %{"index" => "events_1"},
                         "dest" => %{"index" => "events_2"},
                         "script" => ^script
                       }}

      assert Adapter.get_task(@repo, "node:1") ==
               {:ok, %{"completed" => true, "response" => %{"failures" => []}}}
    end
  end
end

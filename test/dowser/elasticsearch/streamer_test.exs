defmodule Dowser.Elasticsearch.StreamerTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.HTTP.Stub
  alias Dowser.Elasticsearch.HTTPStub
  alias Dowser.Elasticsearch.Streamer

  @context [endpoint: "http://x:9200"]

  setup do
    {:ok, requests: start_supervised!({Agent, fn -> [] end})}
  end

  defp record(requests, url, body) do
    Agent.update(requests, &[%{url: url, body: JSON.decode!(IO.iodata_to_binary(body))} | &1])
  end

  defp searches(requests) do
    requests |> Agent.get(& &1) |> Enum.reverse() |> Enum.filter(&(&1.url =~ "/_search"))
  end

  defp hit(id, sort \\ nil) do
    %{
      "_index" => "posts",
      "_id" => to_string(id),
      "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"},
      "sort" => sort || [id]
    }
  end

  # Serves `pages` in order to each slice, keyed by the slice's id (`nil` when
  # the search carries no slice), and answers the PIT endpoints.
  defp stub_pages(requests, pages, opts \\ []) do
    pit_id = Keyword.get(opts, :pit_id, "pit-1")
    counters = start_supervised!({Agent, fn -> %{} end}, id: :counters)

    Stub.stub(fn
      :post, "http://x:9200/posts/_pit" <> _ = url, _h, body, _o ->
        record(requests, url, body || "null")
        Stub.json(200, %{"id" => pit_id})

      :delete, "http://x:9200/_pit" = url, _h, body, _o ->
        record(requests, url, body)
        Stub.json(200, %{"succeeded" => true, "num_freed" => 1})

      :post, "http://x:9200/_search" = url, _h, body, _o ->
        decoded = JSON.decode!(IO.iodata_to_binary(body))
        record(requests, url, body)
        slice = get_in(decoded, ["slice", "id"])

        page =
          Agent.get_and_update(counters, fn state ->
            n = Map.get(state, slice, 0)
            {pages |> Map.fetch!(slice) |> Enum.at(n, []), Map.put(state, slice, n + 1)}
          end)

        Stub.json(200, %{"pit_id" => pit_id, "hits" => %{"hits" => page}})
    end)
  end

  describe "stream/2 — walking one cursor" do
    test "pages with search_after until a short page ends it", %{requests: requests} do
      stub_pages(requests, %{nil => [[hit(1), hit(2)], [hit(3)]]})

      hits =
        %{query: %{match_all: %{}}, size: 2}
        |> Streamer.stream(index: "posts", context: @context)
        |> Enum.to_list()

      assert Enum.map(hits, & &1["_id"]) == ["1", "2", "3"]

      [first, second] = searches(requests)
      refute Map.has_key?(first.body, "search_after")
      assert second.body["search_after"] == [2]
      assert second.body["pit"] == %{"id" => "pit-1", "keep_alive" => "1m"}
    end

    test "appends _shard_doc to the caller's sort, keeping theirs first", %{requests: requests} do
      stub_pages(requests, %{nil => [[]]})

      %{query: %{}, sort: [%{"title" => "desc"}]}
      |> Streamer.stream(index: "posts", context: @context)
      |> Enum.to_list()

      assert [%{body: body}] = searches(requests)
      assert body["sort"] == [%{"title" => "desc"}, %{"_shard_doc" => "asc"}]
      assert body["track_total_hits"] == false
    end

    test "wraps a sort given as an object rather than appending to it", %{requests: requests} do
      stub_pages(requests, %{nil => [[]]})

      %{query: %{}, sort: %{"title" => "desc"}}
      |> Streamer.stream(index: "posts", context: @context)
      |> Enum.to_list()

      assert [%{body: body}] = searches(requests)
      assert body["sort"] == [%{"title" => "desc"}, %{"_shard_doc" => "asc"}]
    end

    test "a string-keyed query gets one sort, not two", %{requests: requests} do
      stub_pages(requests, %{nil => [[]]})

      %{"query" => %{}, "sort" => [%{"title" => "desc"}], "size" => 5}
      |> Streamer.stream(index: "posts", context: @context)
      |> Enum.to_list()

      assert [%{body: body}] = searches(requests)
      assert body["sort"] == [%{"title" => "desc"}, %{"_shard_doc" => "asc"}]
      assert body["size"] == 5
    end

    test "does not add _shard_doc twice", %{requests: requests} do
      stub_pages(requests, %{nil => [[]]})

      %{query: %{}, sort: [%{_shard_doc: "asc"}]}
      |> Streamer.stream(index: "posts", context: @context)
      |> Enum.to_list()

      assert [%{body: body}] = searches(requests)
      assert body["sort"] == [%{"_shard_doc" => "asc"}]
    end

    test "follows the pit_id Elasticsearch returns rather than the one it opened" do
      requests = start_supervised!({Agent, fn -> [] end}, id: :pit_requests)
      counter = start_supervised!({Agent, fn -> 0 end}, id: :pit_counter)

      Stub.stub(fn
        :post, "http://x:9200/posts/_pit" <> _, _h, _b, _o ->
          Stub.json(200, %{"id" => "pit-opened"})

        :delete, "http://x:9200/_pit", _h, body, _o ->
          record(requests, "delete", body)
          Stub.json(200, %{"succeeded" => true, "num_freed" => 1})

        :post, "http://x:9200/_search", _h, body, _o ->
          record(requests, "/_search", body)
          n = Agent.get_and_update(counter, &{&1, &1 + 1})
          hits = if n == 0, do: [hit(1)], else: []

          Stub.json(200, %{"pit_id" => "pit-rotated", "hits" => %{"hits" => hits}})
      end)

      %{query: %{}, size: 1}
      |> Streamer.stream(index: "posts", context: @context)
      |> Enum.to_list()

      [first, second] = searches(requests)
      assert first.body["pit"]["id"] == "pit-opened"
      assert second.body["pit"]["id"] == "pit-rotated"

      # and the rotated id is the one closed
      assert [%{body: %{"id" => "pit-rotated"}}] =
               requests |> Agent.get(& &1) |> Enum.filter(&(&1.url == "delete"))
    end
  end

  describe "stream/2 — the point in time" do
    test "opens one with :keep_alive and closes it when the stream ends", %{requests: requests} do
      stub_pages(requests, %{nil => [[]]})

      %{query: %{}}
      |> Streamer.stream(index: "posts", keep_alive: "30s", context: @context)
      |> Enum.to_list()

      urls = requests |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(& &1.url)
      assert ["http://x:9200/posts/_pit?keep_alive=30s", "http://x:9200/_search" | _] = urls
      assert List.last(urls) == "http://x:9200/_pit"
    end

    test "closes it on an early halt too", %{requests: requests} do
      stub_pages(requests, %{nil => [[hit(1), hit(2)], [hit(3), hit(4)]]})

      assert %{query: %{}, size: 2}
             |> Streamer.stream(index: "posts", context: @context)
             |> Enum.take(1)
             |> length() == 1

      assert requests |> Agent.get(& &1) |> Enum.any?(&(&1.url == "http://x:9200/_pit"))
    end

    test "a caller's pit is checked once and left open", %{requests: requests} do
      stub_pages(requests, %{nil => [[]]})

      %{query: %{}}
      |> Streamer.stream(pit: "pit-given", context: @context)
      |> Enum.to_list()

      all = requests |> Agent.get(& &1) |> Enum.reverse()
      refute Enum.any?(all, &(&1.url =~ "_pit" and &1.url != "http://x:9200/_search"))

      # the liveness check, then the walk itself
      assert [%{body: %{"query" => %{"match_none" => %{}}}}, _walk] = searches(requests)
    end

    test "an expired pit fails before the walk starts, with Elasticsearch's error" do
      Stub.stub(fn :post, "http://x:9200/_search", _h, _b, _o ->
        Stub.json(404, %{"error" => %{"type" => "search_phase_execution_exception"}})
      end)

      assert_raise Dowser.Elasticsearch.Error, ~r/search_phase_execution_exception/, fn ->
        %{query: %{}} |> Streamer.stream(pit: "dead", context: @context) |> Enum.to_list()
      end
    end
  end

  describe "stream/2 — :slice" do
    test "a slice in the query body is forwarded untouched", %{requests: requests} do
      stub_pages(requests, %{2 => [[]]})

      %{query: %{}, slice: %{"id" => 2, "max" => 8}}
      |> Streamer.stream(index: "posts", context: @context)
      |> Enum.to_list()

      assert [%{body: body}] = searches(requests)
      assert body["slice"] == %{"id" => 2, "max" => 8}
    end

    test "no slice means no slice in the body", %{requests: requests} do
      stub_pages(requests, %{nil => [[]]})

      %{query: %{}} |> Streamer.stream(index: "posts", context: @context) |> Enum.to_list()

      assert [%{body: body}] = searches(requests)
      refute Map.has_key?(body, "slice")
    end

    test "a :slice option says where slice belongs rather than being ignored" do
      assert_raise ArgumentError, ~r/belongs in the query body/, fn ->
        Streamer.stream(%{query: %{}}, index: "posts", slice: %{"id" => 0, "max" => 2})
      end
    end

    test ":verify_pit false skips the liveness check", %{requests: requests} do
      stub_pages(requests, %{nil => [[]]})

      %{query: %{}}
      |> Streamer.stream(pit: "pit-given", verify_pit: false, context: @context)
      |> Enum.to_list()

      assert [%{body: body}] = searches(requests)
      refute match?(%{"query" => %{"match_none" => _}}, body)
    end
  end

  # `Dowser.Client.HTTP.Stub` lives in the process dictionary of the process
  # that makes the request, and stream_with_slice/4 makes its requests from
  # tasks — so these go through a real socket instead. Worth knowing: the same
  # is true of any application testing a sliced walk.
  describe "stream_with_slice/4" do
    defp pool(requests, pages) do
      counters = start_supervised!({Agent, fn -> %{} end}, id: :pool_counters)

      port =
        HTTPStub.start_pool(fn request ->
          body = if request.body == "", do: %{}, else: JSON.decode!(request.body)
          Agent.update(requests, &[%{url: request.path, body: body} | &1])

          cond do
            String.contains?(request.path, "/_pit") and request.method == "POST" ->
              HTTPStub.json_response(%{"id" => "pit-1"})

            String.contains?(request.path, "/_pit") ->
              HTTPStub.json_response(%{"succeeded" => true, "num_freed" => 1})

            true ->
              slice = get_in(body, ["slice", "id"])

              page =
                Agent.get_and_update(counters, fn state ->
                  n = Map.get(state, slice, 0)
                  {pages |> Map.fetch!(slice) |> Enum.at(n, []), Map.put(state, slice, n + 1)}
                end)

              HTTPStub.json_response(%{"pit_id" => "pit-1", "hits" => %{"hits" => page}})
          end
        end)

      [endpoint: "http://127.0.0.1:#{port}"]
    end

    test "runs stream_fn over every slice and yields its results", %{requests: requests} do
      context = pool(requests, %{0 => [[hit(1)]], 1 => [[hit(2)]], 2 => [[hit(3)]]})

      results =
        %{query: %{}, size: 5}
        |> Streamer.stream_with_slice(3, &Enum.count/1, index: "posts", context: context)
        |> Enum.to_list()

      assert Enum.sum(results) == 3

      slices = searches(requests) |> Enum.map(& &1.body["slice"]) |> Enum.sort_by(& &1["id"])

      assert slices == [
               %{"id" => 0, "max" => 3},
               %{"id" => 1, "max" => 3},
               %{"id" => 2, "max" => 3}
             ]
    end

    test "runs stream_fn inside the task that owns the slice", %{requests: requests} do
      context = pool(requests, %{0 => [[hit(1)]], 1 => [[hit(2)]]})
      caller = self()

      pids =
        %{query: %{}, size: 5}
        |> Streamer.stream_with_slice(
          2,
          fn slice ->
            Enum.to_list(slice)
            self()
          end,
          index: "posts",
          context: context
        )
        |> Enum.to_list()

      assert length(pids) == 2
      refute caller in pids
      assert pids |> Enum.uniq() |> length() == 2
    end

    test "a slice in the query body is the base each slice is built on", %{requests: requests} do
      context = pool(requests, %{0 => [[]], 1 => [[]]})

      %{query: %{}, slice: %{"field" => "_id"}}
      |> Streamer.stream_with_slice(2, &Stream.run/1, index: "posts", context: context)
      |> Stream.run()

      assert searches(requests) |> Enum.map(& &1.body["slice"]) |> Enum.sort_by(& &1["id"]) == [
               %{"id" => 0, "max" => 2, "field" => "_id"},
               %{"id" => 1, "max" => 2, "field" => "_id"}
             ]
    end

    test "each slice pages independently", %{requests: requests} do
      context = pool(requests, %{0 => [[hit(1)], [hit(2)], []], 1 => [[hit(9)], []]})

      ids =
        %{query: %{}, size: 1}
        |> Streamer.stream_with_slice(2, &Enum.map(&1, fn hit -> hit["_id"] end),
          index: "posts",
          context: context
        )
        |> Enum.concat()
        |> Enum.sort()

      assert ids == ["1", "2", "9"]

      by_slice = Enum.group_by(searches(requests), & &1.body["slice"]["id"])
      assert by_slice |> Map.fetch!(0) |> Enum.map(& &1.body["search_after"]) == [nil, [1], [2]]
      assert by_slice |> Map.fetch!(1) |> Enum.map(& &1.body["search_after"]) == [nil, [9]]
    end

    test "opens one point in time for all the slices, and closes it once", %{requests: requests} do
      context = pool(requests, %{0 => [[]], 1 => [[]], 2 => [[]], 3 => [[]]})

      %{query: %{}}
      |> Streamer.stream_with_slice(4, &Stream.run/1, index: "posts", context: context)
      |> Stream.run()

      all = requests |> Agent.get(& &1) |> Enum.reverse()
      assert all |> Enum.filter(&(&1.url =~ "/posts/_pit")) |> length() == 1
      assert all |> Enum.filter(&(&1.url == "/_pit")) |> length() == 1

      # opened first, closed last, four searches in between
      assert List.first(all).url =~ "/posts/_pit"
      assert List.last(all).url == "/_pit"
      assert length(searches(requests)) == 4
    end

    test "no slice is charged for a liveness check", %{requests: requests} do
      context = pool(requests, %{0 => [[]], 1 => [[]]})

      %{query: %{}}
      |> Streamer.stream_with_slice(2, &Stream.run/1, index: "posts", context: context)
      |> Stream.run()

      refute Enum.any?(searches(requests), &match?(%{"query" => %{"match_none" => _}}, &1.body))
    end

    test "closes the point in time when a slice raises", %{requests: requests} do
      context = pool(requests, %{0 => [[hit(1)]], 1 => [[hit(2)]]})

      assert_raise RuntimeError, ~r/boom/, fn ->
        %{query: %{}}
        |> Streamer.stream_with_slice(2, fn _slice -> raise "boom" end,
          index: "posts",
          context: context
        )
        |> Stream.run()
      end

      assert requests |> Agent.get(& &1) |> Enum.any?(&(&1.url == "/_pit"))
    end

    test "nothing is requested until the result is enumerated", %{requests: requests} do
      context = pool(requests, %{0 => [[]]})

      Streamer.stream_with_slice(%{query: %{}}, 1, &Stream.run/1,
        index: "posts",
        context: context
      )

      assert Agent.get(requests, & &1) == []
    end
  end

  describe "stream/2 — casting" do
    test "yields hits cast by the configured decoder, over raw bookkeeping", %{
      requests: requests
    } do
      HTTPStub.start_mapping_cacher!(%{
        "properties" => %{
          "published_at" => %{"type" => "date", "format" => "strict_date_optional_time"}
        }
      })

      stub_pages(requests, %{nil => [[hit(1)]]})

      context = @context ++ [decoder: Dowser.Elasticsearch.Codec]

      assert [decoded] =
               %{query: %{}, size: 10}
               |> Streamer.stream(index: "posts", context: context, keys: :atoms)
               |> Enum.to_list()

      # `keys: :atoms` and the mapping both applied to the hit …
      assert decoded[:_source][:published_at] == ~U[2026-08-11 00:00:00.000Z]

      # … while the streamer's own bookkeeping read the raw string keys.
      assert [%{body: body}] = searches(requests)
      assert body["pit"]["id"] == "pit-1"
    end

    test "without a decoder the hits come back untouched", %{requests: requests} do
      stub_pages(requests, %{nil => [[hit(1)]]})

      assert [decoded] =
               %{query: %{}, size: 10}
               |> Streamer.stream(index: "posts", context: @context)
               |> Enum.to_list()

      assert decoded["_source"]["published_at"] == "2026-08-11T00:00:00.000Z"
    end
  end

  describe "stream/2 — failure" do
    test "raises Elasticsearch's own error rather than wrapping it", %{requests: requests} do
      stub_pages(requests, %{nil => [[hit(1), hit(2)]]})

      Stub.stub(fn
        :post, "http://x:9200/posts/_pit" <> _, _h, _b, _o ->
          Stub.json(200, %{"id" => "pit-1"})

        :delete, "http://x:9200/_pit", _h, _b, _o ->
          Stub.json(200, %{"succeeded" => true, "num_freed" => 1})

        :post, "http://x:9200/_search", _h, _b, _o ->
          Stub.json(500, %{"error" => %{"type" => "circuit_breaking_exception"}})
      end)

      assert_raise Dowser.Elasticsearch.Error, ~r/circuit_breaking_exception/, fn ->
        %{query: %{}} |> Streamer.stream(index: "posts", context: @context) |> Enum.to_list()
      end
    end
  end
end

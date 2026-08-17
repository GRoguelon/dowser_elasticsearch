defmodule Dowser.Elasticsearch.MappingCacherTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.Config
  alias Dowser.Elasticsearch.MappingCacher

  @config Config.new(endpoint: "http://x:9200")

  describe "get/2" do
    test "fetches on a miss and caches the result" do
      counter = :counters.new(1, [])

      fetch = fn _config, "posts" ->
        :counters.add(counter, 1, 1)
        {:ok, %{"properties" => %{}}}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      assert {:ok, %{"properties" => %{}}} = MappingCacher.get(@config, "posts")
      assert {:ok, %{"properties" => %{}}} = MappingCacher.get(@config, "posts")
      assert :counters.get(counter, 1) == 1
    end

    test "caches different indices independently" do
      fetch = fn _config, index -> {:ok, %{"index" => index}} end
      start_supervised!({MappingCacher, fetch: fetch})

      assert {:ok, %{"index" => "posts"}} = MappingCacher.get(@config, "posts")
      assert {:ok, %{"index" => "comments"}} = MappingCacher.get(@config, "comments")
    end

    test "propagates a fetch error without caching it" do
      counter = :counters.new(1, [])

      fetch = fn _config, _index ->
        :counters.add(counter, 1, 1)
        {:error, :not_found}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      assert {:error, :not_found} = MappingCacher.get(@config, "posts")
      assert {:error, :not_found} = MappingCacher.get(@config, "posts")
      assert :counters.get(counter, 1) == 2
    end

    test "a raised exception in fetch is returned as an error, not crashed on" do
      fetch = fn _config, _index -> raise "boom" end
      start_supervised!({MappingCacher, fetch: fetch})

      assert {:error, %RuntimeError{message: "boom"}} = MappingCacher.get(@config, "posts")
    end

    test "re-fetches after the entry's ttl expires" do
      counter = :counters.new(1, [])

      fetch = fn _config, _index ->
        :counters.add(counter, 1, 1)
        {:ok, :counters.get(counter, 1)}
      end

      start_supervised!({MappingCacher, fetch: fetch, ttl: 1})

      assert {:ok, 1} = MappingCacher.get(@config, "posts")
      Process.sleep(20)
      assert {:ok, 2} = MappingCacher.get(@config, "posts")
    end

    test "concurrent callers for the same miss trigger a single fetch" do
      counter = :counters.new(1, [])

      fetch = fn _config, _index ->
        :counters.add(counter, 1, 1)
        Process.sleep(50)
        {:ok, :done}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      tasks = for _ <- 1..5, do: Task.async(fn -> MappingCacher.get(@config, "posts") end)
      assert Enum.map(tasks, &Task.await/1) == List.duplicate({:ok, :done}, 5)
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "invalidate/2" do
    test "removes a single cached entry, forcing a re-fetch" do
      counter = :counters.new(1, [])

      fetch = fn _config, _index ->
        :counters.add(counter, 1, 1)
        {:ok, :counters.get(counter, 1)}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      assert {:ok, 1} = MappingCacher.get(@config, "posts")
      assert :ok = MappingCacher.invalidate(@config, "posts")
      assert {:ok, 2} = MappingCacher.get(@config, "posts")
    end
  end

  describe "clear/0" do
    test "removes every cached entry" do
      counter = :counters.new(1, [])

      fetch = fn _config, _index ->
        :counters.add(counter, 1, 1)
        {:ok, :counters.get(counter, 1)}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      assert {:ok, 1} = MappingCacher.get(@config, "posts")
      assert {:ok, 2} = MappingCacher.get(@config, "comments")
      assert :ok = MappingCacher.clear()
      assert {:ok, 3} = MappingCacher.get(@config, "posts")
      assert {:ok, 4} = MappingCacher.get(@config, "comments")
    end
  end

  describe ":eager preload" do
    test "warms the given {config, index} pairs at startup" do
      counter = :counters.new(1, [])

      fetch = fn _config, index ->
        :counters.add(counter, 1, 1)
        {:ok, "mapping for #{index}"}
      end

      start_supervised!(
        {MappingCacher, fetch: fetch, eager: [{@config, "posts"}, {@config, "comments"}]}
      )

      # `handle_continue/2` (the warm pass) always runs before the GenServer
      # handles any other message, so by the time these calls return, both
      # eager fetches are guaranteed to have already happened — the counter
      # only reflects the two warm-pass fetches, not these calls.
      assert {:ok, "mapping for posts"} = MappingCacher.get(@config, "posts")
      assert {:ok, "mapping for comments"} = MappingCacher.get(@config, "comments")
      assert :counters.get(counter, 1) == 2
    end
  end
end

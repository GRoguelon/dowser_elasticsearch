defmodule Dowser.Elasticsearch.MappingCacherTest do
  use ExUnit.Case, async: false

  alias Dowser.Client.Context
  alias Dowser.Elasticsearch.MappingCacher

  @context Context.new(endpoint: "http://x:9200")

  describe "get/2" do
    test "fetches on a miss and caches the result" do
      counter = :counters.new(1, [])

      fetch = fn _context, "posts" ->
        :counters.add(counter, 1, 1)
        {:ok, %{"properties" => %{}}}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      assert {:ok, %{"properties" => %{}}} = MappingCacher.get(@context, "posts")
      assert {:ok, %{"properties" => %{}}} = MappingCacher.get(@context, "posts")
      assert :counters.get(counter, 1) == 1
    end

    test "caches different indices independently" do
      fetch = fn _context, index -> {:ok, %{"index" => index}} end
      start_supervised!({MappingCacher, fetch: fetch})

      assert {:ok, %{"index" => "posts"}} = MappingCacher.get(@context, "posts")
      assert {:ok, %{"index" => "comments"}} = MappingCacher.get(@context, "comments")
    end

    test "propagates a fetch error without caching it" do
      counter = :counters.new(1, [])

      fetch = fn _context, _index ->
        :counters.add(counter, 1, 1)
        {:error, :not_found}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      assert {:error, :not_found} = MappingCacher.get(@context, "posts")
      assert {:error, :not_found} = MappingCacher.get(@context, "posts")
      assert :counters.get(counter, 1) == 2
    end

    test "a raised exception in fetch is returned as an error, not crashed on" do
      fetch = fn _context, _index -> raise "boom" end
      start_supervised!({MappingCacher, fetch: fetch})

      assert {:error, %RuntimeError{message: "boom"}} = MappingCacher.get(@context, "posts")
    end

    test "re-fetches after the entry's ttl expires" do
      counter = :counters.new(1, [])

      fetch = fn _context, _index ->
        :counters.add(counter, 1, 1)
        {:ok, :counters.get(counter, 1)}
      end

      start_supervised!({MappingCacher, fetch: fetch, ttl: 1})

      assert {:ok, 1} = MappingCacher.get(@context, "posts")
      Process.sleep(20)
      assert {:ok, 2} = MappingCacher.get(@context, "posts")
    end

    test "concurrent callers for the same miss trigger a single fetch" do
      counter = :counters.new(1, [])

      fetch = fn _context, _index ->
        :counters.add(counter, 1, 1)
        Process.sleep(50)
        {:ok, :done}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      tasks = for _ <- 1..5, do: Task.async(fn -> MappingCacher.get(@context, "posts") end)
      assert Enum.map(tasks, &Task.await/1) == List.duplicate({:ok, :done}, 5)
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "keying" do
    test "two contexts on the same endpoint with different credentials don't share an entry" do
      fetch = fn context, "posts" ->
        {:basic, user, _password} = context.auth

        {:ok, "mapping for #{user}"}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      alice = Context.new(endpoint: "http://x:9200", auth: {:basic, "alice", "s3cret"})
      bob = Context.new(endpoint: "http://x:9200", auth: {:basic, "bob", "hunter2"})

      assert {:ok, "mapping for alice"} = MappingCacher.get(alice, "posts")
      assert {:ok, "mapping for bob"} = MappingCacher.get(bob, "posts")
      assert {:ok, "mapping for alice"} = MappingCacher.get(alice, "posts")
    end

    test "the same credentials do share an entry" do
      counter = :counters.new(1, [])

      fetch = fn _context, _index ->
        :counters.add(counter, 1, 1)
        {:ok, :mapping}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      auth = {:basic, "alice", "s3cret"}
      one = Context.new(endpoint: "http://x:9200", auth: auth)
      two = Context.new(endpoint: "http://x:9200", auth: auth, keys: :atoms)

      assert {:ok, :mapping} = MappingCacher.get(one, "posts")
      assert {:ok, :mapping} = MappingCacher.get(two, "posts")

      # `:keys` is client-side casting; it can't change what the cluster returns.
      assert :counters.get(counter, 1) == 1
    end

    test "credentials are hashed into the key, never stored in the table" do
      start_supervised!({MappingCacher, fetch: fn _context, _index -> {:ok, :mapping} end})

      context = Context.new(endpoint: "http://x:9200", auth: {:basic, "alice", "s3cret"})
      assert {:ok, :mapping} = MappingCacher.get(context, "posts")

      assert {"http://x:9200", scope, "posts"} = MappingCacher.key(context, "posts")
      assert is_binary(scope) and byte_size(scope) == 16

      refute MappingCacher |> :ets.tab2list() |> inspect() |> String.contains?("s3cret")
    end

    test "an unauthenticated context keeps a readable key" do
      assert MappingCacher.key(@context, "posts") == {"http://x:9200", nil, "posts"}
    end

    test "invalidate/2 only clears the calling context's entry" do
      fetch = fn context, _index -> {:ok, context.auth} end
      start_supervised!({MappingCacher, fetch: fetch})

      alice = Context.new(endpoint: "http://x:9200", auth: {:basic, "alice", "s3cret"})
      bob = Context.new(endpoint: "http://x:9200", auth: {:basic, "bob", "hunter2"})

      assert {:ok, _} = MappingCacher.get(alice, "posts")
      assert {:ok, _} = MappingCacher.get(bob, "posts")
      assert :ok = MappingCacher.invalidate(alice, "posts")

      assert [{{_endpoint, _scope, "posts"}, {:basic, "bob", _}, _expires}] =
               :ets.tab2list(MappingCacher)
    end
  end

  describe "invalidate/2" do
    test "removes a single cached entry, forcing a re-fetch" do
      counter = :counters.new(1, [])

      fetch = fn _context, _index ->
        :counters.add(counter, 1, 1)
        {:ok, :counters.get(counter, 1)}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      assert {:ok, 1} = MappingCacher.get(@context, "posts")
      assert :ok = MappingCacher.invalidate(@context, "posts")
      assert {:ok, 2} = MappingCacher.get(@context, "posts")
    end
  end

  describe "clear/0" do
    test "removes every cached entry" do
      counter = :counters.new(1, [])

      fetch = fn _context, _index ->
        :counters.add(counter, 1, 1)
        {:ok, :counters.get(counter, 1)}
      end

      start_supervised!({MappingCacher, fetch: fetch})

      assert {:ok, 1} = MappingCacher.get(@context, "posts")
      assert {:ok, 2} = MappingCacher.get(@context, "comments")
      assert :ok = MappingCacher.clear()
      assert {:ok, 3} = MappingCacher.get(@context, "posts")
      assert {:ok, 4} = MappingCacher.get(@context, "comments")
    end
  end

  describe ":eager preload" do
    test "warms the given {context, index} pairs at startup" do
      counter = :counters.new(1, [])

      fetch = fn _context, index ->
        :counters.add(counter, 1, 1)
        {:ok, "mapping for #{index}"}
      end

      start_supervised!(
        {MappingCacher, fetch: fetch, eager: [{@context, "posts"}, {@context, "comments"}]}
      )

      # `handle_continue/2` (the warm pass) always runs before the GenServer
      # handles any other message, so by the time these calls return, both
      # eager fetches are guaranteed to have already happened — the counter
      # only reflects the two warm-pass fetches, not these calls.
      assert {:ok, "mapping for posts"} = MappingCacher.get(@context, "posts")
      assert {:ok, "mapping for comments"} = MappingCacher.get(@context, "comments")
      assert :counters.get(counter, 1) == 2
    end
  end
end

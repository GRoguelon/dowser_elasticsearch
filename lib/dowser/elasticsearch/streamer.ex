defmodule Dowser.Elasticsearch.Streamer do
  @moduledoc """
  Turns a search into an Elixir `Stream`, for walking more documents than fit
  in one response.

      %{query: %{match_all: %{}}, size: 1_000}
      |> Dowser.Elasticsearch.Streamer.stream(index: "posts")
      |> Stream.map(& &1["_source"])
      |> Enum.each(&process/1)

  Each element is a hit — `_index`, `_id`, `_source` and the rest — cast
  exactly as `Dowser.Elasticsearch.Search.search/2` would cast it.

  ## How it walks

  A [point in time](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-open-point-in-time)
  pins the index against concurrent writes, and `search_after` pages through
  it. `_shard_doc` is appended to the sort as a tiebreaker, which is what makes
  the paging deterministic; a sort of your own is kept and sorted on first.

  `search_after` is sequential by construction — a page's cursor is the last
  hit of the page before it — so one stream cannot fetch pages in parallel.
  `stream_with_slice/4` is how you get parallelism; see below.

  ## Options

    * `:index` — the index to open the point in time on. Required unless
      `:pit` is given. It is *not* sent with the searches themselves:
      Elasticsearch rejects a search that names both an index and a PIT.
    * `:pit` — an existing point-in-time id to walk instead of opening one.
      It is checked once before the walk starts, and left open afterwards —
      whoever opened it closes it. Without it, the stream opens its own and
      closes it when enumeration ends, however it ends.
    * `:keep_alive` — how long Elasticsearch holds the point in time, extended
      on every search. Defaults to `"1m"`. Long enough to cover the gap
      between two pages, not the whole walk.
    * `:verify_pit` — whether a `:pit` you passed is checked before the walk
      starts. `true` by default; `false` when you just opened it and know it
      is alive.

  Everything else is forwarded to `Dowser.Elasticsearch.Search`, so `:context`,
  `:codec`, `:keys` and `:http_opts` all work as usual.

  A query with no `size` gets 1000, not Elasticsearch's default of 10 —
  at 10 hits per round trip a million documents is a hundred thousand
  requests. Set your own when you have a reason to.

  ## Slicing

  `stream_with_slice/4` splits the point in time into disjoint subsets and
  walks them at once. Elasticsearch divides first across shards, then within
  each shard by contiguous ranges of Lucene document ids, so the natural
  ceiling is your shard count — more slices than shards subdivides a shard
  rather than adding parallelism.

      %{query: %{match_all: %{}}, size: 1_000}
      |> Dowser.Elasticsearch.Streamer.stream_with_slice(&Enum.count/1, 4, index: "posts")
      |> Enum.sum()

  Note what it takes: a function, not a stream. Each slice is consumed inside
  its own task, because a lazy stream handed back out of a task would run
  every page in the caller — concurrent in name only.

  To spread a walk across *nodes* instead, open the point in time yourself and
  give each node one slice. `slice` is an ordinary search body field, so it
  goes in the query rather than the options:

      stream(%{query: ..., slice: %{id: 2, max: 8}}, pit: pit_id)

  ## Failure

  There is no `stream!/2`. Every other function in this package comes in a pair
  because it returns `{:ok, result}` or `{:error, error}` and the bang variant
  unwraps it; a stream has nothing to unwrap, and nothing has happened yet when
  it is built. Errors surface on enumeration, by raising — which is what the
  bang variant would have done anyway.

  The stream raises on the first failed request, and closes a point in time it
  opened on the way out — on normal completion, on `Enum.take/2`, and on an
  exception. It cannot close one if the enumerating process is killed outright;
  `:keep_alive` is the backstop there.
  """

  alias Dowser.Client.Decoder, as: ClientDecoder
  alias Dowser.Elasticsearch.Client
  alias Dowser.Elasticsearch.Search

  ## Module attributes

  @default_keep_alive "1m"
  @default_size 1_000
  @shard_doc %{"_shard_doc" => "asc"}

  ## Typespecs

  @type query :: map()

  ## Public functions

  @doc """
  Streams every hit a search matches.

  See the module documentation for the options. The stream is lazy: nothing is
  requested, and no point in time is opened, until it is enumerated.
  """
  @spec stream(query(), keyword()) :: Enumerable.t()
  def stream(%{} = query, opts \\ []) do
    {index, opts} = Keyword.pop(opts, :index)
    {pit_id, opts} = Keyword.pop(opts, :pit)
    {keep_alive, opts} = Keyword.pop(opts, :keep_alive, @default_keep_alive)
    {verify?, opts} = Keyword.pop(opts, :verify_pit, true)

    reject_slice_opt!(opts)
    shaper = shaper(opts)
    query = prepare_query(query)
    size = fetch_field(query, :size, @default_size)

    # Every request this module makes has to come back as plain string-keyed
    # JSON: it reads `hits.hits[]`, each hit's `sort` and the `pit_id` by those
    # names. The casting the caller configured is applied to the hits instead,
    # one at a time, by `shaper`.
    opts = Keyword.merge(opts, keys: :strings, decoder: &raw/2)

    Stream.resource(
      fn -> start(index, pit_id, verify?, keep_alive, size, opts) end,
      &next(&1, query, shaper, opts),
      &stop(&1, opts)
    )
  end

  @doc """
  Walks `slice_nbr` slices of one point in time at once, running `stream_fn`
  over each.

  `stream_fn` receives a slice's stream and is called **inside** the task that
  owns it, so the hits never cross a process boundary — which is the whole
  point: returning a lazy stream from a task would build it there and then run
  every page back in the caller.

      %{query: %{match_all: %{}}, size: 1_000}
      |> Dowser.Elasticsearch.Streamer.stream_with_slice(
        fn slice -> Enum.count(slice) end,
        4,
        index: "posts"
      )
      |> Enum.sum()

  The result is a stream of whatever `stream_fn` returned, one per slice, so
  keep those small — a count, a sum, `:ok`. A slice that returns everything it
  read defeats the streaming.

  A `slice` already in the query body is the base every slice is built on, so
  anything else the split needs travels with it; `id` and `max` are computed
  here and win:

      stream_with_slice(%{query: ..., slice: %{field: "_id"}}, &f/1, 7, index: "posts")
      # each walk carries %{"field" => "_id", "id" => 0..6, "max" => 7}

  All slices share one point in time, opened here and closed when the stream
  finishes, however it finishes. Pass `:pit` to use one of your own; it is
  checked once, and left open.

  ## Options

  Takes everything `stream/2` does, plus:

    * `:max_concurrency` — how many slices run at once. Defaults to
      `slice_nbr`, so every slice is in flight; lower it to bound the load a
      walk puts on the cluster.
    * `:timeout` — per slice, not per request. Defaults to `:infinity`, since
      a slice runs as long as it takes to walk; `Task.async_stream/3` would
      otherwise give up after five seconds.
    * `:ordered` — `false` by default, so a finished slice is not held back by
      a slower one.

  A slice that fails raises: an exception from its own walk, or a
  `RuntimeError` naming the slice if the task exited or timed out.
  """
  @spec stream_with_slice(query(), (Enumerable.t() -> term()), pos_integer(), keyword()) ::
          Enumerable.t()
  def stream_with_slice(%{} = query, stream_fn, slice_nbr, opts \\ [])
      when is_function(stream_fn, 1) and is_integer(slice_nbr) and slice_nbr > 0 do
    {index, opts} = Keyword.pop(opts, :index)
    {pit_id, opts} = Keyword.pop(opts, :pit)
    {keep_alive, opts} = Keyword.pop(opts, :keep_alive, @default_keep_alive)
    {task_opts, opts} = task_opts(opts, slice_nbr)

    # `Stream.transform/4` is what brackets the point in time around a lazy
    # stream: nothing opens until the result is enumerated, and `close` runs
    # whether the enumeration completes, halts early or raises.
    Stream.transform(
      [:slices],
      fn -> open(index, pit_id, true, keep_alive, opts) end,
      fn :slices, {pit_id, owned?} ->
        {walk(query, stream_fn, slice_nbr, pit_id, keep_alive, task_opts, opts), {pit_id, owned?}}
      end,
      fn
        {pit_id, true} -> close(pit_id, opts)
        {_pit_id, false} -> :ok
      end
    )
  end

  ## Private functions — slices

  defp walk(query, stream_fn, slice_nbr, pit_id, keep_alive, task_opts, opts) do
    base = fetch_field(query, :slice, %{})

    0..(slice_nbr - 1)
    |> Task.async_stream(
      fn id ->
        sliced = put_field(query, :slice, Map.merge(base, %{"id" => id, "max" => slice_nbr}))

        # The point in time was opened — or checked — above, so each slice is
        # spared a liveness check of its own.
        walk_opts =
          Keyword.merge(opts,
            pit: pit_id,
            verify_pit: false,
            keep_alive: keep_alive
          )

        # `Task.async_stream/3` links, so a slice that raised would take the
        # caller down with it — before `Stream.transform/4` could close the
        # point in time. Carrying the failure back as a value instead keeps the
        # cleanup, and re-raising below keeps the original exception and its
        # stacktrace.
        try do
          sliced |> stream(walk_opts) |> stream_fn.()
        rescue
          exception -> {:raised, exception, __STACKTRACE__}
        catch
          kind, reason -> {:caught, kind, reason, __STACKTRACE__}
        else
          result -> {:returned, result}
        end
      end,
      task_opts
    )
    |> Stream.map(fn
      {:ok, {:returned, result}} -> result
      {:ok, {:raised, exception, stacktrace}} -> reraise(exception, stacktrace)
      {:ok, {:caught, kind, reason, stacktrace}} -> :erlang.raise(kind, reason, stacktrace)
      {:exit, reason} -> raise "a slice of the stream exited: #{inspect(reason)}"
    end)
  end

  defp task_opts(opts, slice_nbr) do
    {max_concurrency, opts} = Keyword.pop(opts, :max_concurrency, slice_nbr)
    {timeout, opts} = Keyword.pop(opts, :timeout, :infinity)
    {ordered, opts} = Keyword.pop(opts, :ordered, false)

    {[max_concurrency: max_concurrency, timeout: timeout, ordered: ordered], opts}
  end

  ## Private functions — the resource

  defp start(index, pit_id, verify?, keep_alive, size, opts) do
    {pit_id, owned?} = open(index, pit_id, verify?, keep_alive, opts)

    %{pit: pit_id, keep_alive: keep_alive, owned?: owned?, size: size, cursor: :start}
  end

  defp next(%{cursor: :done} = state, _query, _shaper, _opts) do
    {:halt, state}
  end

  defp next(state, query, shaper, opts) do
    case query |> build(state) |> Search.search(opts) do
      {:ok, response} ->
        {hits, cursor, pit_id} = page(response, state.size)

        {Enum.map(hits, shaper), %{state | pit: pit_id || state.pit, cursor: cursor}}

      {:error, exception} ->
        raise exception
    end
  end

  defp stop(state, opts) do
    if state.owned?, do: close(state.pit, opts)

    :ok
  end

  defp page(response, size) do
    hits = get_in(response, ["hits", "hits"]) || []

    # A short page is the last one, so the walk stops without the extra request
    # it would take to see an empty one.
    cursor = if hits != [] and length(hits) >= size, do: last_sort(hits), else: :done

    # Elasticsearch may hand back a different id than the one it was given, and
    # says to use the most recent for the next request.
    {hits, cursor, response["pit_id"]}
  end

  defp build(query, state) do
    query
    |> put_field(:pit, %{"id" => state.pit, "keep_alive" => state.keep_alive})
    |> put_search_after(state.cursor)
  end

  defp last_sort(hits), do: hits |> List.last() |> Map.fetch!("sort")

  ## Private functions — the point in time

  defp open(index, nil, _verify?, keep_alive, opts) do
    case Search.open_point_in_time(%{}, index, keep_alive, opts) do
      {:ok, %{"id" => pit_id}} ->
        {pit_id, true}

      {:error, exception} ->
        raise exception
    end
  end

  defp open(_index, pit_id, false, _keep_alive, _opts) when is_binary(pit_id) do
    {pit_id, false}
  end

  # A point in time the caller already has may have expired since. One
  # match_none search is the cheapest way to find out, and failing here — with
  # Elasticsearch's own error — beats failing halfway through a walk.
  defp open(_index, pit_id, true, _keep_alive, opts) when is_binary(pit_id) do
    case Search.search(%{query: %{match_none: %{}}, pit: %{id: pit_id}}, opts) do
      {:ok, _response} ->
        {pit_id, false}

      {:error, exception} ->
        raise exception
    end
  end

  defp close(pit_id, opts) do
    case Search.close_point_in_time(pit_id, opts) do
      {:ok, _response} ->
        :ok

      # The walk is already done and the point in time expires on its own, so
      # there is nothing here worth failing the caller over.
      {:error, _exception} ->
        :ok
    end
  end

  ## Private functions — the query

  defp prepare_query(query) do
    query
    |> put_new_field(:size, @default_size)
    |> put_new_field(:track_total_hits, false)
    |> put_field(:sort, sort(query))
  end

  # `_shard_doc` is what makes `search_after` deterministic. A sort of the
  # caller's own comes first and the tiebreaker last; a single sort spec given
  # as a map or a string is wrapped rather than appended to, which `++` would
  # refuse.
  defp sort(query) do
    case fetch_field(query, :sort) do
      nil -> [@shard_doc]
      sort when is_list(sort) -> if shard_doc?(sort), do: sort, else: sort ++ [@shard_doc]
      sort -> [sort, @shard_doc]
    end
  end

  defp shard_doc?(sort) do
    Enum.any?(sort, fn
      "_shard_doc" -> true
      %{} = entry -> Enum.any?(entry, fn {key, _} -> to_string(key) == "_shard_doc" end)
      _other -> false
    end)
  end

  defp put_search_after(query, :start), do: query
  defp put_search_after(query, cursor), do: put_field(query, :search_after, cursor)

  ## Private functions — atom/string keyed queries

  # A query may be written with atom or string keys. Reading and writing both
  # forms keeps this module from adding a second `"sort"` to a body that
  # already has one — which would be encoded as a duplicate JSON member, and
  # could cost the `_shard_doc` tiebreaker.

  defp fetch_field(query, key, default \\ nil) do
    case Map.fetch(query, key) do
      {:ok, value} -> value
      :error -> Map.get(query, Atom.to_string(key), default)
    end
  end

  defp put_field(query, key, value) do
    if Map.has_key?(query, key) or not Map.has_key?(query, Atom.to_string(key)) do
      Map.put(query, key, value)
    else
      Map.put(query, Atom.to_string(key), value)
    end
  end

  defp put_new_field(query, key, value) do
    if is_nil(fetch_field(query, key)), do: put_field(query, key, value), else: query
  end

  ## Private functions — options

  # `slice` is a search body field, like `size` and `sort`, and neither of those
  # has an option either. It used to, though, so say so rather than ignoring it.
  defp reject_slice_opt!(opts) do
    if Keyword.has_key?(opts, :slice) do
      raise ArgumentError,
            "`slice` belongs in the query body, not the options — " <>
              "%{query: ..., slice: %{id: 2, max: 8}}. To walk every slice at " <>
              "once, see stream_with_slice/4."
    end
  end

  defp shaper(opts) do
    {key_fun, decoder} = Client.resolve_decoder(opts)

    fn hit -> ClientDecoder.run(hit, key_fun, decoder) end
  end

  # The pass-through that keeps this module's own requests raw; see stream/2.
  defp raw(body, _opts), do: body
end

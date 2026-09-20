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
  `:slice` is how you get parallelism; see below.

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
    * `:slice` — how to split the point in time, in one of three shapes:
      * an integer — that many slices, walked **concurrently**.
      * `{max, opts}` — the same, with `opts` merged into each slice, for
        `field: "_id"` and friends.
      * a map — one slice, walked on its own, verbatim. This is the shape for
        fanning out across nodes rather than processes: each node walks
        `%{id: n, max: total}` of a point in time you opened and pass in.

  Everything else is forwarded to `Dowser.Elasticsearch.Search`, so `:context`,
  `:codec`, `:keys` and `:http_opts` all work as usual.

  A query with no `size` gets 1000, not Elasticsearch's default of 10 —
  at 10 hits per round trip a million documents is a hundred thousand
  requests. Set your own when you have a reason to.

  ## Slicing

  `:slice` splits the point in time into disjoint subsets and walks them at
  once. Elasticsearch divides first across shards, then within each shard by
  contiguous ranges of Lucene document ids, so the natural ceiling is your
  shard count — more slices than shards subdivides a shard rather than adding
  parallelism.

      %{query: %{match_all: %{}}, size: 1_000}
      |> Dowser.Elasticsearch.Streamer.stream(index: "posts", slice: 4)
      |> Enum.each(&process/1)

  Anything else the slice needs travels in the second element of a tuple, and
  is merged into every slice:

      stream(query, index: "posts", slice: {7, field: "_id"})
      # each request carries %{"id" => 0..6, "max" => 7, "field" => "_id"}

  All slices share one point in time, which is why the stream owns it: no
  single slice can close it without cutting the others off. To spread the walk
  across *nodes* instead, open the point in time yourself and give each node
  one slice as a map:

      stream(query, pit: pit_id, slice: %{id: 2, max: 8})

  The merged stream stays lazy — one request per slice is in flight at a time,
  so at most `slices × size` hits are held. Those requests are made from
  spawned tasks rather than the enumerating process, which matters for anything
  process-scoped; an unsliced stream requests inline. That is also why the fan-out is not
  `Task.async_stream/3`: it yields one result per element, so a slice would
  have to be fully materialized before you saw any of it.

  `Task.async_stream/3` is still the right tool one level out, when the work
  per hit is the bottleneck rather than the fetching:

      query
      |> Dowser.Elasticsearch.Streamer.stream(index: "posts")
      |> Task.async_stream(&process/1, ordered: false)
      |> Stream.run()

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
    {slice, opts} = Keyword.pop(opts, :slice)

    splits = split!(slice)
    shaper = shaper(opts)
    query = prepare_query(query)
    size = fetch_field(query, :size, @default_size)

    # Every request this module makes has to come back as plain string-keyed
    # JSON: it reads `hits.hits[]`, each hit's `sort` and the `pit_id` by those
    # names. The casting the caller configured is applied to the hits instead,
    # one at a time, by `shaper`.
    opts = Keyword.merge(opts, keys: :strings, decoder: &raw/2)

    Stream.resource(
      fn -> start(query, index, pit_id, keep_alive, splits, size, opts) end,
      &next(&1, query, shaper, opts),
      &stop(&1, opts)
    )
  end

  ## Private functions — the resource

  defp start(query, index, pit_id, keep_alive, splits, size, opts) do
    {pit_id, owned?} = open(index, pit_id, keep_alive, opts)
    state = %{pit: pit_id, keep_alive: keep_alive, owned?: owned?, size: size}

    case splits do
      # One split needs no concurrency — a single cursor fetches, emits and
      # fetches again — and running it inline keeps the stream lazy to the
      # page, keeps stacktraces direct, and keeps every request in the
      # enumerating process.
      [split] ->
        Map.merge(state, %{split: split, cursor: :start})

      splits ->
        Enum.reduce(splits, Map.put(state, :tasks, %{}), &launch(&2, &1, :start, query, opts))
    end
  end

  ## Private functions — one cursor, inline

  defp next(%{cursor: :done} = state, _query, _shaper, _opts) do
    {:halt, state}
  end

  defp next(%{cursor: cursor} = state, query, shaper, opts) do
    case query |> build(state, state.split, cursor) |> Search.search(opts) do
      {:ok, response} ->
        {hits, cursor, pit_id} = page(response, state.size)

        {Enum.map(hits, shaper), %{state | pit: pit_id || state.pit, cursor: cursor}}

      {:error, exception} ->
        raise exception
    end
  end

  ## Private functions — several slices, concurrently

  defp next(%{tasks: tasks} = state, _query, _shaper, _opts) when map_size(tasks) == 0 do
    {:halt, state}
  end

  defp next(%{tasks: _tasks} = state, query, shaper, opts) do
    {split, result, tasks} = await_any(state.tasks)
    state = %{state | tasks: tasks}

    case result do
      {:ok, response} ->
        {hits, cursor, pit_id} = page(response, state.size)
        state = %{state | pit: pit_id || state.pit}
        state = if cursor == :done, do: state, else: launch(state, split, cursor, query, opts)

        {Enum.map(hits, shaper), state}

      {:error, exception} ->
        raise exception

      {:raised, exception, stacktrace} ->
        reraise(exception, stacktrace)
    end
  end

  defp launch(state, split, cursor, query, opts) do
    body = build(query, state, split, cursor)
    task = Task.async(fn -> run(body, opts) end)

    %{state | tasks: Map.put(state.tasks, task.ref, {split, task})}
  end

  # Nothing here may crash: `Task.async/1` links, and a linked crash would take
  # the enumerating process down without giving `Stream.resource/3` the chance
  # to close the point in time.
  defp run(body, opts) do
    Search.search(body, opts)
  rescue
    exception -> {:raised, exception, __STACKTRACE__}
  end

  defp await_any(tasks) do
    receive do
      {ref, result} when is_map_key(tasks, ref) ->
        Process.demonitor(ref, [:flush])
        {split, _task} = Map.fetch!(tasks, ref)

        {split, result, Map.delete(tasks, ref)}

      {:DOWN, ref, :process, _pid, reason} when is_map_key(tasks, ref) ->
        {split, _task} = Map.fetch!(tasks, ref)

        raise "the slice #{inspect(split)} of the stream died: #{inspect(reason)}"
    end
  end

  defp stop(state, opts) do
    state
    |> Map.get(:tasks, %{})
    |> Enum.each(fn {_ref, {_split, task}} -> Task.shutdown(task, :brutal_kill) end)

    if state.owned?, do: close(state.pit, opts)

    :ok
  end

  ## Private functions — one page

  defp page(response, size) do
    hits = get_in(response, ["hits", "hits"]) || []

    # A short page is the last one, so a cursor stops without the extra request
    # it would take to see an empty one.
    cursor = if hits != [] and length(hits) >= size, do: last_sort(hits), else: :done

    # Elasticsearch may hand back a different id than the one it was given, and
    # says to use the most recent for the next request.
    {hits, cursor, response["pit_id"]}
  end

  defp build(query, state, split, cursor) do
    query
    |> put_field(:pit, %{"id" => state.pit, "keep_alive" => state.keep_alive})
    |> put_split(split)
    |> put_search_after(cursor)
  end

  defp last_sort(hits), do: hits |> List.last() |> Map.fetch!("sort")

  ## Private functions — the point in time

  defp open(index, nil, keep_alive, opts) do
    case Search.open_point_in_time(%{}, index, keep_alive, opts) do
      {:ok, %{"id" => pit_id}} ->
        {pit_id, true}

      {:error, exception} ->
        raise exception
    end
  end

  # A point in time the caller already has may have expired since. One
  # match_none search is the cheapest way to find out, and failing here — with
  # Elasticsearch's own error — beats failing halfway through a walk.
  defp open(_index, pit_id, _keep_alive, opts) when is_binary(pit_id) do
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

  defp put_split(query, nil), do: query
  defp put_split(query, %{} = slice), do: put_field(query, :slice, slice)

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

  # Three shapes, one option: an integer or `{max, opts}` fans out over
  # `0..max - 1`, a map is one slice taken verbatim, and nothing at all is one
  # unsliced walk. `:id` and `:max` are computed here, so anything carrying
  # them in `opts` loses.
  defp split!(nil), do: [nil]
  defp split!(1), do: [nil]

  defp split!(max) when is_integer(max) and max > 1 do
    Enum.map(0..(max - 1), &%{"id" => &1, "max" => max})
  end

  defp split!({max, slice_opts})
       when is_integer(max) and max > 1 and (is_list(slice_opts) or is_map(slice_opts)) do
    extra = Map.new(slice_opts, fn {key, value} -> {to_string(key), value} end)

    Enum.map(0..(max - 1), &Map.merge(extra, %{"id" => &1, "max" => max}))
  end

  defp split!(%{} = slice), do: [slice]

  defp split!(other) do
    raise ArgumentError,
          "invalid :slice #{inspect(other)}, expected a positive integer, a " <>
            "{max, opts} tuple with max > 1, or a map holding one slice"
  end

  defp shaper(opts) do
    {key_fun, decoder} = Client.resolve_decoder(opts)

    fn hit -> ClientDecoder.run(hit, key_fun, decoder) end
  end

  # The pass-through that keeps this module's own requests raw; see stream/2.
  defp raw(body, _opts), do: body
end

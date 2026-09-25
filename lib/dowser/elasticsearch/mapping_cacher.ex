defmodule Dowser.Elasticsearch.MappingCacher do
  @moduledoc """
  Per-node cache of Elasticsearch index mappings.

  A GenServer owns an ETS table; reads go straight to ETS (concurrent,
  lock-free), and only misses/expired entries go through the GenServer — which
  de-duplicates concurrent fetches for the same key (single-flight).

  Entries are keyed by `{endpoint, scope, index}`, so the same index reached
  through different contexts is cached separately, and each fetch honours its
  context. The *scope* is what distinguishes two contexts pointing at the same
  endpoint — see `key/2`.

  ## Options (`start_link/1`)

    * `:ttl` — entry lifetime in **ms** (default 5 min).
    * `:sweep_interval` — how often expired entries are actively purged, in ms
      (default 1 min). `nil`/`0` disables active sweeping; lazy expiration on
      read still applies.
    * `:fetch` — `(context, index -> {:ok, value} | {:error, reason})`, how a
      mapping is loaded on a miss. Defaults to a `Dowser.Client` `_mapping` call.
      Have it return the *compiled schema* rather than the raw mapping to keep
      cached values small.
    * `:eager` — preload at startup via `handle_continue/2`: `false` (default,
      lazy), a list of `{context, index}`, or a 0-arity fun returning one.

  Whether the cacher is started at all (and with which options) is decided by
  the supervisor — see Dowser.Elasticsearch.Application.

  ## Mappings that are never fetched

  A mapping given in the application environment answers for its index without
  any request at all — and so can never fail to be fetched:

      config :dowser_elasticsearch,
        mappings: %{"posts" => %{"properties" => %{"published_at" => %{"type" => "date"}}}}

  It wins over the cache. Use it for an index whose mapping is pinned, and in
  test suites, where it makes casting behave as it does in production without
  a cluster to ask (`put/3` does the same through a running cacher).

  ## When a fetch fails

  `lookup/2` distinguishes "there is no mapping" from "the mapping could not be
  fetched"; `fetch/2` is the lenient read that folds both into `nil`. The
  difference matters because the second silently changes the *type* of what a
  caller gets back — see `Dowser.Elasticsearch.Codec`'s `:mapping_failure`.
  """

  use GenServer

  require Logger

  alias Dowser.Client.Context

  @table __MODULE__
  @forever :timer.hours(24 * 365 * 100)
  @default_ttl :timer.minutes(5)
  @default_sweep :timer.minutes(1)
  @call_timeout :timer.seconds(15)

  ## Client API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The cache key for `{context, index}`: `{endpoint, scope, index}`.

  Two contexts pointing at the same endpoint do not necessarily see the same
  mapping — different credentials can mean field-level security hiding fields,
  or an alias resolving to a different concrete index — so the credentials are
  part of what identifies an entry.

  They are *hashed* into it rather than stored. A cache key lives in an ETS
  table for the lifetime of the entry, where any process can read it and a
  crash dump would carry it; `Dowser.Client.Context` goes as far as redacting
  `:auth` from its own `Inspect`, and putting it in a table here would undo
  that.

  The hash is SHA-256, truncated to 128 bits. An application that builds
  contexts from end-user credentials makes the hashed value attacker-
  influenced, and a collision there would serve one tenant another's mapping —
  so the cheaper `:erlang.phash2/1` is the wrong tool: its default range is
  2^27, which a targeted collision search exhausts in seconds.

  `:http_opts` is hashed alongside `:auth`, since a credential can also arrive
  as a header and a proxy or TLS setting can change which cluster answers. The
  purely client-side fields (`:profile`, `:keys`, `:decoder`, `:encoder`) are
  not: they can't change what Elasticsearch returns. A plain unauthenticated
  context hashes to `nil`, so the common key stays readable.
  """
  @spec key(Context.t(), term()) :: {String.t(), binary() | nil, term()}
  def key(%Context{} = context, index), do: {context.endpoint, scope(context), index}

  @doc "Returns the mapping for `{context, index}`, fetching lazily on a miss."
  def get(context, index) do
    with {:ok, resolved} <- Context.resolve(context) do
      key = key(resolved, index)

      # Hot path: read ETS directly, no GenServer involved.
      case fresh_lookup(key) do
        {:ok, value} ->
          {:ok, value}

        :miss ->
          GenServer.call(__MODULE__, {:fetch, key, resolved, index}, @call_timeout)
      end
    end
  end

  @doc """
  Like `get/2`, but tells a mapping that *cannot exist* apart from one that
  *could not be fetched* — which `get/2` reports the same way, and which the
  caller must not: casting against no mapping is correct for the first and
  silently wrong for the second.

    * `{:ok, mapping}` — a static mapping, a cached one, or a freshly fetched
      one.
    * `{:ok, nil}` — there is no mapping to be had: no index named, or no
      cacher running (an application that doesn't cast at all).
    * `{:error, reason}` — the fetch failed. The mapping may well exist; this
      request just couldn't see it. `Dowser.Elasticsearch.Codec` turns this
      into a `Dowser.Elasticsearch.MappingError` by default, rather than
      casting nothing and handing back raw JSON values.

  A static mapping (`config :dowser_elasticsearch, mappings: %{...}`) wins over
  the cache and is never fetched, so it cannot fail.
  """
  @spec lookup(Context.ref(), term()) :: {:ok, map() | nil} | {:error, term()}
  def lookup(context, index)

  def lookup(nil, _index), do: {:ok, nil}
  def lookup(_context, nil), do: {:ok, nil}

  def lookup(context, index) do
    case static(index) do
      nil ->
        cached(context, index)

      mapping ->
        {:ok, mapping}
    end
  end

  @doc """
  Like `lookup/2`, but returns the mapping directly, or `nil` when there is
  none to be had *or* the fetch failed.

  The lenient read: a mapping that can't be resolved degrades a cast to
  identity rather than failing the request. `Dowser.Elasticsearch.Codec` uses
  it only under `mapping_failure: :ignore`.
  """
  @spec fetch(Context.ref(), term()) :: map() | nil
  def fetch(context, index) do
    case lookup(context, index) do
      {:ok, mapping} ->
        mapping

      {:error, _reason} ->
        nil
    end
  end

  @doc """
  Caches `mapping` for `index` directly, without fetching anything.

  The seam tests use, so that casting behaves the way it does in production
  instead of degrading to identity for want of a cluster to ask:

      setup do
        Dowser.Elasticsearch.MappingCacher.put("posts", %{"properties" => %{...}})
      end

  ## Options

    * `:context` — the context the entry belongs to, as in `key/2`
      (default `nil`, the unauthenticated one).
    * `:ttl` — entry lifetime in ms (default `:infinity`, unlike a fetched
      entry: an entry put by hand is not a cached answer that can go stale).

  For a mapping that is *always* known — a pinned index, a test suite that
  never starts the cacher — `config :dowser_elasticsearch, mappings: %{...}`
  needs no running cacher at all.
  """
  @spec put(term(), map(), keyword()) :: :ok
  def put(index, mapping, opts \\ []) when is_map(mapping) do
    if not running?() do
      raise "#{inspect(__MODULE__)} is not running; start it before putting a mapping into it"
    end

    ttl = Keyword.get(opts, :ttl, :infinity)

    GenServer.call(__MODULE__, {:put, Keyword.get(opts, :context), index, mapping, ttl})
  end

  @doc "Invalidates a single `{context, index}` entry."
  def invalidate(context, index), do: GenServer.call(__MODULE__, {:invalidate, context, index})

  @doc "Clears the whole cache."
  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Server

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    state = %{
      ttl: to_native(Keyword.get(opts, :ttl, @default_ttl)),
      sweep_interval: Keyword.get(opts, :sweep_interval, @default_sweep),
      fetch: Keyword.get(opts, :fetch, &default_fetch/2),
      eager: Keyword.get(opts, :eager, false),
      inflight: %{}
    }

    schedule_sweep(state.sweep_interval)
    {:ok, state, {:continue, :warm}}
  end

  # Eager preload — blocks startup until every configured mapping is loaded.
  @impl GenServer
  def handle_continue(:warm, state) do
    warm(state.eager, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:fetch, key, context, index}, from, state) do
    # Re-check under the GenServer: another caller may have filled it while we
    # were queued.
    case fresh_lookup(key) do
      {:ok, value} ->
        {:reply, {:ok, value}, state}

      :miss ->
        state = add_waiter(state, key, from)

        if first_waiter?(state, key) do
          start_fetch(state.fetch, key, context, index)
        end

        {:noreply, state}
    end
  end

  def handle_call({:put, context, index, mapping, ttl}, _from, state) do
    with {:ok, resolved} <- Context.resolve(context) do
      store(key(resolved, index), mapping, to_native(ttl))
    end

    {:reply, :ok, state}
  end

  def handle_call({:invalidate, context, index}, _from, state) do
    with {:ok, resolved} <- Context.resolve(context) do
      :ets.delete(@table, key(resolved, index))
    end

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # A single-flight fetch finished: store it, reply to every waiter.
  @impl GenServer
  def handle_info({:fetched, key, result}, state) do
    {waiters, inflight} = Map.pop(state.inflight, key, [])

    reply =
      case result do
        {:ok, value} ->
          store(key, value, state.ttl)
          {:ok, value}

        {:error, _reason} = error ->
          error
      end

    Enum.each(waiters, &GenServer.reply(&1, reply))
    {:noreply, %{state | inflight: inflight}}
  end

  # Active expiration.
  def handle_info(:sweep, state) do
    now = System.monotonic_time()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule_sweep(state.sweep_interval)
    {:noreply, state}
  end

  ## Keys

  # 128 bits: a birthday bound of 2^64 is far past anything a cache key needs,
  # and the key is copied on every lookup, so the other 16 bytes would be pure
  # overhead.
  @scope_bytes 16

  defp scope(%Context{auth: nil, http_opts: []}), do: nil

  defp scope(%Context{} = context) do
    # `:deterministic` because `:http_opts` may hold a map (`:headers`), whose
    # ordinary encoding is not canonical — two equal contexts must not scope
    # differently.
    binary = :erlang.term_to_binary({context.auth, context.http_opts}, [:deterministic])

    <<scope::binary-size(@scope_bytes), _rest::binary>> = :crypto.hash(:sha256, binary)

    scope
  end

  ## Reads (run in the caller's process, straight off ETS)

  # A mapping given in the application environment is the answer, whatever the
  # cluster would say — no request, so nothing to fail.
  defp static(index) do
    :dowser_elasticsearch
    |> Application.get_env(:mappings, %{})
    |> Enum.find_value(fn {name, mapping} -> named?(name, index) && mapping end)
  end

  defp named?(name, index) when is_binary(index) or is_atom(index),
    do: to_string(name) == to_string(index)

  defp named?(name, index), do: name == index

  defp cached(context, index) do
    if running?() do
      get(context, index)
    else
      {:ok, nil}
    end
  rescue
    exception ->
      {:error, exception}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  # Nothing to read from and nothing to ask: an application that doesn't cast
  # doesn't start the cacher, and that is not a failed fetch.
  defp running?, do: :ets.whereis(@table) != :undefined

  defp fresh_lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        # Lazy expiration: an entry past its deadline reads as a miss.
        if expires_at > System.monotonic_time() do
          {:ok, value}
        else
          :miss
        end

      [] ->
        :miss
    end
  end

  ## Single-flight

  defp add_waiter(state, key, from),
    do: %{state | inflight: Map.update(state.inflight, key, [from], &[from | &1])}

  defp first_waiter?(state, key), do: length(Map.fetch!(state.inflight, key)) == 1

  # Fetch off the GenServer so it stays responsive to other keys' misses.
  defp start_fetch(fetch, key, context, index) do
    parent = self()
    spawn(fn -> send(parent, {:fetched, key, safe_fetch(fetch, context, index)}) end)
  end

  defp safe_fetch(fetch, context, index) do
    fetch.(context, index)
  rescue
    error ->
      {:error, error}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  ## Storage / TTL

  defp store(key, value, ttl),
    do: :ets.insert(@table, {key, value, System.monotonic_time() + ttl})

  # An entry that never expires still carries a deadline, so the sweep and the
  # lazy check stay one comparison rather than two shapes.
  defp to_native(:infinity), do: to_native(@forever)
  defp to_native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp schedule_sweep(interval) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :sweep, interval)

  defp schedule_sweep(_disabled), do: :ok

  ## Eager warming

  defp warm(false, _state), do: :ok
  defp warm(fun, state) when is_function(fun, 0), do: warm(fun.(), state)

  defp warm(targets, state) when is_list(targets) do
    targets
    |> Task.async_stream(
      fn {context, index} -> {index, resolve_and_fetch(state.fetch, context, index)} end,
      max_concurrency: System.schedulers_online(),
      timeout: :timer.seconds(30),
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, {_index, {:ok, key, value}}} ->
        store(key, value, state.ttl)

      {:ok, {index, {:error, reason}}} ->
        log_warm(index, reason)

      {:exit, reason} ->
        log_warm(:unknown, reason)
    end)
  end

  defp resolve_and_fetch(fetch, context, index) do
    with {:ok, resolved} <- Context.resolve(context),
         {:ok, value} <- fetch.(resolved, index) do
      {:ok, key(resolved, index), value}
    end
  end

  defp log_warm(index, reason),
    do: Logger.warning("MappingCacher warm failed for #{inspect(index)}: #{inspect(reason)}")

  ## Default fetch — GET /<index>/_mapping via Dowser.Client

  defp default_fetch(context, index) do
    case Dowser.Client.get("/#{index}/_mapping",
           context: context,
           keys: :strings,
           decoder: &raw/2,
           format: :json
         ) do
      {:ok, %Dowser.Client.Response{status: 200, body: body}} ->
        {:ok, extract(body, index)}

      {:ok, %Dowser.Client.Response{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # A mapping document is not a search result, so the context's own `:decoder`
  # has nothing to cast in it — and calling it here would recurse straight back
  # into this cacher. `:decoder` can't be unset per request (a `nil` falls back
  # to the context), so it is overridden with a pass-through instead.
  defp raw(body, _opts), do: body

  # body: %{"<index>" => %{"mappings" => %{...}}}
  defp extract(body, index) do
    case body do
      %{^index => %{"mappings" => mappings}} ->
        mappings

      %{} ->
        body |> Map.values() |> List.first(%{}) |> Map.get("mappings", %{})
    end
  end
end

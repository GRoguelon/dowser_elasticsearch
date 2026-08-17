defmodule Dowser.Elasticsearch.MappingCacher do
  @moduledoc """
  Per-node cache of Elasticsearch index mappings.

  A GenServer owns an ETS table; reads go straight to ETS (concurrent,
  lock-free), and only misses/expired entries go through the GenServer — which
  de-duplicates concurrent fetches for the same key (single-flight).

  Entries are keyed by `{config endpoint, index}`, so the same index on
  different configs is cached separately, and each fetch honours its config.

  ## Options (`start_link/1`)

    * `:ttl` — entry lifetime in **ms** (default 5 min).
    * `:sweep_interval` — how often expired entries are actively purged, in ms
      (default 1 min). `nil`/`0` disables active sweeping; lazy expiration on
      read still applies.
    * `:fetch` — `(config, index -> {:ok, value} | {:error, reason})`, how a
      mapping is loaded on a miss. Defaults to a `Dowser.Client` `_mapping` call.
      Have it return the *compiled schema* rather than the raw mapping to keep
      cached values small.
    * `:eager` — preload at startup via `handle_continue/2`: `false` (default,
      lazy), a list of `{config, index}`, or a 0-arity fun returning one.

  Whether the cacher is started at all (and with which options) is decided by
  the supervisor — see Dowser.Elasticsearch.Application.
  """

  use GenServer

  require Logger

  alias Dowser.Client.Config

  @table __MODULE__
  @default_ttl :timer.minutes(5)
  @default_sweep :timer.minutes(1)
  @call_timeout :timer.seconds(15)

  ## Client API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the mapping for `{config, index}`, fetching lazily on a miss."
  def get(config, index) do
    with {:ok, resolved} <- Dowser.Client.Config.resolve(config) do
      key = {resolved.endpoint, index}

      # Hot path: read ETS directly, no GenServer involved.
      case fresh_lookup(key) do
        {:ok, value} ->
          {:ok, value}

        :miss ->
          GenServer.call(__MODULE__, {:fetch, key, resolved, index}, @call_timeout)
      end
    end
  end

  @doc "Invalidates a single `{config, index}` entry."
  def invalidate(config, index), do: GenServer.call(__MODULE__, {:invalidate, config, index})

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
  def handle_call({:fetch, key, config, index}, from, state) do
    # Re-check under the GenServer: another caller may have filled it while we
    # were queued.
    case fresh_lookup(key) do
      {:ok, value} ->
        {:reply, {:ok, value}, state}

      :miss ->
        state = add_waiter(state, key, from)

        if first_waiter?(state, key) do
          start_fetch(state.fetch, key, config, index)
        end

        {:noreply, state}
    end
  end

  def handle_call({:invalidate, config, index}, _from, state) do
    with {:ok, resolved} <- Config.resolve(config) do
      :ets.delete(@table, {resolved.endpoint, index})
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

  ## Reads (run in the caller's process, straight off ETS)

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
  defp start_fetch(fetch, key, config, index) do
    parent = self()
    spawn(fn -> send(parent, {:fetched, key, safe_fetch(fetch, config, index)}) end)
  end

  defp safe_fetch(fetch, config, index) do
    fetch.(config, index)
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
      fn {config, index} -> {index, resolve_and_fetch(state.fetch, config, index)} end,
      max_concurrency: System.schedulers_online(),
      timeout: :timer.seconds(30),
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:ok, {index, {:ok, endpoint, value}}} ->
        store({endpoint, index}, value, state.ttl)

      {:ok, {index, {:error, reason}}} ->
        log_warm(index, reason)

      {:exit, reason} ->
        log_warm(:unknown, reason)
    end)
  end

  defp resolve_and_fetch(fetch, config, index) do
    with {:ok, resolved} <- Config.resolve(config),
         {:ok, value} <- fetch.(resolved, index) do
      {:ok, resolved.endpoint, value}
    end
  end

  defp log_warm(index, reason),
    do: Logger.warning("MappingCacher warm failed for #{inspect(index)}: #{inspect(reason)}")

  ## Default fetch — GET /<index>/_mapping via Dowser.Client

  defp default_fetch(config, index) do
    case Dowser.Client.get("/#{index}/_mapping",
           config: config,
           codec_adapter: nil,
           keys: :strings,
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

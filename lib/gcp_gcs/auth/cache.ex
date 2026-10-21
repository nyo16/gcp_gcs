defmodule GcpGcs.Auth.Cache do
  @moduledoc false
  # Owns the access-token cache and its refresh.
  #
  # Reads are lock-free ETS lookups in the caller. On a miss the caller asks
  # this process to fetch. The fetch runs in a task under
  # GcpGcs.TaskSupervisor, so this process never blocks: callers that miss
  # while it runs are kept in the state (not in the mailbox) and all get its
  # result (one gcloud run per refresh), and `clear/0` answers at once. The
  # table is :protected — only this process writes to it.
  #
  # Entries are refreshed at 80% of their TTL; failures are cached for 5 s so
  # a broken credential source isn't hammered. The fetch function enforces
  # its own deadline (`config :gcp_gcs, :gcloud_timeout`); as a backstop the
  # task is stopped 2 s after it, and callers wait at most that plus 3 s.
  # Fetch tasks trap exits, so a stopped fetch can clean up (the gcloud
  # runner kills its OS process).
  #
  # `clear/0` detaches a running fetch: its waiters still get its result, but
  # it isn't cached, and the next miss starts a new fetch, which reads the
  # credentials as they are after the clear.
  #
  # After a 401 the caller passes the token it sent as `stale`: a cached token
  # with the same fingerprint then counts as a miss (both in the caller and
  # in the server), so the token is replaced once, and a fresher token that
  # another caller already fetched is returned as is. Only a SHA-256
  # fingerprint of it is sent to this process, so the token never appears in
  # call messages or crash reports.

  use GenServer

  require Logger

  alias GcpGcs.{Config, Error}

  @table :gcp_gcs_auth_cache
  @key :token
  @negative_ttl_ms 5_000
  @refresh_ratio 0.8
  @deadline_margin_ms 2_000
  @call_margin_ms 5_000
  @fetch_shutdown_ms 500
  @task_supervisor GcpGcs.TaskSupervisor

  @type fetch_fun :: (-> {:ok, String.t(), non_neg_integer()} | {:error, Error.t()})

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec table() :: atom()
  def table, do: @table

  @doc """
  Returns the cached result, or runs `fun` once (single-flight) and caches it.
  A cached `{:ok, stale}` is treated as a miss.
  """
  @spec fetch(fetch_fun(), String.t() | nil) :: {:ok, String.t()} | {:error, Error.t()}
  def fetch(fun, stale \\ nil) do
    stale_fp = stale && fingerprint(stale)

    case lookup(stale_fp) do
      {:hit, result} -> result
      :miss -> call({:fetch, fun, stale_fp}, fun)
    end
  end

  # Never exits: clearing the cache must not crash the caller.
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  catch
    :exit, _ -> :ok
  end

  defp lookup(stale_fp) do
    case :ets.lookup(@table, @key) do
      [{@key, _result, _refresh_at, fp}] when stale_fp != nil and fp == stale_fp ->
        :miss

      [{@key, result, refresh_at, _fp}] ->
        if now() < refresh_at, do: {:hit, result}, else: :miss

      [] ->
        :miss
    end
  rescue
    # Table doesn't exist (cache process not started or restarting).
    ArgumentError -> :miss
  end

  defp call(request, fun) do
    GenServer.call(__MODULE__, request, Config.gcloud_timeout() + @call_margin_ms)
  catch
    :exit, {:noproc, _} ->
      # Cache not running: still serve the request, uncached.
      Logger.warning("GcpGcs: auth cache unavailable; token not cached")
      to_result(fun.())

    :exit, {:timeout, _} ->
      {:error, Error.new(:unauthenticated, "timed out waiting for an access token")}

    :exit, _ ->
      # The cache stopped or crashed while this caller waited.
      {:error, Error.new(:unauthenticated, "access token cache unavailable")}
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    # `current`: the running fetch new misses join (nil when none, or after a
    # clear); `fetches`: every running fetch by task ref, detached ones too.
    {:ok, %{current: nil, fetches: %{}}}
  end

  @impl true
  def handle_call({:fetch, fun, stale_fp}, from, state) do
    case {lookup(stale_fp), state.current} do
      {{:hit, result}, _} -> {:reply, result, state}
      {:miss, nil} -> start_fetch(fun, from, state)
      {:miss, ref} -> {:noreply, update_in(state.fetches[ref].waiters, &[from | &1])}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | current: nil}}
  end

  @impl true
  def handle_info({ref, fetched}, state) when is_map_key(state.fetches, ref) do
    Process.demonitor(ref, [:flush])
    finish(state, ref, fetched)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state)
      when is_map_key(state.fetches, ref) do
    Logger.error("GcpGcs: access token fetch crashed")
    finish(state, ref, {:error, Error.new(:unauthenticated, "access token fetch crashed")})
  end

  def handle_info({:fetch_deadline, ref}, state) when is_map_key(state.fetches, ref) do
    Logger.error("GcpGcs: access token fetch did not finish in time; stopped")
    _ = Task.Supervisor.terminate_child(@task_supervisor, state.fetches[ref].pid)
    Process.demonitor(ref, [:flush])
    finish(state, ref, {:error, Error.new(:unauthenticated, "access token fetch timed out")})
  end

  # Late replies of stopped fetches, expired deadlines and anything else.
  def handle_info(message, state) do
    Logger.debug(fn -> "GcpGcs: auth cache ignored #{inspect(message, limit: 5)}" end)
    {:noreply, state}
  end

  defp start_fetch(fun, from, state) do
    # Fetch tasks trap exits to clean up when stopped (the gcloud runner
    # kills its OS process), which takes milliseconds; a fetch that ignores
    # the shutdown is killed after @fetch_shutdown_ms, so stopping one never
    # blocks this process for long.
    task =
      Task.Supervisor.async_nolink(
        @task_supervisor,
        fn ->
          Process.flag(:trap_exit, true)
          fun.()
        end,
        shutdown: @fetch_shutdown_ms
      )

    timer =
      Process.send_after(
        self(),
        {:fetch_deadline, task.ref},
        Config.gcloud_timeout() + @deadline_margin_ms
      )

    fetch = %{pid: task.pid, waiters: [from], timer: timer}
    {:noreply, %{state | current: task.ref, fetches: Map.put(state.fetches, task.ref, fetch)}}
  catch
    # GcpGcs.TaskSupervisor is down (restarting): fail this caller, cache nothing.
    :exit, _ ->
      {:reply, {:error, Error.new(:unauthenticated, "access token fetch could not start")}, state}
  end

  defp finish(state, ref, fetched) do
    {fetch, fetches} = Map.pop!(state.fetches, ref)
    _ = Process.cancel_timer(fetch.timer)
    result = to_result(fetched)

    state =
      if state.current == ref do
        :ets.insert(@table, {@key, result, refresh_at(fetched), token_fingerprint(result)})
        %{state | current: nil, fetches: fetches}
      else
        %{state | fetches: fetches}
      end

    Enum.each(fetch.waiters, &GenServer.reply(&1, result))
    {:noreply, state}
  end

  defp fingerprint(token), do: :crypto.hash(:sha256, token)

  defp token_fingerprint({:ok, token}), do: fingerprint(token)
  defp token_fingerprint({:error, _}), do: nil

  defp to_result({:ok, token, _ttl_ms}), do: {:ok, token}
  defp to_result({:error, %Error{}} = error), do: error

  defp refresh_at({:ok, _token, ttl_ms}), do: now() + trunc(ttl_ms * @refresh_ratio)
  defp refresh_at({:error, _}), do: now() + @negative_ttl_ms

  defp now, do: System.monotonic_time(:millisecond)
end

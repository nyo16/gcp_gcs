defmodule GcpGcs.Auth.Cache do
  @moduledoc false
  # Owns the access-token cache and its refresh.
  #
  # Reads are lock-free ETS lookups in the caller. On a miss the caller asks
  # this process to fetch: the call re-checks the table first, so concurrent
  # callers that queued behind the first fetch get its result instead of
  # starting their own (one gcloud run per refresh). The table is :protected —
  # only this process writes to it.
  #
  # Entries are refreshed at 80% of their TTL; failures are cached for 5 s so
  # a broken credential source isn't hammered.

  use GenServer

  require Logger

  alias GcpGcs.Error

  @table :gcp_gcs_auth_cache
  @key :token
  @negative_ttl_ms 5_000
  @refresh_ratio 0.8
  @fetch_timeout 60_000

  @type fetch_fun :: (-> {:ok, String.t(), non_neg_integer()} | {:error, Error.t()})

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec table() :: atom()
  def table, do: @table

  @doc """
  Returns the cached result, or runs `fun` once (single-flight) and caches it.
  """
  @spec fetch(fetch_fun()) :: {:ok, String.t()} | {:error, Error.t()}
  def fetch(fun) do
    case lookup() do
      {:hit, result} -> result
      :miss -> call({:fetch, fun}, fun)
    end
  end

  @spec clear() :: :ok
  def clear do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :clear), else: :ok
  end

  defp lookup do
    case :ets.lookup(@table, @key) do
      [{@key, result, refresh_at}] ->
        if System.monotonic_time(:millisecond) < refresh_at, do: {:hit, result}, else: :miss

      [] ->
        :miss
    end
  rescue
    # Table doesn't exist (cache process not started or restarting).
    ArgumentError -> :miss
  end

  defp call(request, fun) do
    GenServer.call(__MODULE__, request, @fetch_timeout)
  catch
    :exit, {:noproc, _} ->
      # Cache not running: still serve the request, uncached.
      Logger.warning("GcpGcs: auth cache unavailable; token not cached")
      to_result(fun.())

    :exit, {:timeout, _} ->
      {:error, Error.new(:unauthenticated, "timed out waiting for an access token")}
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:fetch, fun}, _from, state) do
    case lookup() do
      {:hit, result} ->
        {:reply, result, state}

      :miss ->
        fetched = fun.()
        :ets.insert(@table, {@key, to_result(fetched), refresh_at(fetched)})
        {:reply, to_result(fetched), state}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp to_result({:ok, token, _ttl_ms}), do: {:ok, token}
  defp to_result({:error, %Error{}} = error), do: error

  defp refresh_at({:ok, _token, ttl_ms}), do: now() + trunc(ttl_ms * @refresh_ratio)
  defp refresh_at({:error, _}), do: now() + @negative_ttl_ms

  defp now, do: System.monotonic_time(:millisecond)
end

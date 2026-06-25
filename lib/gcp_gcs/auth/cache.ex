defmodule GcpGcs.Auth.Cache do
  @moduledoc false
  # Owns the :gcp_gcs_auth_cache ETS table.
  #
  # Why a process: a public ETS table dies with its owner. Without a supervised
  # owner, the table would be created by whatever caller first touched
  # `GcpGcs.Auth` and would not be re-created after an Application restart.

  use GenServer

  @table :gcp_gcs_auth_cache

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec table() :: :ets.tid() | atom()
  def table, do: @table

  @impl true
  def init(:ok) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _tid ->
        # Already exists (test re-init or hot upgrade) — leave it alone.
        :ok
    end

    {:ok, nil}
  end
end

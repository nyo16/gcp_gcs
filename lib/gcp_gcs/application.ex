defmodule GcpGcs.Application do
  @moduledoc false
  # Supervises GcpGcs.TaskSupervisor (runs token fetches for the cache),
  # GcpGcs.Auth.Cache (owner of the access-token ETS table) and, unless
  # `config :gcp_gcs, :start_finch, false`, the Finch pool used for all
  # requests, sized from `config :gcp_gcs, :finch` (see GcpGcs.Config).
  use Application

  alias GcpGcs.Config

  @impl true
  def start(_type, _args) do
    _ = Config.refresh()
    Config.log_emulator_mode()

    auth = [{Task.Supervisor, name: GcpGcs.TaskSupervisor}, GcpGcs.Auth.Cache]

    children =
      if Config.start_finch?() do
        :ok = Config.check_trust_store!()
        auth ++ [{Finch, Config.finch_opts()}]
      else
        auth
      end

    opts = [strategy: :one_for_one, name: GcpGcs.Supervisor, max_restarts: 10]
    Supervisor.start_link(children, opts)
  end
end

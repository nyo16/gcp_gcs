defmodule GcpGcs.Application do
  @moduledoc """
  Starts the supervision tree for `GcpGcs`.

  Two children are supervised:

    * `GcpGcs.Auth`'s cache — an internal GenServer that owns the ETS table
      backing the access-token cache
    * `Finch` — the HTTP connection pool used for all requests

  The Finch pool is sized from `config :gcp_gcs, :finch` and targets either the
  production endpoint (`storage.googleapis.com`) or a configured emulator. See
  `GcpGcs.Config`.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    _ = GcpGcs.Config.refresh()
    warn_if_emulator_mode()

    children = [
      GcpGcs.Auth.Cache,
      {Finch, GcpGcs.Config.finch_opts()}
    ]

    opts = [strategy: :one_for_one, name: GcpGcs.Supervisor, max_restarts: 10]
    Supervisor.start_link(children, opts)
  end

  defp warn_if_emulator_mode do
    if GcpGcs.Config.emulator?() do
      Logger.warning(
        "GcpGcs: emulator mode is active — authentication will be skipped. " <>
          "Remove the `:gcp_gcs, :emulator` config (and STORAGE_EMULATOR_HOST) for production."
      )
    end
  end
end

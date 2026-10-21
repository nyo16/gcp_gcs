defmodule GcpGcs.Application do
  @moduledoc """
  Starts the supervision tree for `GcpGcs`.

  Two children are supervised:

    * `GcpGcs.Auth`'s cache — an internal GenServer that owns the ETS table
      backing the access-token cache
    * `Finch` — the HTTP connection pool used for all requests, unless
      `config :gcp_gcs, :start_finch, false` (then name your own instance with
      `config :gcp_gcs, :finch_name`)

  The Finch pool is sized from `config :gcp_gcs, :finch` and targets either the
  production endpoint (`storage.googleapis.com`) or a configured emulator. See
  `GcpGcs.Config`.
  """
  use Application

  alias GcpGcs.Config

  @impl true
  def start(_type, _args) do
    _ = Config.refresh()
    Config.log_emulator_mode()

    children =
      if Config.start_finch?(),
        do: [GcpGcs.Auth.Cache, {Finch, Config.finch_opts()}],
        else: [GcpGcs.Auth.Cache]

    opts = [strategy: :one_for_one, name: GcpGcs.Supervisor, max_restarts: 10]
    Supervisor.start_link(children, opts)
  end
end

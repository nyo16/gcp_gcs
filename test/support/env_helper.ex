defmodule GcpGcs.EnvHelper do
  @moduledoc false
  # Test-scoped application/system env changes, restored on test exit. Restores
  # an originally-unset key with `delete_env` rather than writing `nil` back,
  # which would leave a `nil` value that `Application.get_env/3` defaults skip.
  #
  # The endpoint is resolved once and cached (`GcpGcs.Config.refresh/0`), so
  # every change and every restore re-resolves it.

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias GcpGcs.Config

  @doc "Sets `app`/`key` to `value` for the current test."
  @spec put_env_for_test(atom(), atom(), term()) :: :ok
  def put_env_for_test(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)
    Config.refresh()
    on_exit(fn -> restore_app_env(app, key, previous) end)
    :ok
  end

  @doc "Deletes `app`/`key` for the current test."
  @spec delete_env_for_test(atom(), atom()) :: :ok
  def delete_env_for_test(app, key) do
    previous = Application.fetch_env(app, key)
    Application.delete_env(app, key)
    Config.refresh()
    on_exit(fn -> restore_app_env(app, key, previous) end)
    :ok
  end

  @doc "Sets (or, with `nil`, unsets) an OS environment variable for the current test."
  @spec put_system_env_for_test(String.t(), String.t() | nil) :: :ok
  def put_system_env_for_test(name, value) do
    previous = System.get_env(name)
    set_system_env(name, value)
    on_exit(fn -> set_system_env(name, previous) end)
    :ok
  end

  @doc "Points the library at a plain-HTTP emulator on `localhost:port` for the current test."
  @spec put_emulator_for_test(pos_integer()) :: :ok
  def put_emulator_for_test(port) do
    put_env_for_test(:gcp_gcs, :emulator, scheme: "http", host: "localhost", port: port)
  end

  defp restore_app_env(app, key, {:ok, value}) do
    Application.put_env(app, key, value)
    Config.refresh()
  end

  defp restore_app_env(app, key, :error) do
    Application.delete_env(app, key)
    Config.refresh()
  end

  defp set_system_env(name, nil) do
    System.delete_env(name)
    Config.refresh()
  end

  defp set_system_env(name, value) do
    System.put_env(name, value)
    Config.refresh()
  end
end

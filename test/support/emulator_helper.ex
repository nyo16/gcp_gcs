defmodule GcpGcs.EmulatorHelper do
  @moduledoc false
  # Helpers for integration tests that run against a local GCS emulator
  # (e.g. fsouza/fake-gcs-server). See docker-compose.yml.

  @doc "Returns true if a TCP connection to the configured endpoint succeeds."
  @spec emulator_running?() :: boolean()
  def emulator_running? do
    {_scheme, host, port} = GcpGcs.Config.endpoint()

    case :gen_tcp.connect(to_charlist(host), port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @doc "Generates a unique, valid resource name with the given prefix."
  @spec unique(String.t()) :: String.t()
  def unique(prefix) do
    # Timestamp + per-VM counter so names don't collide with leftover resources
    # from a previous test run still living in the emulator.
    "#{prefix}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end
end

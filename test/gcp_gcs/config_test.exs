defmodule GcpGcs.ConfigTest do
  # Not async: these tests mutate global application/system env.
  use ExUnit.Case, async: false

  alias GcpGcs.Config

  setup do
    original = Application.get_env(:gcp_gcs, :emulator)
    original_host = System.get_env("STORAGE_EMULATOR_HOST")

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:gcp_gcs, :emulator)
      else
        Application.put_env(:gcp_gcs, :emulator, original)
      end

      if original_host do
        System.put_env("STORAGE_EMULATOR_HOST", original_host)
      else
        System.delete_env("STORAGE_EMULATOR_HOST")
      end
    end)

    :ok
  end

  describe "emulator config (keyword list)" do
    test "resolves base/json/upload URLs and endpoint" do
      Application.put_env(:gcp_gcs, :emulator, scheme: "http", host: "localhost", port: 4443)

      assert Config.emulator?()
      assert Config.base_url() == "http://localhost:4443"
      assert Config.json_base() == "http://localhost:4443/storage/v1"
      assert Config.upload_base() == "http://localhost:4443/upload/storage/v1"
      assert Config.endpoint() == {:http, "localhost", 4443}
    end

    test "defaults scheme/host/port sensibly" do
      Application.put_env(:gcp_gcs, :emulator, host: "emu")
      assert %{scheme: "http", host: "emu", port: 80} = Config.emulator()
    end
  end

  describe "production (no emulator)" do
    test "false disables emulator and ignores STORAGE_EMULATOR_HOST" do
      System.put_env("STORAGE_EMULATOR_HOST", "http://localhost:4443")
      Application.put_env(:gcp_gcs, :emulator, false)

      refute Config.emulator?()
      assert Config.base_url() == "https://storage.googleapis.com"
      assert Config.endpoint() == {:https, "storage.googleapis.com", 443}
    end
  end

  describe "STORAGE_EMULATOR_HOST env var" do
    test "is honored when no :emulator config is set" do
      Application.delete_env(:gcp_gcs, :emulator)
      System.put_env("STORAGE_EMULATOR_HOST", "http://127.0.0.1:9000")

      assert %{scheme: "http", host: "127.0.0.1", port: 9000} = Config.emulator()
      assert Config.base_url() == "http://127.0.0.1:9000"
    end

    test "tolerates a host:port value without a scheme" do
      Application.delete_env(:gcp_gcs, :emulator)
      System.put_env("STORAGE_EMULATOR_HOST", "localhost:4443")

      assert %{scheme: "http", host: "localhost", port: 4443} = Config.emulator()
    end
  end

  describe "finch_opts/0" do
    test "names the pool and configures a pool for the endpoint" do
      Application.put_env(:gcp_gcs, :emulator, scheme: "http", host: "localhost", port: 4443)
      opts = Config.finch_opts()

      assert opts[:name] == GcpGcs.Finch
      assert Map.has_key?(opts[:pools], "http://localhost:4443")
    end

    test "an http emulator pool has no TLS options" do
      Application.put_env(:gcp_gcs, :emulator, scheme: "http", host: "localhost", port: 4443)
      pool = Config.finch_opts()[:pools]["http://localhost:4443"]
      refute Keyword.has_key?(pool, :conn_opts)
    end

    test "the production https pool enforces certificate verification" do
      Application.put_env(:gcp_gcs, :emulator, false)
      pool = Config.finch_opts()[:pools]["https://storage.googleapis.com:443"]
      transport_opts = pool[:conn_opts][:transport_opts]

      assert transport_opts[:verify] == :verify_peer
      assert is_list(transport_opts[:cacerts])
    end
  end
end

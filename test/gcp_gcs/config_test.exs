defmodule GcpGcs.ConfigTest do
  # Not async: these tests mutate global application/system env.
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  alias GcpGcs.Config

  # Start every test from "nothing configured"; the helpers restore the
  # original values (including "unset") on exit and re-resolve the endpoint.
  setup do
    delete_env_for_test(:gcp_gcs, :emulator)
    put_system_env_for_test("STORAGE_EMULATOR_HOST", nil)
  end

  defp put_emulator(value), do: put_env_for_test(:gcp_gcs, :emulator, value)

  describe "emulator config (keyword list)" do
    test "resolves base/json/upload URLs and endpoint" do
      put_emulator(scheme: "http", host: "localhost", port: 4443)

      assert Config.emulator?()
      assert Config.base_url() == "http://localhost:4443"
      assert Config.json_base() == "http://localhost:4443/storage/v1"
      assert Config.upload_base() == "http://localhost:4443/upload/storage/v1"
      assert Config.endpoint() == {:http, "localhost", 4443}
    end

    test "defaults scheme/host/port sensibly" do
      put_emulator(host: "emu")
      assert %{scheme: "http", host: "emu", port: 80} = Config.emulator()
    end
  end

  describe "production (no emulator)" do
    test "false disables emulator and ignores STORAGE_EMULATOR_HOST" do
      put_system_env_for_test("STORAGE_EMULATOR_HOST", "http://localhost:4443")
      put_emulator(false)

      refute Config.emulator?()
      assert Config.base_url() == "https://storage.googleapis.com"
      assert Config.endpoint() == {:https, "storage.googleapis.com", 443}
    end
  end

  describe "STORAGE_EMULATOR_HOST env var" do
    test "is honored when no :emulator config is set" do
      put_system_env_for_test("STORAGE_EMULATOR_HOST", "http://127.0.0.1:9000")

      assert %{scheme: "http", host: "127.0.0.1", port: 9000} = Config.emulator()
      assert Config.base_url() == "http://127.0.0.1:9000"
    end

    test "tolerates a host:port value without a scheme" do
      put_system_env_for_test("STORAGE_EMULATOR_HOST", "localhost:4443")

      assert %{scheme: "http", host: "localhost", port: 4443} = Config.emulator()
    end
  end

  describe "endpoint resolution is cached" do
    test "app env changes apply only after refresh/0" do
      assert Config.base_url() == "https://storage.googleapis.com"

      Application.put_env(:gcp_gcs, :emulator, scheme: "http", host: "localhost", port: 9999)
      assert Config.base_url() == "https://storage.googleapis.com"
      refute Config.emulator?()

      Config.refresh()
      assert Config.base_url() == "http://localhost:9999"
      assert Config.emulator?()
    end
  end

  describe "finch_opts/0" do
    test "names the pool and configures a pool for the endpoint" do
      put_emulator(scheme: "http", host: "localhost", port: 4443)
      opts = Config.finch_opts()

      assert opts[:name] == GcpGcs.Finch
      assert Map.has_key?(opts[:pools], "http://localhost:4443")
    end

    test "an http emulator pool has no TLS options" do
      put_emulator(scheme: "http", host: "localhost", port: 4443)
      pool = Config.finch_opts()[:pools]["http://localhost:4443"]
      refute Keyword.has_key?(pool, :conn_opts)
    end

    test "the production https pool enforces certificate verification" do
      put_emulator(false)
      pool = Config.finch_opts()[:pools]["https://storage.googleapis.com:443"]
      transport_opts = pool[:conn_opts][:transport_opts]

      assert transport_opts[:verify] == :verify_peer
      assert is_list(transport_opts[:cacerts])
    end

    test "the default pool for other origins also enforces certificate verification" do
      put_emulator(scheme: "http", host: "localhost", port: 4443)
      transport_opts = Config.finch_opts()[:pools][:default][:conn_opts][:transport_opts]

      assert transport_opts[:verify] == :verify_peer
    end

    test "pool size, count and protocols follow config, with per-scheduler shards by default" do
      put_emulator(false)
      delete_env_for_test(:gcp_gcs, :finch)
      pool = Config.finch_opts()[:pools]["https://storage.googleapis.com:443"]
      assert pool[:size] == 10
      assert pool[:count] == System.schedulers_online()
      refute Keyword.has_key?(pool, :protocols)

      put_env_for_test(:gcp_gcs, :finch, pool_size: 3, pool_count: 2, protocols: [:http2])
      pool = Config.finch_opts()[:pools]["https://storage.googleapis.com:443"]
      assert {pool[:size], pool[:count], pool[:protocols]} == {3, 2, [:http2]}
    end

    test "the Finch instance name is configurable" do
      put_env_for_test(:gcp_gcs, :finch_name, MyApp.Finch)
      assert Config.finch_opts()[:name] == MyApp.Finch
      assert Config.finch_name() == MyApp.Finch
    end
  end

  describe "emulator guard" do
    import ExUnit.CaptureLog

    test "a non-loopback STORAGE_EMULATOR_HOST is logged as an error" do
      put_system_env_for_test("STORAGE_EMULATOR_HOST", "http://10.1.2.3:4443")

      log = capture_log([level: :warning], fn -> Config.log_emulator_mode() end)
      assert log =~ "[error]"
      assert log =~ "non-loopback host 10.1.2.3:4443"
    end

    test "loopback emulators only warn" do
      for host <- ["http://localhost:4443", "http://127.0.0.5:4443", "http://[::1]:4443"] do
        put_system_env_for_test("STORAGE_EMULATOR_HOST", host)

        log = capture_log([level: :warning], fn -> Config.log_emulator_mode() end)
        assert log =~ "[warning]"
        refute log =~ "[error]"
      end
    end

    test "emulator_env: false ignores STORAGE_EMULATOR_HOST" do
      put_env_for_test(:gcp_gcs, :emulator_env, false)
      put_system_env_for_test("STORAGE_EMULATOR_HOST", "http://10.1.2.3:4443")

      refute Config.emulator?()
      assert Config.base_url() == "https://storage.googleapis.com"
    end
  end
end

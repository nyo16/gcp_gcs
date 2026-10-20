defmodule GcpGcs.AuthTest do
  @moduledoc """
  Token acquisition through a fake `gcloud` executable placed first on `PATH`.

  `async: false` — mutates `PATH`, app env and the shared token cache.
  """
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  alias GcpGcs.{Auth, Error}

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: tmp_dir} do
    delete_env_for_test(:gcp_gcs, :emulator)
    delete_env_for_test(:gcp_gcs, :goth)
    put_system_env_for_test("STORAGE_EMULATOR_HOST", nil)

    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)
    put_system_env_for_test("PATH", bin <> ":" <> System.get_env("PATH", ""))

    Auth.clear_cache()
    on_exit(&Auth.clear_cache/0)

    {:ok, bin: bin}
  end

  # Writes a fake `gcloud` that prints `output` and exits with `status`.
  defp fake_gcloud(bin, output, status \\ 0) do
    path = Path.join(bin, "gcloud")
    File.write!(path, "#!/bin/sh\ncat <<'EOF'\n#{output}\nEOF\nexit #{status}\n")
    File.chmod!(path, 0o755)
  end

  describe "gcloud source" do
    test "returns a bearer token and caches it", %{bin: bin} do
      fake_gcloud(bin, "tok")
      assert {:ok, "Bearer tok"} = Auth.get_token()

      fake_gcloud(bin, "broken", 1)
      assert {:ok, "Bearer tok"} = Auth.get_token()
      assert {:ok, [{"authorization", "Bearer tok"}]} = Auth.request_headers()
    end

    test "a non-zero exit is :unauthenticated with the exit status", %{bin: bin} do
      fake_gcloud(bin, "ERROR: not logged in", 1)

      assert {:error, %Error{code: :unauthenticated, details: {:gcloud_exit, 1}}} =
               Auth.get_token()
    end

    test "a missing gcloud executable is :unauthenticated", %{bin: bin} do
      put_system_env_for_test("PATH", bin)

      assert {:error, %Error{code: :unauthenticated, details: %ErlangError{original: :enoent}}} =
               Auth.get_token()
    end

    test "clear_cache/0 forces a refetch", %{bin: bin} do
      fake_gcloud(bin, "tok1")
      assert {:ok, "Bearer tok1"} = Auth.get_token()

      fake_gcloud(bin, "tok2")
      assert {:ok, "Bearer tok1"} = Auth.get_token()

      assert :ok = GcpGcs.clear_auth_cache()
      assert {:ok, "Bearer tok2"} = Auth.get_token()
    end

    test "warning lines merged from stderr are skipped", %{bin: bin} do
      fake_gcloud(bin, """
      WARNING: Your active project does not match the quota project.
      ya29.token-value_123
      Updates are available for some Google Cloud CLI components.\
      """)

      assert {:ok, "Bearer ya29.token-value_123"} = Auth.get_token()
    end

    test "output without a token-shaped line is an error and is not cached", %{bin: bin} do
      fake_gcloud(bin, "ERROR: (gcloud) something went wrong")

      assert {:error, %Error{code: :unauthenticated, message: "gcloud returned malformed output"}} =
               Auth.get_token()

      fake_gcloud(bin, "tok")
      assert {:ok, "Bearer tok"} = Auth.get_token()
    end
  end

  describe "goth source" do
    test "an unregistered Goth name is :unauthenticated, not a crash", %{bin: bin} do
      # Must not fall back to gcloud when Goth is configured.
      fake_gcloud(bin, "tok")
      put_env_for_test(:gcp_gcs, :goth, GcpGcs.AuthTest.NoSuchGoth)

      assert {:error, %Error{code: :unauthenticated}} = Auth.get_token()
    end
  end

  describe "goth_ttl_ms/1" do
    test "integer expiry is Unix seconds, minus a 60 s margin" do
      expires = System.os_time(:second) + 3600
      ttl = Auth.goth_ttl_ms(%{expires: expires})
      assert ttl in (3_540_000 - 2_000)..3_540_000
    end

    test "DateTime expiry" do
      expires = DateTime.add(DateTime.utc_now(), 600, :second)
      ttl = Auth.goth_ttl_ms(%{expires: expires})
      assert ttl in (540_000 - 2_000)..540_000
    end

    test "an expired token gets a zero TTL" do
      assert Auth.goth_ttl_ms(%{expires: System.os_time(:second) - 10}) == 0
    end

    test "unknown expiry defaults to 50 minutes" do
      assert Auth.goth_ttl_ms(%{expires: nil}) == 50 * 60 * 1000
      assert Auth.goth_ttl_ms(%{}) == 50 * 60 * 1000
    end
  end

  describe "Error.from_transport/1 redaction" do
    test "an invalid header value is reported by name only" do
      mint = %Mint.HTTPError{
        reason: {:invalid_header_value, "authorization", "Bearer s3cret\n"},
        module: Mint.HTTP1
      }

      for reason <- [
            mint,
            %Finch.HTTPError{reason: mint.reason, module: Mint.HTTP1, source: mint}
          ] do
        error = Error.from_transport(reason)

        assert %Error{
                 code: :connection_error,
                 message: "invalid value for header authorization",
                 details: {:invalid_header_value, "authorization"}
               } = error

        refute inspect(error, structs: false) =~ "s3cret"
      end
    end

    test "a bad header value sent through the client never reaches the error" do
      bypass = Bypass.open()
      put_emulator_for_test(bypass.port)
      url = "http://localhost:#{bypass.port}/storage/v1/b/bucket"

      assert {:error, %Error{} = error} =
               GcpGcs.Client.request(:get, url, headers: [{"x-secret", "s3cret\r\nx: y"}])

      assert error.details == {:invalid_header_value, "x-secret"}
      refute inspect(error, structs: false) =~ "s3cret"
    end
  end
end

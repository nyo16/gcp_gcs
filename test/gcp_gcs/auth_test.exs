defmodule GcpGcs.AuthTest do
  @moduledoc """
  Token acquisition through a fake `gcloud` executable placed first on `PATH`,
  and through stub Goth instances.

  `async: false` — mutates `PATH`, app env and the shared token cache.
  """
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  alias GcpGcs.{Auth, Error, FakeResumable, Upload}
  alias GcpGcs.Auth.Cache

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

    {:ok, bin: bin, runs: Path.join(tmp_dir, "runs")}
  end

  # Writes a fake `gcloud` that records each run in `runs`, prints `output`
  # and exits with `status`.
  defp fake_gcloud(bin, output, status \\ 0, delay \\ "0") do
    runs = Path.join(Path.dirname(bin), "runs")
    path = Path.join(bin, "gcloud")

    File.write!(path, """
    #!/bin/sh
    echo run >> '#{runs}'
    sleep #{delay}
    cat <<'EOF'
    #{output}
    EOF
    exit #{status}
    """)

    File.chmod!(path, 0o755)
  end

  defp runs(path) do
    case File.read(path) do
      {:ok, content} -> content |> String.split("\n", trim: true) |> length()
      {:error, :enoent} -> 0
    end
  end

  defp gcloud_json(token, expiry) do
    datetime = expiry |> DateTime.to_naive() |> NaiveDateTime.to_string()
    JSON.encode!(%{"expiry" => %{"datetime" => datetime}, "token" => token})
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

    test "JSON output is parsed, also around warning lines", %{bin: bin} do
      expiry = DateTime.add(DateTime.utc_now(), 3600, :second)
      fake_gcloud(bin, "WARNING: something\n" <> gcloud_json("ya29.json", expiry))

      assert {:ok, "Bearer ya29.json"} = Auth.get_token()
    end

    test "the token is cached according to its real expiry", %{bin: bin, runs: runs} do
      # Expires within the 60 s margin: usable once, never cached.
      fake_gcloud(bin, gcloud_json("short", DateTime.add(DateTime.utc_now(), 30, :second)))

      assert {:ok, "Bearer short"} = Auth.get_token()
      assert {:ok, "Bearer short"} = Auth.get_token()
      assert runs(runs) == 2
    end

    test "output without a token-shaped line is an error, cached briefly", %{
      bin: bin,
      runs: runs
    } do
      fake_gcloud(bin, "ERROR: (gcloud) something went wrong")

      assert {:error, %Error{code: :unauthenticated, message: "gcloud returned malformed output"}} =
               Auth.get_token()

      # The failure is cached (no second gcloud run) and no token is cached.
      fake_gcloud(bin, "tok")
      assert {:error, %Error{code: :unauthenticated}} = Auth.get_token()
      assert runs(runs) == 1

      Auth.clear_cache()
      assert {:ok, "Bearer tok"} = Auth.get_token()
    end

    test "concurrent callers on a cold cache run gcloud once", %{bin: bin, runs: runs} do
      fake_gcloud(bin, "tok", 0, "0.2")

      results =
        1..50
        |> Enum.map(fn _ -> Task.async(fn -> Auth.get_token() end) end)
        |> Task.await_many(10_000)

      assert Enum.uniq(results) == [{:ok, "Bearer tok"}]
      assert runs(runs) == 1
    end

    test "the cache table cannot be written by other processes" do
      assert_raise ArgumentError, fn ->
        :ets.insert(Cache.table(), {:token, {:ok, "Bearer evil"}, :infinity})
      end
    end

    test "gcloud_path selects the executable", %{tmp_dir: tmp_dir, bin: bin} do
      other = Path.join(tmp_dir, "other-gcloud")
      File.write!(other, "#!/bin/sh\necho custom\n")
      File.chmod!(other, 0o755)
      fake_gcloud(bin, "on-path")
      put_env_for_test(:gcp_gcs, :gcloud_path, other)

      assert {:ok, "Bearer custom"} = Auth.get_token()
    end

    test "gcloud_fallback: false never runs gcloud", %{bin: bin, runs: runs} do
      fake_gcloud(bin, "tok")
      put_env_for_test(:gcp_gcs, :gcloud_fallback, false)

      assert {:error, %Error{code: :unauthenticated}} = Auth.get_token()
      assert runs(runs) == 0
    end
  end

  describe "goth source" do
    # A Goth instance whose metadata-server token request is answered locally.
    defp start_goth(name, token) do
      http_client = fn _request ->
        body =
          JSON.encode!(%{"access_token" => token, "token_type" => "Bearer", "expires_in" => 3600})

        {:ok, %{status: 200, headers: [], body: body}}
      end

      start_supervised!(
        Supervisor.child_spec(
          {Goth, name: name, source: {:metadata, []}, http_client: http_client, prefetch: :sync},
          id: name
        )
      )
    end

    test "an unregistered Goth name is :unauthenticated, not a crash", %{bin: bin, runs: runs} do
      # Must not fall back to gcloud when Goth is configured.
      fake_gcloud(bin, "tok")
      put_env_for_test(:gcp_gcs, :goth, :gcp_gcs_test_no_such_goth)

      assert {:error, %Error{code: :unauthenticated}} = Auth.get_token()
      assert runs(runs) == 0
    end

    test "per-call :goth names use their own tokens" do
      start_goth(:gcp_gcs_test_goth_a, "token-a")
      start_goth(:gcp_gcs_test_goth_b, "token-b")
      put_env_for_test(:gcp_gcs, :goth, :gcp_gcs_test_goth_a)

      assert {:ok, "Bearer token-a"} = Auth.get_token()
      assert {:ok, "Bearer token-b"} = Auth.get_token(goth: :gcp_gcs_test_goth_b)
      assert {:ok, "Bearer token-a"} = Auth.get_token()
    end
  end

  describe "expiry_ttl_ms/1" do
    test "integer expiry is Unix seconds, minus a 60 s margin" do
      ttl = Auth.expiry_ttl_ms(System.os_time(:second) + 3600)
      assert ttl in (3_540_000 - 2_000)..3_540_000
    end

    test "DateTime expiry" do
      ttl = Auth.expiry_ttl_ms(DateTime.add(DateTime.utc_now(), 600, :second))
      assert ttl in (540_000 - 2_000)..540_000
    end

    test "an expired token gets a zero TTL" do
      assert Auth.expiry_ttl_ms(System.os_time(:second) - 10) == 0
    end

    test "unknown expiry defaults to 50 minutes" do
      assert Auth.expiry_ttl_ms(nil) == 50 * 60 * 1000
    end
  end

  describe "authenticated requests against a per-call :base_url" do
    setup %{bin: bin} do
      fake_gcloud(bin, "tok")
      bypass = Bypass.open()
      {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
    end

    test "the initiation POST is authenticated, session PUTs are not", %{
      bypass: bypass,
      base_url: base_url,
      tmp_dir: tmp_dir
    } do
      server = FakeResumable.start(bypass)
      path = Path.join(tmp_dir, "payload.bin")
      File.write!(path, :crypto.strong_rand_bytes(300_000))

      assert {:ok, _} =
               Upload.upload_file("test-bucket", "a.bin", path,
                 base_url: base_url,
                 chunk_size: 262_144
               )

      other = Bypass.open()
      other_url = "http://localhost:#{other.port}"
      other_server = FakeResumable.start(other)

      {:ok, session} = Upload.start_resumable_upload("test-bucket", "b.bin", base_url: other_url)

      assert {:ok, _} =
               Upload.upload_chunk(session, "abc", offset: 0, total: 3, base_url: other_url)

      posts = FakeResumable.posts(server) ++ FakeResumable.posts(other_server)
      assert [_, _] = posts
      assert Enum.all?(posts, &({"authorization", "Bearer tok"} in &1))

      puts = FakeResumable.puts(server) ++ FakeResumable.puts(other_server)
      assert [_, _, _] = puts
      assert Enum.all?(puts, &(List.keyfind(&1.headers, "authorization", 0) == nil))
    end

    test "a 401 refetches the token once and retries", %{
      bypass: bypass,
      base_url: base_url,
      bin: bin,
      runs: runs
    } do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/storage/v1/b/bucket", fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:auth, auth})

        case auth do
          "Bearer tok" -> Plug.Conn.resp(conn, 401, "")
          "Bearer fresh" -> Plug.Conn.resp(conn, 200, ~s({"name":"bucket"}))
        end
      end)

      assert {:ok, "Bearer tok"} = Auth.get_token()
      fake_gcloud(bin, "fresh")

      assert {:ok, %{"name" => "bucket"}} = GcpGcs.get_bucket("bucket", base_url: base_url)
      assert_received {:auth, "Bearer tok"}
      assert_received {:auth, "Bearer fresh"}
      assert runs(runs) == 2
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

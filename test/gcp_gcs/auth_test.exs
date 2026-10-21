defmodule GcpGcs.AuthTest do
  @moduledoc """
  Token acquisition through a fake `gcloud` executable placed first on `PATH`,
  and through stub Goth instances.

  `async: false` — mutates `PATH`, app env and the shared token cache.
  """
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  alias GcpGcs.{Auth, Error, FakeResumable, FakeServer, Upload}
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
    echo run >> #{sh_quote(runs)}
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

  # A single-quoted shell word (test names, and so tmp_dir paths, may contain `'`).
  defp sh_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  # Polls `fun` until it returns true (up to ~5 s).
  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met within 5 s")
      true -> Process.sleep(50) && wait_until(fun, attempts - 1)
    end
  end

  defp read_pid!(file) do
    wait_until(fn -> match?({:ok, <<_, _::binary>>}, File.read(file)) end)
    file |> File.read!() |> String.trim()
  end

  # `kill -0` fails once the process is gone (and reaped).
  defp os_alive?(os_pid),
    do: elem(System.cmd("/bin/kill", ["-0", os_pid], stderr_to_stdout: true), 1) == 0

  defp collect_traces(acc) do
    receive do
      {:trace, _pid, :receive, message} -> collect_traces([message | acc])
    after
      100 -> Enum.reverse(acc)
    end
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

    test "waiters for a running fetch are held in state, not in the mailbox", %{
      bin: bin,
      runs: runs
    } do
      fake_gcloud(bin, "tok", 0, "3")
      cache = Process.whereis(Cache)
      t0 = System.monotonic_time(:millisecond)
      callers = for _ <- 1..500, do: Task.async(fn -> Auth.get_token() end)

      # Every caller is parked in the cache's state while gcloud runs ...
      wait_until(fn -> waiter_count(cache) == 500 end)

      # ... and the cache keeps its mailbox drained meanwhile.
      for _ <- 1..5 do
        assert {:message_queue_len, len} = Process.info(cache, :message_queue_len)
        assert len <= 1
        elapsed = System.monotonic_time(:millisecond) - t0
        assert waiter_count(cache) == 500, "fetch already answered after #{elapsed} ms"
        Process.sleep(50)
      end

      assert Enum.uniq(Task.await_many(callers, 10_000)) == [{:ok, "Bearer tok"}]
      assert runs(runs) == 1
    end

    defp waiter_count(cache) do
      cache
      |> :sys.get_state()
      |> Map.fetch!(:fetches)
      |> Map.values()
      |> Enum.map(&length(&1.waiters))
      |> Enum.sum()
    end

    test "a crashing fetch answers every waiter with :unauthenticated, cached briefly" do
      calls = :counters.new(1, [])

      crash = fn ->
        :counters.add(calls, 1, 1)
        Process.sleep(200)
        raise "boom"
      end

      results =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> Cache.fetch(crash) end) end)
        |> Task.await_many(5_000)

      assert Enum.all?(results, &match?({:error, %Error{code: :unauthenticated}}, &1))
      assert :counters.get(calls, 1) == 1

      assert {:error, %Error{code: :unauthenticated}} =
               Cache.fetch(fn -> {:ok, "Bearer x", 60_000} end)
    end

    test "a fetch past the cache's own deadline is stopped and answered", %{bin: bin} do
      put_env_for_test(:gcp_gcs, :gcloud_timeout, 100)
      test_pid = self()

      hang = fn ->
        send(test_pid, {:fetch_task, self()})
        Process.sleep(:infinity)
      end

      assert {:error, %Error{code: :unauthenticated, message: "access token fetch timed out"}} =
               Cache.fetch(hang)

      assert_received {:fetch_task, task}
      refute Process.alive?(task)

      # Negative-cached like any failure; a clear lets the next fetch run.
      put_env_for_test(:gcp_gcs, :gcloud_timeout, 30_000)
      fake_gcloud(bin, "tok")
      assert {:error, %Error{}} = Auth.get_token()
      GcpGcs.clear_auth_cache()
      assert {:ok, "Bearer tok"} = Auth.get_token()
    end

    test "clearing during a slow fetch returns at once; later callers get fresh credentials", %{
      bin: bin,
      runs: runs,
      tmp_dir: tmp_dir
    } do
      fake_gcloud(bin, "old", 0, "2")
      before_clear = Task.async(fn -> Auth.get_token() end)
      wait_until(fn -> runs(runs) == 1 end)

      # Switch credentials (a different gcloud), then clear.
      fresh = Path.join(tmp_dir, "fresh-gcloud")
      File.write!(fresh, "#!/bin/sh\necho run >> #{sh_quote(runs)}\necho new\n")
      File.chmod!(fresh, 0o755)
      put_env_for_test(:gcp_gcs, :gcloud_path, fresh)

      {us, :ok} = :timer.tc(&GcpGcs.clear_auth_cache/0)
      assert us < 1_000_000

      # A caller after the clear doesn't join the old fetch.
      assert {:ok, "Bearer new"} = Auth.get_token()
      # The old fetch still answers its own caller, but isn't cached.
      assert {:ok, "Bearer old"} = Task.await(before_clear, 10_000)
      assert {:ok, "Bearer new"} = Auth.get_token()
      assert runs(runs) == 2
    end

    test "a gcloud run past :gcloud_timeout is killed with its children and fails fast", %{
      bin: bin,
      tmp_dir: tmp_dir
    } do
      sh_pid = Path.join(tmp_dir, "sh.pid")
      child_pid = Path.join(tmp_dir, "child.pid")
      path = Path.join(bin, "gcloud")

      # Absolute paths: PATH holds only `bin`, so no `kill` executable either.
      File.write!(path, """
      #!/bin/sh
      echo $$ > #{sh_quote(sh_pid)}
      /bin/sleep 10 &
      echo $! > #{sh_quote(child_pid)}
      wait
      echo tok
      """)

      File.chmod!(path, 0o755)
      put_system_env_for_test("PATH", bin)
      # Long enough for the script to start (and record its pids) under load.
      put_env_for_test(:gcp_gcs, :gcloud_timeout, 1_000)

      {us, results} =
        :timer.tc(fn ->
          1..5
          |> Enum.map(fn _ -> Task.async(fn -> Auth.get_token() end) end)
          |> Task.await_many(10_000)
        end)

      assert Enum.all?(results, &match?({:error, %Error{details: :gcloud_timeout}}, &1))
      # Well before the script's own 10 s.
      assert us < 5_000_000

      # The failure is cached briefly.
      assert {:error, %Error{details: :gcloud_timeout}} = Auth.get_token()

      # Neither the script nor its child outlives the deadline.
      for file <- [sh_pid, child_pid] do
        os_pid = read_pid!(file)
        wait_until(fn -> not os_alive?(os_pid) end)
      end

      GcpGcs.clear_auth_cache()
      # Shell builtins only: PATH is just `bin`.
      File.write!(path, "#!/bin/sh\necho tok\n")
      assert {:ok, "Bearer tok"} = Auth.get_token()
    end

    test "stopping the fetch supervisor kills a running gcloud", %{bin: bin, tmp_dir: tmp_dir} do
      pid_file = Path.join(tmp_dir, "gcloud.pid")
      path = Path.join(bin, "gcloud")
      File.write!(path, "#!/bin/sh\necho $$ > #{sh_quote(pid_file)}\nsleep 10\necho tok\n")
      File.chmod!(path, 0o755)

      caller = Task.async(fn -> Auth.get_token() end)
      wait_until(fn -> File.exists?(pid_file) and File.read!(pid_file) != "" end)
      os_pid = read_pid!(pid_file)

      :ok = Supervisor.terminate_child(GcpGcs.Supervisor, GcpGcs.TaskSupervisor)

      on_exit(fn ->
        {:ok, _} = Supervisor.restart_child(GcpGcs.Supervisor, GcpGcs.TaskSupervisor)
      end)

      assert {:error, %Error{code: :unauthenticated}} = Task.await(caller, 5_000)
      wait_until(fn -> not os_alive?(os_pid) end)
    end

    test "with the cache process down, tokens are fetched uncached and clearing is a no-op", %{
      bin: bin,
      runs: runs
    } do
      fake_gcloud(bin, "tok")
      :ok = Supervisor.terminate_child(GcpGcs.Supervisor, Cache)
      on_exit(fn -> {:ok, _} = Supervisor.restart_child(GcpGcs.Supervisor, Cache) end)

      assert :ok = GcpGcs.clear_auth_cache()
      assert {:ok, "Bearer tok"} = Auth.get_token()
      assert {:ok, "Bearer tok"} = Auth.get_token()
      assert runs(runs) == 2
    end

    test "a fetch that can't start fails fast instead of crashing the cache", %{bin: bin} do
      fake_gcloud(bin, "tok")
      cache = Process.whereis(Cache)
      :ok = Supervisor.terminate_child(GcpGcs.Supervisor, GcpGcs.TaskSupervisor)

      on_exit(fn ->
        {:ok, _} = Supervisor.restart_child(GcpGcs.Supervisor, GcpGcs.TaskSupervisor)
      end)

      assert {:error,
              %Error{code: :unauthenticated, message: "access token fetch could not start"}} =
               Auth.get_token()

      assert Process.whereis(Cache) == cache
    end

    test "a caller whose cache dies mid-wait gets :unauthenticated, not an exit", %{bin: bin} do
      fake_gcloud(bin, "tok", 0, "2")
      cache = Process.whereis(Cache)
      caller = Task.async(fn -> Auth.get_token() end)
      wait_until(fn -> waiter_count(cache) == 1 end)

      Process.exit(cache, :kill)

      assert {:error, %Error{code: :unauthenticated, message: "access token cache unavailable"}} =
               Task.await(caller, 5_000)

      # The supervisor brings a fresh cache back.
      wait_until(fn -> Process.whereis(Cache) not in [nil, cache] end)
    end

    test "stray messages don't take the cache down", %{bin: bin} do
      fake_gcloud(bin, "tok")
      assert {:ok, "Bearer tok"} = Auth.get_token()
      cache = Process.whereis(Cache)

      send(cache, :junk)
      send(cache, {make_ref(), :late_reply})
      send(cache, {:DOWN, make_ref(), :process, self(), :normal})
      _ = :sys.get_state(cache)

      assert Process.whereis(Cache) == cache
      assert [{:token, {:ok, "Bearer tok"}, _, _}] = :ets.lookup(Cache.table(), :token)
    end

    test "a bare gcloud name is never run from the working directory", %{
      tmp_dir: tmp_dir,
      bin: bin
    } do
      cwd = Path.join(tmp_dir, "cwd")
      File.mkdir_p!(cwd)
      local = Path.join(cwd, "gcloud")
      File.write!(local, "#!/bin/sh\necho local\n")
      File.chmod!(local, 0o755)
      put_system_env_for_test("PATH", bin)

      # Sync test module: no async test runs while the cwd is changed.
      result = File.cd!(cwd, fn -> Auth.get_token() end)

      assert {:error, %Error{code: :unauthenticated, details: %ErlangError{original: :enoent}}} =
               result
    end

    test "the rejected token itself never reaches the cache process", %{bin: bin} do
      fake_gcloud(bin, "tok")
      assert {:ok, "Bearer tok"} = Auth.get_token()
      fake_gcloud(bin, "fresh")

      cache = Process.whereis(Cache)
      :erlang.trace(cache, true, [:receive, {:tracer, self()}])
      on_exit(fn -> :erlang.trace(cache, false, [:receive]) end)

      assert {:ok, "Bearer fresh"} = Auth.get_token([], "Bearer tok")
      :erlang.trace(cache, false, [:receive])

      received = collect_traces([])
      assert Enum.any?(received, &match?({:"$gen_call", _, {:fetch, _, _}}, &1))

      refute Enum.any?(
               received,
               &(:binary.match(:erlang.term_to_binary(&1), "Bearer tok") != :nomatch)
             )
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

    test "a failing Goth source is :unauthenticated and never falls back to gcloud", %{
      bin: bin,
      runs: runs
    } do
      fake_gcloud(bin, "tok")
      failing = fn _request -> {:ok, %{status: 500, headers: [], body: "{}"}} end

      start_supervised!(
        Supervisor.child_spec(
          {Goth,
           name: :gcp_gcs_test_goth_failing,
           source: {:metadata, []},
           http_client: failing,
           prefetch: :async,
           max_retries: 0},
          id: :gcp_gcs_test_goth_failing
        )
      )

      assert {:error, %Error{code: :unauthenticated}} =
               Auth.get_token(goth: :gcp_gcs_test_goth_failing)

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

  describe "auth telemetry" do
    setup do
      id = {__MODULE__, make_ref()}
      test_pid = self()

      :ok =
        :telemetry.attach(
          id,
          [:gcp_gcs, :auth, :stop],
          fn _event, _measurements, metadata, _config ->
            send(test_pid, {:auth_stop, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "is emitted only when gcloud actually runs", %{bin: bin} do
      fake_gcloud(bin, "tok")

      assert {:ok, "Bearer tok"} = Auth.get_token()
      assert {:ok, "Bearer tok"} = Auth.get_token()

      assert_receive {:auth_stop, %{source: :gcloud, result: :ok}}, 1_000
      refute_received {:auth_stop, _}
    end

    test "is not emitted for Goth token reads" do
      start_goth(:gcp_gcs_test_goth_telemetry, "goth-token")
      put_env_for_test(:gcp_gcs, :goth, :gcp_gcs_test_goth_telemetry)

      for _ <- 1..10, do: assert({:ok, "Bearer goth-token"} = Auth.get_token())
      refute_received {:auth_stop, _}
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
      fake = FakeServer.open()
      {:ok, fake: fake, base_url: "http://localhost:#{fake.port}"}
    end

    test "no request is sent when no credentials are available", %{base_url: base_url} do
      # The fake server has no expectations: any request fails the test.
      put_env_for_test(:gcp_gcs, :gcloud_fallback, false)

      assert {:error, %Error{code: :unauthenticated}} =
               GcpGcs.get_bucket("bucket", base_url: base_url)
    end

    test "the initiation POST is authenticated, session PUTs are not", %{
      fake: fake,
      base_url: base_url,
      tmp_dir: tmp_dir
    } do
      server = FakeResumable.start(fake)
      path = Path.join(tmp_dir, "payload.bin")
      File.write!(path, :crypto.strong_rand_bytes(300_000))

      assert {:ok, _} =
               Upload.upload_file("test-bucket", "a.bin", path,
                 base_url: base_url,
                 chunk_size: 262_144
               )

      other = FakeServer.open()
      other_url = "http://localhost:#{other.port}"
      other_server = FakeResumable.start(other)

      {:ok, session} = Upload.start_resumable_upload("test-bucket", "b.bin", base_url: other_url)

      assert {:ok, _} =
               Upload.upload_chunk(session, "abc", offset: 0, total: 3, base_url: other_url)

      posts = FakeResumable.posts(server) ++ FakeResumable.posts(other_server)
      assert [_, _] = posts
      assert Enum.all?(posts, &({"authorization", "Bearer tok"} in &1.headers))

      puts = FakeResumable.puts(server) ++ FakeResumable.puts(other_server)
      assert [_, _, _] = puts
      assert Enum.all?(puts, &(List.keyfind(&1.headers, "authorization", 0) == nil))
    end

    test "a 401 refetches the token once and retries", %{
      fake: fake,
      base_url: base_url,
      bin: bin,
      runs: runs
    } do
      test_pid = self()

      FakeServer.expect(fake, "GET", "/storage/v1/b/bucket", fn conn ->
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

    test "a second 401 is returned, after a single refetch", %{
      fake: fake,
      base_url: base_url,
      bin: bin,
      runs: runs
    } do
      calls = :counters.new(1, [])

      FakeServer.expect(fake, "GET", "/storage/v1/b/bucket", fn conn ->
        :counters.add(calls, 1, 1)
        Plug.Conn.resp(conn, 401, "")
      end)

      assert {:ok, "Bearer tok"} = Auth.get_token()
      fake_gcloud(bin, "fresh")

      assert {:error, %Error{code: :unauthenticated, status: 401}} =
               GcpGcs.get_bucket("bucket", base_url: base_url)

      assert :counters.get(calls, 1) == 2
      assert runs(runs) == 2
    end

    test "a 401 to an unauthenticated (emulator) request is not retried", %{
      fake: fake,
      runs: runs
    } do
      put_emulator_for_test(fake.port)

      FakeServer.expect_once(fake, "GET", "/storage/v1/b/bucket", fn conn ->
        assert [] = Plug.Conn.get_req_header(conn, "authorization")
        Plug.Conn.resp(conn, 401, "")
      end)

      assert {:error, %Error{code: :unauthenticated}} = GcpGcs.get_bucket("bucket")
      assert runs(runs) == 0
    end

    test "concurrent 401s replace the rejected token once", %{
      fake: fake,
      base_url: base_url,
      bin: bin,
      runs: runs
    } do
      rejected = :counters.new(1, [])

      FakeServer.expect(fake, "GET", "/storage/v1/b/bucket", fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer tok"] ->
            :counters.add(rejected, 1, 1)
            Plug.Conn.resp(conn, 401, "")

          ["Bearer fresh"] ->
            Plug.Conn.resp(conn, 200, ~s({"name":"bucket"}))
        end
      end)

      assert {:ok, "Bearer tok"} = Auth.get_token()
      fake_gcloud(bin, "fresh", 0, "0.2")

      results =
        1..20
        |> Enum.map(fn _ ->
          Task.async(fn -> GcpGcs.get_bucket("bucket", base_url: base_url) end)
        end)
        |> Task.await_many(10_000)

      assert Enum.uniq(results) == [{:ok, %{"name" => "bucket"}}]
      # Several requests were rejected, yet the token was refetched once.
      assert :counters.get(rejected, 1) >= 2
      assert runs(runs) == 2
    end

    test "retries after the re-authenticated attempt don't refetch the token again", %{
      fake: fake,
      base_url: base_url,
      runs: runs
    } do
      # gcloud keeps returning the same token; the request is answered 401,
      # then 503, then 200.
      calls = :counters.new(1, [])

      FakeServer.expect(fake, "GET", "/storage/v1/b/bucket", fn conn ->
        :counters.add(calls, 1, 1)

        case :counters.get(calls, 1) do
          1 -> Plug.Conn.resp(conn, 401, "")
          2 -> Plug.Conn.resp(conn, 503, "")
          _ -> Plug.Conn.resp(conn, 200, ~s({"name":"bucket"}))
        end
      end)

      assert {:ok, "Bearer tok"} = Auth.get_token()
      assert {:ok, %{"name" => "bucket"}} = GcpGcs.get_bucket("bucket", base_url: base_url)
      assert :counters.get(calls, 1) == 3
      # The initial fetch and one refetch after the 401, none for the 503 retry.
      assert runs(runs) == 2
    end

    test "with Goth, a 401 is retried once and the gcloud token cache is left alone", %{
      fake: fake,
      base_url: base_url,
      runs: runs
    } do
      start_goth(:gcp_gcs_test_goth_401, "goth-token")
      calls = :counters.new(1, [])

      FakeServer.expect(fake, "GET", "/storage/v1/b/bucket", fn conn ->
        assert ["Bearer " <> _] = Plug.Conn.get_req_header(conn, "authorization")
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1,
          do: Plug.Conn.resp(conn, 401, ""),
          else: Plug.Conn.resp(conn, 200, ~s({"name":"bucket"}))
      end)

      assert {:ok, "Bearer tok"} = Auth.get_token()
      cached = :ets.lookup(Cache.table(), :token)

      assert {:ok, %{"name" => "bucket"}} =
               GcpGcs.get_bucket("bucket", base_url: base_url, goth: :gcp_gcs_test_goth_401)

      assert :counters.get(calls, 1) == 2
      assert :ets.lookup(Cache.table(), :token) == cached
      assert runs(runs) == 1
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
      fake = FakeServer.open()
      put_emulator_for_test(fake.port)
      url = "http://localhost:#{fake.port}/storage/v1/b/bucket"

      assert {:error, %Error{} = error} =
               GcpGcs.Client.request(:get, url, headers: [{"x-secret", "s3cret\r\nx: y"}])

      assert error.details == {:invalid_header_value, "x-secret"}
      refute inspect(error, structs: false) =~ "s3cret"
    end
  end
end

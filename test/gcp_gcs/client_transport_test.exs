defmodule GcpGcs.ClientTransportTest do
  @moduledoc """
  Exercises `GcpGcs.Client` through the real Finch/Mint transport against a
  local fake HTTP server (`GcpGcs.FakeServer`).

  `async: false` — the tests point the global emulator endpoint at the fake server.
  """
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  alias GcpGcs.{Client, Config, FakeServer}

  setup do
    fake = FakeServer.open()
    put_emulator_for_test(fake.port)
    {:ok, fake: fake, url: "http://localhost:#{fake.port}/storage/v1/b/bucket"}
  end

  # Blocks the fake server's handler until the test sends `:release`, without
  # sleeping. The client gives up on the connection first, so the handler's
  # response goes nowhere; `FakeServer.pass/1` keeps that from failing the
  # test, which asserts the observable results itself.
  defp blocking_handler(fake, test_pid) do
    fn conn ->
      FakeServer.pass(fake)
      send(test_pid, {:blocked, self()})

      receive do
        :release -> Plug.Conn.resp(conn, 200, "{}")
      end
    end
  end

  describe "receive timeout" do
    test "a timed-out request leaves the pool usable for the next one", %{
      fake: fake,
      url: url
    } do
      test_pid = self()
      counter = :counters.new(1, [])

      FakeServer.expect(fake, "GET", "/storage/v1/b/bucket", fn conn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 -> blocking_handler(fake, test_pid).(conn)
          _ -> Plug.Conn.resp(conn, 200, ~s({"name":"bucket"}))
        end
      end)

      assert {:error, %GcpGcs.Error{code: :connection_error, details: details}} =
               Client.request(:get, url, timeout: 50, retry: false)

      assert %Finch.TransportError{reason: :timeout} = details

      assert_receive {:blocked, handler}
      send(handler, :release)

      assert {:ok, %{"name" => "bucket"}} = Client.request(:get, url)
      assert Config.finch_name() |> Process.whereis() |> Process.alive?()
    end
  end

  describe "pool checkout timeout" do
    test "an exhausted pool returns :resource_exhausted instead of raising", %{
      fake: fake,
      url: url
    } do
      finch = :"#{__MODULE__}.Finch"
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1, count: 1]}})
      test_pid = self()

      FakeServer.expect_once(fake, "GET", "/storage/v1/b/bucket", fn conn ->
        send(test_pid, {:blocked, self()})

        receive do
          :release -> Plug.Conn.resp(conn, 200, "{}")
        end
      end)

      holder = Task.async(fn -> Client.request(:get, url, finch: finch) end)
      assert_receive {:blocked, handler}

      assert {:error, %GcpGcs.Error{code: :resource_exhausted}} =
               Client.request(:get, url, finch: finch, pool_timeout: 50)

      send(handler, :release)
      assert {:ok, %{}} = Task.await(holder)
    end
  end

  describe "HTTP error mapping" do
    test "a 503 with a non-JSON body is :unavailable with a generic message", %{
      fake: fake,
      url: url
    } do
      FakeServer.expect_once(fake, "GET", "/storage/v1/b/bucket", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(503, "<html>Service Unavailable</html>")
      end)

      assert {:error, %GcpGcs.Error{code: :unavailable, status: 503, message: "HTTP 503"}} =
               Client.request(:get, url, retry: false)
    end

    test "a 429 is :resource_exhausted", %{fake: fake, url: url} do
      FakeServer.expect_once(fake, "GET", "/storage/v1/b/bucket", fn conn ->
        Plug.Conn.resp(conn, 429, ~s({"error":{"code":429,"message":"rate limited"}}))
      end)

      assert {:error, %GcpGcs.Error{code: :resource_exhausted, message: "rate limited"}} =
               Client.request(:get, url, retry: false)
    end
  end

  describe "connection refused" do
    test "request/3 and stream/5 return :connection_error", %{fake: fake, url: url} do
      FakeServer.down(fake)

      assert {:error, %GcpGcs.Error{code: :connection_error}} = Client.request(:get, url)

      assert {:error, %GcpGcs.Error{code: :connection_error}} =
               Client.stream(:get, url, [], nil, fn _, acc -> acc end)
    end
  end

  describe "retries" do
    # Counts calls and answers with `responses` in order (the last one repeats).
    defp scripted(fake, method, responses) do
      counter = :counters.new(1, [])

      FakeServer.expect(fake, method, "/storage/v1/b/bucket", fn conn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        {status, headers, body} = Enum.at(responses, n - 1, List.last(responses))

        headers
        |> Enum.reduce(conn, fn {k, v}, conn -> Plug.Conn.put_resp_header(conn, k, v) end)
        |> Plug.Conn.resp(status, body)
      end)

      counter
    end

    test "a GET is retried after a 503", %{fake: fake, url: url} do
      calls = scripted(fake, "GET", [{503, [], ""}, {200, [], ~s({"name":"bucket"})}])

      assert {:ok, %{"name" => "bucket"}} = Client.request(:get, url, retry: [base_delay: 0])
      assert :counters.get(calls, 1) == 2
    end

    test "a 429 with Retry-After: 0 is retried", %{fake: fake, url: url} do
      calls = scripted(fake, "GET", [{429, [{"retry-after", "0"}], ""}, {200, [], "{}"}])

      assert {:ok, %{}} = Client.request(:get, url)
      assert :counters.get(calls, 1) == 2
    end

    test "a non-idempotent POST is not retried", %{fake: fake, url: url} do
      calls = scripted(fake, "POST", [{503, [], ""}, {200, [], "{}"}])

      assert {:error, %GcpGcs.Error{code: :unavailable}} =
               Client.request(:post, url, retry: [base_delay: 0])

      assert :counters.get(calls, 1) == 1
    end

    test "a POST marked idempotent is retried", %{fake: fake, url: url} do
      calls = scripted(fake, "POST", [{503, [], ""}, {200, [], "{}"}])

      assert {:ok, %{}} = Client.request(:post, url, idempotent: true, retry: [base_delay: 0])
      assert :counters.get(calls, 1) == 2
    end

    test "exhausting max_attempts returns the last error", %{fake: fake, url: url} do
      calls =
        scripted(fake, "GET", [
          {503, [], ""},
          {500, [], ""},
          {502, [], ~s({"error":{"message":"last"}})}
        ])

      assert {:error, %GcpGcs.Error{status: 502, message: "last"}} =
               Client.request(:get, url, retry: [max_attempts: 3, base_delay: 0])

      assert :counters.get(calls, 1) == 3
    end

    test "retry: false disables retries", %{fake: fake, url: url} do
      calls = scripted(fake, "GET", [{503, [], ""}, {200, [], "{}"}])

      assert {:error, %GcpGcs.Error{code: :unavailable}} = Client.request(:get, url, retry: false)
      assert :counters.get(calls, 1) == 1
    end

    test "a streamed GET is retried before the reducer sees anything", %{fake: fake, url: url} do
      calls = scripted(fake, "GET", [{503, [], "busy"}, {200, [], "payload"}])

      reducer = fn
        {:data, data}, acc -> acc <> data
        _other, acc -> acc
      end

      assert {:ok, {200, _headers, "payload"}} =
               Client.stream(:get, url, [retry: [base_delay: 0]], "", reducer)

      assert :counters.get(calls, 1) == 2
    end
  end
end

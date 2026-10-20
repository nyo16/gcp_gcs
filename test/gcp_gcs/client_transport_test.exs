defmodule GcpGcs.ClientTransportTest do
  @moduledoc """
  Exercises `GcpGcs.Client` through the real Finch/Mint transport against a
  local `Bypass` server.

  `async: false` — the tests point the global emulator endpoint at Bypass.
  """
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  alias GcpGcs.{Client, Config}

  setup do
    bypass = Bypass.open()
    put_emulator_for_test(bypass.port)
    {:ok, bypass: bypass, url: "http://localhost:#{bypass.port}/storage/v1/b/bucket"}
  end

  # Blocks the Bypass handler until the test sends `:release`, without sleeping.
  # The client aborts the connection on timeout, so cowboy shuts the handler
  # down; `Bypass.pass/1` keeps that expected exit from failing the test, which
  # asserts the observable results itself.
  defp blocking_handler(bypass, test_pid) do
    fn conn ->
      Bypass.pass(bypass)
      send(test_pid, {:blocked, self()})

      receive do
        :release -> Plug.Conn.resp(conn, 200, "{}")
      end
    end
  end

  describe "receive timeout" do
    test "a timed-out request leaves the pool usable for the next one", %{
      bypass: bypass,
      url: url
    } do
      test_pid = self()
      counter = :counters.new(1, [])

      Bypass.expect(bypass, "GET", "/storage/v1/b/bucket", fn conn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 -> blocking_handler(bypass, test_pid).(conn)
          _ -> Plug.Conn.resp(conn, 200, ~s({"name":"bucket"}))
        end
      end)

      assert {:error, %GcpGcs.Error{code: :connection_error, details: details}} =
               Client.request(:get, url, timeout: 50)

      assert %Finch.TransportError{reason: :timeout} = details

      assert_receive {:blocked, handler}
      send(handler, :release)

      assert {:ok, %{"name" => "bucket"}} = Client.request(:get, url)
      assert Config.finch_name() |> Process.whereis() |> Process.alive?()
    end
  end

  describe "pool checkout timeout" do
    test "an exhausted pool returns :resource_exhausted instead of raising", %{
      bypass: bypass,
      url: url
    } do
      finch = :"#{__MODULE__}.Finch"
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1, count: 1]}})
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/storage/v1/b/bucket", fn conn ->
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
      bypass: bypass,
      url: url
    } do
      Bypass.expect_once(bypass, "GET", "/storage/v1/b/bucket", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(503, "<html>Service Unavailable</html>")
      end)

      assert {:error, %GcpGcs.Error{code: :unavailable, status: 503, message: "HTTP 503"}} =
               Client.request(:get, url)
    end

    test "a 429 is :resource_exhausted", %{bypass: bypass, url: url} do
      Bypass.expect_once(bypass, "GET", "/storage/v1/b/bucket", fn conn ->
        Plug.Conn.resp(conn, 429, ~s({"error":{"code":429,"message":"rate limited"}}))
      end)

      assert {:error, %GcpGcs.Error{code: :resource_exhausted, message: "rate limited"}} =
               Client.request(:get, url)
    end
  end

  describe "connection refused" do
    test "request/3 and stream/5 return :connection_error", %{bypass: bypass, url: url} do
      Bypass.down(bypass)

      assert {:error, %GcpGcs.Error{code: :connection_error}} = Client.request(:get, url)

      assert {:error, %GcpGcs.Error{code: :connection_error}} =
               Client.stream(:get, url, [], nil, fn _, acc -> acc end)
    end
  end
end

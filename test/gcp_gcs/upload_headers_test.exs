defmodule GcpGcs.UploadHeadersTest do
  @moduledoc """
  Guards the exact headers sent on the resumable-upload flow, where real GCS is
  stricter than the `fake-gcs-server` emulator used by the integration tests:

    * `Content-Length` — real GCS rejects both requests with `411 Length
      Required` if they carry none (the bodyless session-initiation POST, and
      the session PUT whose stream body Mint would otherwise send as
      `transfer-encoding: chunked`).
    * `Origin` — GCS only returns CORS headers on requests to a session URI if
      the session-initiation POST carried an `Origin`; without it a browser
      PUT to the session succeeds server-side but the browser blocks reading
      the response, failing the upload client-side.

  The emulator enforces neither, so these assertions run against a local
  `Bypass` server that captures the exact headers sent.

  `async: false` — the tests point the global emulator endpoint at Bypass.
  """
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  alias GcpGcs.Upload

  @bucket "test-bucket"

  setup do
    bypass = Bypass.open()
    put_emulator_for_test(bypass.port)
    {:ok, bypass: bypass}
  end

  test "session-initiation POST sends Content-Length: 0 when it has no body", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/upload/storage/v1/b/#{@bucket}/o", fn conn ->
      send(test_pid, {:req_headers, conn.req_headers})

      conn
      |> Plug.Conn.put_resp_header("location", session_uri(bypass))
      |> Plug.Conn.resp(200, "")
    end)

    assert {:ok, _uri} = Upload.start_resumable_upload(@bucket, "object.txt")

    assert_receive {:req_headers, headers}
    assert {"content-length", "0"} in headers
  end

  test "session-initiation POST forwards :origin as the Origin header", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/upload/storage/v1/b/#{@bucket}/o", fn conn ->
      send(test_pid, {:req_headers, conn.req_headers})

      conn
      |> Plug.Conn.put_resp_header("location", session_uri(bypass))
      |> Plug.Conn.resp(200, "")
    end)

    assert {:ok, _uri} =
             Upload.start_resumable_upload(@bucket, "object.txt",
               origin: "https://app.example.com"
             )

    assert_receive {:req_headers, headers}
    assert {"origin", "https://app.example.com"} in headers
  end

  test "session-initiation POST sends no Origin header when :origin is absent", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/upload/storage/v1/b/#{@bucket}/o", fn conn ->
      send(test_pid, {:req_headers, conn.req_headers})

      conn
      |> Plug.Conn.put_resp_header("location", session_uri(bypass))
      |> Plug.Conn.resp(200, "")
    end)

    assert {:ok, _uri} = Upload.start_resumable_upload(@bucket, "object.txt")

    assert_receive {:req_headers, headers}
    assert List.keyfind(headers, "origin", 0) == nil
  end

  @tag :tmp_dir
  test "session PUT sends Content-Length and never transfer-encoding: chunked", %{
    bypass: bypass,
    tmp_dir: tmp_dir
  } do
    test_pid = self()
    payload = :crypto.strong_rand_bytes(1024)
    size = byte_size(payload)
    path = Path.join(tmp_dir, "payload.bin")
    File.write!(path, payload)

    Bypass.expect(bypass, fn conn ->
      case conn.method do
        "POST" ->
          conn
          |> Plug.Conn.put_resp_header("location", session_uri(bypass))
          |> Plug.Conn.resp(200, "")

        "PUT" ->
          send(test_pid, {:req_headers, conn.req_headers})
          Plug.Conn.resp(conn, 200, JSON.encode!(%{"name" => "object.bin"}))
      end
    end)

    assert {:ok, %{"name" => "object.bin"}} = Upload.upload_file(@bucket, "object.bin", path)

    assert_receive {:req_headers, headers}
    assert {"content-length", Integer.to_string(size)} in headers
    assert List.keyfind(headers, "transfer-encoding", 0) == nil
  end

  defp session_uri(bypass),
    do: "http://localhost:#{bypass.port}/upload/storage/v1/b/#{@bucket}/o?upload_id=abc123"
end

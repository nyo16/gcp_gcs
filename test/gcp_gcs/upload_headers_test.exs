defmodule GcpGcs.UploadHeadersTest do
  @moduledoc """
  Guards the `Content-Length` headers on the resumable-upload flow.

  Real GCS rejects both requests with `411 Length Required` if they carry no
  `Content-Length` (the bodyless session-initiation POST, and the session PUT
  whose stream body Mint would otherwise send as `transfer-encoding: chunked`).
  The `fake-gcs-server` emulator does not enforce this, so these assertions run
  against a local `Bypass` server that captures the exact headers sent.

  `async: false` — the tests point the global emulator endpoint at Bypass.
  """
  use ExUnit.Case, async: false

  alias GcpGcs.Upload

  @bucket "test-bucket"

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:gcp_gcs, :emulator)

    Application.put_env(:gcp_gcs, :emulator, scheme: "http", host: "localhost", port: bypass.port)
    on_exit(fn -> Application.put_env(:gcp_gcs, :emulator, original) end)

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

  defp session_uri(bypass), do: "http://localhost:#{bypass.port}/upload/session/abc123"
end

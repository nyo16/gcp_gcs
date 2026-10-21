defmodule GcpGcs.OperationsTest do
  @moduledoc """
  Public API error paths and request shapes against a local fake HTTP server (`GcpGcs.FakeServer`):
  downloads, resumable-upload failures and object metadata operations.

  `async: false` — the tests point the global emulator endpoint at the fake server.
  """
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  alias GcpGcs.{Download, Error, FakeResumable, FakeServer}

  @bucket "test-bucket"
  @not_found ~s({"error":{"code":404,"message":"No such object: test-bucket/obj"}})

  setup do
    fake = FakeServer.open()
    put_emulator_for_test(fake.port)
    {:ok, fake: fake}
  end

  defp expect_media_404(fake) do
    FakeServer.expect_once(fake, "GET", "/storage/v1/b/#{@bucket}/o/obj", fn conn ->
      Plug.Conn.resp(conn, 404, @not_found)
    end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, JSON.encode!(body))
  end

  defp read_json(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {JSON.decode!(body), conn}
  end

  describe "downloads" do
    test "download/3 returns :not_found with the API message", %{fake: fake} do
      expect_media_404(fake)

      assert {:error, %Error{code: :not_found, message: "No such object: test-bucket/obj"}} =
               GcpGcs.download(@bucket, "obj")
    end

    @tag :tmp_dir
    test "download_to_file/4 leaves neither the file nor .part on error", %{
      fake: fake,
      tmp_dir: tmp_dir
    } do
      expect_media_404(fake)
      path = Path.join(tmp_dir, "out.bin")

      assert {:error, %Error{code: :not_found}} = GcpGcs.download_to_file(@bucket, "obj", path)
      refute File.exists?(path)
      refute File.exists?(path <> ".part")
    end

    @tag :tmp_dir
    test "download_to_file/4 into a read-only directory is :io_error", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "ro")
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o555)
      on_exit(fn -> File.chmod(dir, 0o755) end)
      path = Path.join(dir, "out.bin")

      assert {:error, %Error{code: :io_error}} = GcpGcs.download_to_file(@bucket, "obj", path)
      assert File.ls!(dir) == []
    end

    test "stream/5 returns the error and the reducer never sees data", %{fake: fake} do
      expect_media_404(fake)
      test_pid = self()

      reducer = fn
        {:data, _} = event, acc ->
          send(test_pid, event)
          acc

        _other, acc ->
          acc
      end

      assert {:error, %Error{code: :not_found}} =
               Download.stream(@bucket, "obj", :acc, reducer)

      refute_received {:data, _}
    end

    test "stream/5 folds every chunk of a chunked body", %{fake: fake} do
      FakeServer.expect_once(fake, "GET", "/storage/v1/b/#{@bucket}/o/obj", fn conn ->
        assert conn.query_string == "alt=media"
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(["one,", "two,", "three"], conn, fn part, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, part)
          conn
        end)
      end)

      reducer = fn
        {:data, chunk}, acc -> [acc, chunk]
        _other, acc -> acc
      end

      assert {:ok, iodata} = GcpGcs.download_stream(@bucket, "obj", [], reducer)
      assert IO.iodata_to_binary(iodata) == "one,two,three"
    end

    test ":range sends a Range header and a 206 is a success", %{fake: fake} do
      test_pid = self()

      FakeServer.expect(fake, "GET", "/storage/v1/b/#{@bucket}/o/obj", fn conn ->
        send(test_pid, {:range, Plug.Conn.get_req_header(conn, "range")})
        Plug.Conn.resp(conn, 206, "cde")
      end)

      assert {:ok, "cde"} = GcpGcs.download(@bucket, "obj", range: 2..4)
      assert_received {:range, ["bytes=2-4"]}

      assert {:ok, "cde"} = GcpGcs.download(@bucket, "obj", range: {2, nil})
      assert_received {:range, ["bytes=2-"]}

      assert {:error, %Error{code: :validation_error}} =
               GcpGcs.download(@bucket, "obj", range: {5, 1})

      refute_received {:range, _}
    end

    test "a reducer returning {:halt, acc} stops reading the body", %{fake: fake} do
      FakeServer.expect_once(fake, "GET", "/storage/v1/b/#{@bucket}/o/obj", fn conn ->
        FakeServer.pass(fake)
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(["first", "second", "third"], conn, fn part, conn ->
          case Plug.Conn.chunk(conn, part) do
            {:ok, conn} -> conn
            {:error, :closed} -> conn
          end
        end)
      end)

      reducer = fn
        {:data, chunk}, acc -> {:halt, [chunk | acc]}
        _other, acc -> acc
      end

      assert {:ok, ["first"]} = GcpGcs.download_stream(@bucket, "obj", [], reducer)
    end

    test "a large error body is truncated to 64 KiB", %{fake: fake} do
      FakeServer.expect_once(fake, "GET", "/storage/v1/b/#{@bucket}/o/obj", fn conn ->
        FakeServer.pass(fake)
        Plug.Conn.resp(conn, 403, String.duplicate("x", 1024 * 1024))
      end)

      assert {:error, %Error{code: :permission_denied, details: body}} =
               GcpGcs.download(@bucket, "obj")

      assert byte_size(body) == 64 * 1024
    end
  end

  describe "resumable upload failures" do
    test "an initiation 200 without Location is an error", %{fake: fake} do
      FakeServer.expect_once(fake, "POST", "/upload/storage/v1/b/#{@bucket}/o", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:error, %Error{message: "resumable upload session missing Location header"}} =
               GcpGcs.start_resumable_upload(@bucket, "obj")
    end

    test "an initiation 403 is :permission_denied", %{fake: fake} do
      FakeServer.expect_once(fake, "POST", "/upload/storage/v1/b/#{@bucket}/o", fn conn ->
        json(conn, 403, %{"error" => %{"code" => 403, "message" => "denied"}})
      end)

      assert {:error, %Error{code: :permission_denied, message: "denied"}} =
               GcpGcs.upload_stream(@bucket, "obj", ["data"])
    end

    test "with retries disabled, a failing chunk PUT stops the upload", %{fake: fake} do
      server =
        FakeResumable.start(fake, fn
          1, _req -> {:status, 503}
          _i, _req -> :all
        end)

      chunk = 262_144
      data = :crypto.strong_rand_bytes(4 * chunk)

      assert {:error, %Error{code: :unavailable, status: 503, details: details}} =
               GcpGcs.upload_stream(@bucket, "obj", [data], chunk_size: chunk, retry: false)

      assert %{session_uri: session_uri} = details
      assert session_uri == FakeResumable.session_uri(fake)
      assert length(FakeResumable.puts(server)) == 2
    end

    test "upload_file/4 on a missing path is :io_error" do
      assert {:error, %Error{code: :io_error}} =
               GcpGcs.upload_file(@bucket, "obj", "/nonexistent/gcp_gcs/file.bin")
    end

    @tag :tmp_dir
    test "upload_file/4 of an empty file is a single media upload", %{
      fake: fake,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "empty.txt")
      File.write!(path, "")

      FakeServer.expect_once(fake, "POST", "/upload/storage/v1/b/#{@bucket}/o", fn conn ->
        assert %{"uploadType" => "media", "name" => "empty.txt"} =
                 URI.decode_query(conn.query_string)

        json(conn, 200, %{"name" => "empty.txt", "size" => "0"})
      end)

      assert {:ok, %{"size" => "0"}} = GcpGcs.upload_file(@bucket, "empty.txt", path)
    end
  end

  describe "rewrite_object/5" do
    test "follows the rewrite token until done", %{fake: fake} do
      test_pid = self()

      FakeServer.expect(fake, "POST", "/storage/v1/b/src/o/a%2Fb/rewriteTo/b/dst/o/c", fn conn ->
        query = URI.decode_query(conn.query_string)
        send(test_pid, {:rewrite, query})

        case query do
          %{"rewriteToken" => "t1"} ->
            json(conn, 200, %{"done" => true, "resource" => %{"name" => "c"}})

          _ ->
            json(conn, 200, %{"done" => false, "rewriteToken" => "t1"})
        end
      end)

      assert {:ok, %{"name" => "c"}} = GcpGcs.rewrite_object("src", "a/b", "dst", "c")
      assert_received {:rewrite, first}
      refute Map.has_key?(first, "rewriteToken")
      assert_received {:rewrite, %{"rewriteToken" => "t1"}}
    end

    test "passes 4xx errors through", %{fake: fake} do
      FakeServer.expect_once(fake, "POST", "/storage/v1/b/src/o/a/rewriteTo/b/dst/o/c", fn conn ->
        json(conn, 404, %{"error" => %{"message" => "gone"}})
      end)

      assert {:error, %Error{code: :not_found, message: "gone"}} =
               GcpGcs.rewrite_object("src", "a", "dst", "c")
    end

    test "an unexpected response shape is an error, not a success", %{fake: fake} do
      FakeServer.expect_once(fake, "POST", "/storage/v1/b/src/o/a/rewriteTo/b/dst/o/c", fn conn ->
        json(conn, 200, %{"kind" => "storage#rewriteResponse"})
      end)

      assert {:error, %Error{message: "unexpected rewrite response"}} =
               GcpGcs.rewrite_object("src", "a", "dst", "c")
    end
  end

  describe "copy, move and update" do
    test "copy_object/5 posts attrs to the encoded copyTo path", %{fake: fake} do
      FakeServer.expect_once(fake, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/storage/v1/b/src/o/dir%2Fa.txt/copyTo/b/dst/o/dir%2Fb.txt"
        {body, conn} = read_json(conn)
        assert body == %{"contentType" => "text/plain"}
        json(conn, 200, %{"name" => "dir/b.txt"})
      end)

      assert {:ok, %{"name" => "dir/b.txt"}} =
               GcpGcs.copy_object("src", "dir/a.txt", "dst", "dir/b.txt",
                 attrs: %{"contentType" => "text/plain"}
               )
    end

    test "move_object/4 posts to the encoded moveTo path", %{fake: fake} do
      FakeServer.expect_once(fake, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/storage/v1/b/#{@bucket}/o/a%2Fb/moveTo/o/c%2Fd"
        json(conn, 200, %{"name" => "c/d"})
      end)

      assert {:ok, %{"name" => "c/d"}} = GcpGcs.move_object(@bucket, "a/b", "c/d")
    end

    test "update_object/4 patches the encoded object path", %{fake: fake} do
      FakeServer.expect_once(fake, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/storage/v1/b/#{@bucket}/o/a%2Fb"
        {body, conn} = read_json(conn)
        assert body == %{"metadata" => %{"k" => "v"}}
        json(conn, 200, %{"name" => "a/b", "metadata" => %{"k" => "v"}})
      end)

      assert {:ok, %{"metadata" => %{"k" => "v"}}} =
               GcpGcs.update_object(@bucket, "a/b", %{"metadata" => %{"k" => "v"}})
    end

    test "404s pass through", %{fake: fake} do
      FakeServer.expect(fake, fn conn -> json(conn, 404, %{"error" => %{"message" => "nope"}}) end)

      for result <- [
            GcpGcs.copy_object("src", "a", "dst", "b"),
            GcpGcs.move_object(@bucket, "a", "b"),
            GcpGcs.update_object(@bucket, "a", %{})
          ] do
        assert {:error, %Error{code: :not_found, message: "nope"}} = result
      end
    end
  end
end

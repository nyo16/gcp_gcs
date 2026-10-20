defmodule GcpGcs.UploadResumableTest do
  @moduledoc """
  Resumable-upload chunking against a Bypass-backed fake session
  (`GcpGcs.FakeResumable`), asserting what goes over the wire.

  `async: false` — the tests point the global emulator endpoint at Bypass.
  """
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  alias GcpGcs.{Error, FakeResumable, Upload}

  @bucket "test-bucket"
  @chunk 262_144

  setup do
    bypass = Bypass.open()
    put_emulator_for_test(bypass.port)
    {:ok, bypass: bypass}
  end

  defp input(size), do: :crypto.strong_rand_bytes(size)

  # Splits `data` into `size`-byte pieces (the last one may be shorter).
  defp split(data, size) when byte_size(data) > size do
    <<piece::binary-size(^size), rest::binary>> = data
    [piece | split(rest, size)]
  end

  defp split(data, _size), do: [data]

  describe "upload_stream/4 partial persistence" do
    test "a 308 persisting only part of a chunk resends from the persisted offset", %{
      bypass: bypass
    } do
      server =
        FakeResumable.start(bypass, fn
          0, _req -> {:partial, 100}
          _i, _req -> :all
        end)

      data = input(2 * @chunk + 1000)

      assert {:ok, %{"name" => "object.bin"}} =
               Upload.upload_stream(@bucket, "object.bin", split(data, 1000), chunk_size: @chunk)

      [first, second | _] = FakeResumable.puts(server)
      assert first.content_range == "bytes 0-#{@chunk - 1}/*"
      assert second.content_range == "bytes 100-#{100 + @chunk - 1}/*"
      assert binary_part(second.body, 0, 16) == binary_part(data, 100, 16)

      assert FakeResumable.data(server) == data
    end

    test "a 308 without Range on the first chunk resends the whole chunk", %{bypass: bypass} do
      server =
        FakeResumable.start(bypass, fn
          0, _req -> :none
          _i, _req -> :all
        end)

      data = input(@chunk + 10)

      assert {:ok, _} = Upload.upload_stream(@bucket, "object.bin", [data], chunk_size: @chunk)

      assert [first, second, final] = FakeResumable.puts(server)
      assert first.content_range == "bytes 0-#{@chunk - 1}/*"
      assert second.content_range == first.content_range
      assert second.body == first.body
      assert final.content_range == "bytes #{@chunk}-#{@chunk + 9}/#{@chunk + 10}"
      assert FakeResumable.data(server) == data
    end

    test "a 308 without Range after the first chunk is data loss", %{bypass: bypass} do
      FakeResumable.start(bypass, fn
        1, _req -> :forget
        _i, _req -> :all
      end)

      assert {:error, %Error{code: :data_loss}} =
               Upload.upload_stream(@bucket, "object.bin", [input(3 * @chunk)],
                 chunk_size: @chunk
               )
    end

    test "repeated no-progress 308s stop with an error instead of looping", %{bypass: bypass} do
      server = FakeResumable.start(bypass, fn _i, _req -> :none end)

      assert {:error, %Error{message: "resumable upload made no progress" <> _}} =
               Upload.upload_stream(@bucket, "object.bin", [input(@chunk)], chunk_size: @chunk)

      assert length(FakeResumable.puts(server)) == 2
    end
  end

  describe "upload_stream/4 finalize" do
    test "a 308 on the final request resends the unsent tail", %{bypass: bypass} do
      server =
        FakeResumable.start(bypass, fn
          0, _req -> {:partial, 40}
          _i, _req -> :all
        end)

      data = input(100)

      assert {:ok, _} = Upload.upload_stream(@bucket, "object.bin", [data], chunk_size: @chunk)

      assert [first, second] = FakeResumable.puts(server)
      assert first.content_range == "bytes 0-99/100"
      assert second.content_range == "bytes 40-99/100"
      assert second.body == binary_part(data, 40, 60)
      assert FakeResumable.data(server) == data
    end
  end

  describe "upload_chunk/3 session URI validation" do
    # `other` has no expectations: any request reaching it fails the test.
    setup %{bypass: bypass} do
      {:ok,
       other: Bypass.open(),
       path: "/upload/storage/v1/b/#{@bucket}/o?upload_id=x",
       port: bypass.port}
    end

    test "rejects a foreign host", %{other: other, path: path} do
      uri = "http://127.0.0.1:#{other.port}#{path}"

      assert {:error, %Error{code: :validation_error}} =
               Upload.upload_chunk(uri, "data", offset: 0, total: 4)
    end

    test "rejects a wrong port", %{other: other, path: path} do
      uri = "http://localhost:#{other.port}#{path}"

      assert {:error, %Error{code: :validation_error}} =
               Upload.upload_chunk(uri, "data", offset: 0, total: 4)
    end

    test "rejects http:// when the endpoint is https", %{other: other, path: path} do
      put_env_for_test(:gcp_gcs, :emulator, scheme: "https", host: "localhost", port: other.port)
      uri = "http://localhost:#{other.port}#{path}"

      assert {:error, %Error{code: :validation_error}} =
               Upload.upload_chunk(uri, "data", offset: 0, total: 4)
    end

    test "rejects a path outside the upload API", %{port: port} do
      uri = "http://localhost:#{port}/storage/v1/b/#{@bucket}/o/x"

      assert {:error, %Error{code: :validation_error}} =
               Upload.upload_chunk(uri, "data", offset: 0, total: 4)
    end

    test "rejects a server-returned Location on another host", %{bypass: bypass, other: other} do
      Bypass.expect_once(bypass, "POST", "/upload/storage/v1/b/#{@bucket}/o", fn conn ->
        conn
        |> Plug.Conn.put_resp_header(
          "location",
          "http://127.0.0.1:#{other.port}/upload/storage/v1/b/x"
        )
        |> Plug.Conn.resp(200, "")
      end)

      assert {:error, %Error{code: :validation_error}} =
               Upload.upload_stream(@bucket, "object.bin", ["data"])
    end
  end
end

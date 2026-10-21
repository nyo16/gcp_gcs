defmodule GcpGcsTest do
  # Not async: points the global emulator endpoint at a downed fake server.
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  alias GcpGcs.FakeServer

  # The endpoint refuses connections, so an input that slipped past validation
  # would surface as :connection_error instead of :validation_error.
  setup do
    fake = FakeServer.open()
    FakeServer.down(fake)
    put_emulator_for_test(fake.port)
  end

  describe "validation short-circuits before any network call" do
    test "rejects an invalid bucket name" do
      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.get_bucket("UPPERCASE_AND_BAD")
    end

    test "rejects an empty object name" do
      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.get_object("valid-bucket", "")
    end

    test "rejects a non-binary project id on create" do
      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.create_bucket(nil, "valid-bucket")
    end
  end

  describe "former raises return validation errors" do
    test "upload_chunk/3 with non-binary data or a bad offset" do
      uri = GcpGcs.Config.upload_base() <> "/b/valid-bucket/o?upload_id=x"

      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.upload_chunk(uri, 123, offset: 0)

      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.upload_chunk(uri, "data", [])

      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.upload_chunk(uri, "data", offset: -1)
    end

    test "update_bucket/3 and update_object/4 with non-map attrs" do
      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.update_bucket("valid-bucket", labels: %{})

      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.update_object("valid-bucket", "obj", "nope")
    end

    test "download_stream with a reducer of the wrong arity" do
      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.download_stream("valid-bucket", "obj", 0, fn _ -> 0 end)
    end

    test "download_stream with non-keyword options" do
      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.download_stream("valid-bucket", "obj", 0, fn _, acc -> acc end, :nope)
    end

    test "upload/4 with an unsupported source makes no request" do
      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.upload("valid-bucket", "obj", 123)
    end
  end

  describe "unknown options are rejected" do
    test "one function per module" do
      calls = [
        fn -> GcpGcs.list_objects("valid-bucket", max_results: 10) end,
        fn -> GcpGcs.list_buckets("my-project", max_results: 10) end,
        fn -> GcpGcs.get_object("valid-bucket", "obj", generations: 1) end,
        fn -> GcpGcs.create_bucket("my-project", "valid-bucket", region: "EU") end,
        fn -> GcpGcs.put_object("valid-bucket", "obj", "data", chunk_size: 1) end,
        fn -> GcpGcs.upload_stream("valid-bucket", "obj", ["data"], metadata: %{}) end,
        fn ->
          GcpGcs.upload_chunk("http://localhost/upload/storage/v1/b/x", "d", offset: 0, foo: 1)
        end,
        fn -> GcpGcs.download("valid-bucket", "obj", byte_range: 1..2) end,
        fn -> GcpGcs.rewrite_object("a-bucket", "a", "b-bucket", "b", attr: %{}) end
      ]

      for call <- calls do
        assert {:error, %GcpGcs.Error{code: :validation_error, details: {:unknown_options, [_]}}} =
                 call.()
      end
    end

    test "transport options are accepted everywhere" do
      # The endpoint is down, so a request that gets past validation fails to connect.
      assert {:error, %GcpGcs.Error{code: :connection_error}} =
               GcpGcs.list_objects("valid-bucket", timeout: 100, pool_timeout: 100, retry: false)
    end
  end

  describe "download_stream argument order" do
    import ExUnit.CaptureIO

    setup do
      fake = FakeServer.open()
      put_emulator_for_test(fake.port)

      FakeServer.expect(fake, "GET", "/storage/v1/b/valid-bucket/o/obj", fn conn ->
        Plug.Conn.resp(conn, 200, "body")
      end)

      :ok
    end

    test "the old order still works, with a deprecation warning" do
      reducer = fn
        {:data, data}, acc -> acc <> data
        _other, acc -> acc
      end

      assert {:ok, "body"} = GcpGcs.download_stream("valid-bucket", "obj", "", reducer)

      assert {:ok, "body"} =
               GcpGcs.download_stream("valid-bucket", "obj", "", reducer, retry: false)

      warning =
        capture_io(:stderr, fn ->
          assert {:ok, "body"} = GcpGcs.download_stream("valid-bucket", "obj", [], "", reducer)
        end)

      assert warning =~ "deprecated"
    end
  end

  describe "header values and names are validated before any request" do
    test ":origin and :content_type must be printable ASCII" do
      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.start_resumable_upload("valid-bucket", "obj", origin: "https://a\r\nx: y")

      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.put_object("valid-bucket", "obj", "d", content_type: "text/plain\n")

      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.upload_stream("valid-bucket", "obj", ["d"], content_type: "tëxt/plain")
    end

    test "bucket names with '..', '.-' or '-.' are rejected" do
      for bucket <- ["my..bucket", "my.-bucket", "my-.bucket"] do
        assert {:error, %GcpGcs.Error{code: :validation_error}} = GcpGcs.get_bucket(bucket)
      end
    end

    test "object names with control characters or invalid UTF-8 are rejected" do
      for object <- ["a\tb", "nul\0", "bell\a", <<0xFF, 0xFE>>] do
        assert {:error, %GcpGcs.Error{code: :validation_error}} =
                 GcpGcs.get_object("valid-bucket", object)
      end
    end
  end
end

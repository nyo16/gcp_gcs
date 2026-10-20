defmodule GcpGcsTest do
  # Not async: points the global emulator endpoint at a downed Bypass server.
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  # The endpoint refuses connections, so an input that slipped past validation
  # would surface as :connection_error instead of :validation_error.
  setup do
    bypass = Bypass.open()
    Bypass.down(bypass)
    put_emulator_for_test(bypass.port)
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

    test "download_stream/5 with a reducer of the wrong arity" do
      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.download_stream("valid-bucket", "obj", [], 0, fn _ -> 0 end)
    end

    test "upload/4 with an unsupported source makes no request" do
      assert {:error, %GcpGcs.Error{code: :validation_error}} =
               GcpGcs.upload("valid-bucket", "obj", 123)
    end
  end
end

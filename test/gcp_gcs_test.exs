defmodule GcpGcsTest do
  use ExUnit.Case, async: true

  # function_exported?/3 does not auto-load; make sure the module is loaded
  # regardless of test ordering.
  setup_all do
    Code.ensure_loaded!(GcpGcs)
    :ok
  end

  describe "public API surface" do
    test "delegates bucket operations" do
      assert function_exported?(GcpGcs, :create_bucket, 3)
      assert function_exported?(GcpGcs, :get_bucket, 2)
      assert function_exported?(GcpGcs, :list_buckets, 2)
      assert function_exported?(GcpGcs, :delete_bucket, 2)
      assert function_exported?(GcpGcs, :update_bucket, 3)
    end

    test "delegates object operations" do
      assert function_exported?(GcpGcs, :get_object, 3)
      assert function_exported?(GcpGcs, :list_objects, 2)
      assert function_exported?(GcpGcs, :delete_object, 3)
      assert function_exported?(GcpGcs, :copy_object, 5)
      assert function_exported?(GcpGcs, :compose_object, 4)
      assert function_exported?(GcpGcs, :rewrite_object, 5)
      assert function_exported?(GcpGcs, :move_object, 4)
    end

    test "delegates upload and download operations" do
      assert function_exported?(GcpGcs, :put_object, 4)
      assert function_exported?(GcpGcs, :upload, 4)
      assert function_exported?(GcpGcs, :upload_file, 4)
      assert function_exported?(GcpGcs, :upload_stream, 4)
      assert function_exported?(GcpGcs, :download, 3)
      assert function_exported?(GcpGcs, :download_to_file, 4)
      assert function_exported?(GcpGcs, :download_stream, 5)
    end
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
end

defmodule GcpGcs.TelemetryTest do
  # Not async: telemetry handlers are global, so events from concurrently
  # running tests would reach this test's handler.
  use ExUnit.Case, async: false

  @events [
    [:gcp_gcs, :request, :start],
    [:gcp_gcs, :request, :stop],
    [:gcp_gcs, :request, :exception]
  ]

  setup do
    id = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        id,
        @events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "a validation failure emits start and stop with the error code" do
    assert {:error, _} = GcpGcs.get_bucket("BAD-telemetry")

    assert_received {:telemetry, [:gcp_gcs, :request, :start], %{system_time: _},
                     %{operation: :get_bucket, bucket: "BAD-telemetry"}}

    assert_received {:telemetry, [:gcp_gcs, :request, :stop], %{duration: duration},
                     %{
                       operation: :get_bucket,
                       bucket: "BAD-telemetry",
                       result: {:error, :validation_error}
                     }}

    assert is_integer(duration) and duration >= 0
  end

  test "a raising operation emits an :exception event" do
    assert_raise RuntimeError, "boom", fn ->
      GcpGcs.Telemetry.span(:telemetry_test, %{bucket: "b"}, fn -> raise "boom" end)
    end

    assert_received {:telemetry, [:gcp_gcs, :request, :exception], %{duration: _},
                     %{operation: :telemetry_test, kind: :error, reason: %RuntimeError{}}}
  end

  describe "operation names and metadata" do
    import GcpGcs.EnvHelper

    alias GcpGcs.{FakeResumable, FakeServer}

    setup do
      fake = FakeServer.open()
      put_emulator_for_test(fake.port)
      {:ok, fake: fake}
    end

    defp stops do
      receive do
        {:telemetry, [:gcp_gcs, :request, :stop], _measurements, meta} -> [meta | stops()]
      after
        0 -> []
      end
    end

    @tag :tmp_dir
    test "uploads and downloads report their own operation", %{
      fake: fake,
      tmp_dir: tmp_dir
    } do
      server = FakeResumable.start(fake)
      path = Path.join(tmp_dir, "f.bin")
      File.write!(path, "abc")
      bucket = "test-bucket"

      {:ok, _} = GcpGcs.upload_file(bucket, "f.bin", path)
      {:ok, _} = GcpGcs.upload_stream(bucket, "s.bin", ["abc"])
      {:ok, session} = GcpGcs.start_resumable_upload(bucket, "c.bin")
      {:ok, _} = GcpGcs.upload_chunk(session, "abc", offset: 0, total: 3)
      _ = FakeResumable.data(server)

      assert [
               %{operation: :upload_file, bucket: ^bucket, object: "f.bin", source: ^path},
               %{operation: :upload_stream, bucket: ^bucket, object: "s.bin"},
               %{operation: :start_resumable_upload, bucket: ^bucket, object: "c.bin"},
               # The fake session URI names no object; the bucket comes from its path.
               %{operation: :upload_chunk, bucket: ^bucket, object: nil, result: :ok}
             ] = stops()

      dest = Path.join(tmp_dir, "out.bin")

      FakeServer.expect(fake, "GET", "/storage/v1/b/#{bucket}/o/x", fn conn ->
        Plug.Conn.resp(conn, 200, "x")
      end)

      {:ok, _} = GcpGcs.download(bucket, "x")
      :ok = GcpGcs.download_to_file(bucket, "x", dest)
      {:ok, _} = GcpGcs.download_stream(bucket, "x", nil, fn _, acc -> acc end)

      assert [
               %{operation: :download, object: "x"},
               %{operation: :download_to_file, object: "x", destination: ^dest},
               %{operation: :download_stream, object: "x"}
             ] = stops()
    end

    test "put_object reports its strategy; bucket ops carry object: nil" do
      assert {:error, _} = GcpGcs.put_object("BAD-bucket", "o", "d")
      assert {:error, _} = GcpGcs.put_object("BAD-bucket", "o", "d", attrs: %{})
      assert {:error, _} = GcpGcs.list_objects("BAD-bucket")

      assert [
               %{operation: :put_object, strategy: :simple},
               %{operation: :put_object, strategy: :resumable},
               %{operation: :list_objects, bucket: "BAD-bucket", object: nil}
             ] = stops()
    end

    test "copy, rewrite and move name the destination as bucket/object" do
      assert {:error, _} = GcpGcs.copy_object("src-bkt", "a", "BAD-dst", "b")
      assert {:error, _} = GcpGcs.rewrite_object("src-bkt", "a", "BAD-dst", "b")
      assert {:error, _} = GcpGcs.move_object("BAD-bkt", "a", "b")

      assert [
               %{operation: :copy_object, bucket: "BAD-dst", object: "b", src_bucket: "src-bkt"},
               %{operation: :rewrite_object, bucket: "BAD-dst", object: "b", src_object: "a"},
               %{operation: :move_object, bucket: "BAD-bkt", object: "b", src_object: "a"}
             ] = stops()
    end
  end
end

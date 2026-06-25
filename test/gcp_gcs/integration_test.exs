defmodule GcpGcs.IntegrationTest do
  @moduledoc """
  End-to-end tests against a local emulator (fake-gcs-server).

  Excluded by default. Run with:

      docker-compose up -d
      mix test --include integration
  """
  use ExUnit.Case, async: false

  alias GcpGcs.EmulatorHelper

  @moduletag :integration

  @project "test-project"

  setup do
    unless EmulatorHelper.emulator_running?() do
      flunk("GCS emulator not reachable — run `docker-compose up -d` first")
    end

    bucket = EmulatorHelper.unique("gcp-gcs-it")
    {:ok, _} = GcpGcs.create_bucket(@project, bucket)
    on_exit(fn -> cleanup(bucket) end)

    {:ok, bucket: bucket}
  end

  test "simple upload round-trips through download and metadata", %{bucket: bucket} do
    assert {:ok, _} =
             GcpGcs.put_object(bucket, "hello.txt", "Hello, GCS!", content_type: "text/plain")

    assert {:ok, object} = GcpGcs.get_object(bucket, "hello.txt")
    assert object["name"] == "hello.txt"

    assert {:ok, "Hello, GCS!"} = GcpGcs.download(bucket, "hello.txt")
    assert :ok = GcpGcs.delete_object(bucket, "hello.txt")
    assert {:error, %GcpGcs.Error{code: :not_found}} = GcpGcs.get_object(bucket, "hello.txt")
  end

  test "lists objects with a prefix and delimiter", %{bucket: bucket} do
    assert {:ok, _} = GcpGcs.put_object(bucket, "logs/a.txt", "a")
    assert {:ok, _} = GcpGcs.put_object(bucket, "logs/b.txt", "b")
    assert {:ok, _} = GcpGcs.put_object(bucket, "root.txt", "r")

    assert {:ok, %{items: items}} = GcpGcs.list_objects(bucket, prefix: "logs/")
    names = Enum.map(items, & &1["name"])
    assert "logs/a.txt" in names
    assert "logs/b.txt" in names
    refute "root.txt" in names
  end

  test "resumable file upload and streamed download", %{bucket: bucket} do
    source = Path.join(System.tmp_dir!(), EmulatorHelper.unique("upload") <> ".bin")
    dest = Path.join(System.tmp_dir!(), EmulatorHelper.unique("download") <> ".bin")
    payload = :crypto.strong_rand_bytes(1_000_000)
    File.write!(source, payload)

    on_exit(fn ->
      File.rm(source)
      File.rm(dest)
    end)

    assert {:ok, _} = GcpGcs.upload_file(bucket, "big.bin", source)
    assert :ok = GcpGcs.download_to_file(bucket, "big.bin", dest)
    assert File.read!(dest) == payload
  end

  test "stream upload from an enumerable", %{bucket: bucket} do
    chunks = for _ <- 1..4, do: :crypto.strong_rand_bytes(300_000)
    expected = IO.iodata_to_binary(chunks)

    assert {:ok, _} = GcpGcs.upload_stream(bucket, "streamed.bin", chunks, chunk_size: 262_144)
    assert {:ok, ^expected} = GcpGcs.download(bucket, "streamed.bin")
  end

  test "compose concatenates source objects", %{bucket: bucket} do
    assert {:ok, _} = GcpGcs.put_object(bucket, "part-1", "foo")
    assert {:ok, _} = GcpGcs.put_object(bucket, "part-2", "bar")

    assert {:ok, _} = GcpGcs.compose_object(bucket, "combined", ["part-1", "part-2"])
    assert {:ok, "foobar"} = GcpGcs.download(bucket, "combined")
  end

  defp cleanup(bucket) do
    case GcpGcs.list_objects(bucket) do
      {:ok, %{items: items}} ->
        Enum.each(items, fn obj -> GcpGcs.delete_object(bucket, obj["name"]) end)

      _ ->
        :ok
    end

    GcpGcs.delete_bucket(bucket)
  end
end

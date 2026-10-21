defmodule GcpGcs.IntegrationTest do
  @moduledoc """
  End-to-end tests against a local emulator (fake-gcs-server).

  Excluded by default. Run with:

      docker-compose up -d
      mix test --include integration
  """
  use ExUnit.Case, async: false

  import GcpGcs.EnvHelper

  alias GcpGcs.EmulatorHelper

  @moduletag :integration

  @project "test-project"
  @emulator_port 4443

  setup do
    put_emulator_for_test(@emulator_port)

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

    assert {:ok, %{items: top, prefixes: prefixes}} = GcpGcs.list_objects(bucket, delimiter: "/")
    assert Enum.map(top, & &1["name"]) == ["root.txt"]
    assert prefixes == ["logs/"]
  end

  test "pages through objects with page_size and next_page_token", %{bucket: bucket} do
    for name <- ~w(a b c), do: {:ok, _} = GcpGcs.put_object(bucket, name, name)

    names = collect_pages(bucket, nil, [])
    assert Enum.sort(names) == ~w(a b c)
  end

  test "stream_objects!/2 pages lazily", %{bucket: bucket} do
    for name <- ~w(a b c), do: {:ok, _} = GcpGcs.put_object(bucket, name, name)

    id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      id,
      [:gcp_gcs, :request, :stop],
      fn _event, _measurements, %{operation: op}, _ -> send(test_pid, {:request, op}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    stream = GcpGcs.stream_objects!(bucket, page_size: 1)

    assert stream |> Enum.map(& &1["name"]) |> Enum.sort() == ~w(a b c)
    assert count_requests(:list_objects) >= 3

    assert [_] = Enum.take(stream, 1)
    assert count_requests(:list_objects) == 1
  end

  test "stream_objects!/2 raises on a missing bucket" do
    assert_raise GcpGcs.Error, fn ->
      "gcp-gcs-missing-bucket" |> GcpGcs.stream_objects!() |> Enum.to_list()
    end
  end

  defp count_requests(op, n \\ 0) do
    receive do
      {:request, ^op} -> count_requests(op, n + 1)
    after
      0 -> n
    end
  end

  test "bucket metadata round-trips", %{bucket: bucket} do
    assert {:ok, %{"name" => ^bucket}} = GcpGcs.get_bucket(bucket)

    assert {:ok, %{items: buckets}} = GcpGcs.list_buckets(@project, prefix: bucket)
    assert bucket in Enum.map(buckets, & &1["name"])

    # fake-gcs-server persists only some Bucket fields on PATCH (not
    # versioning or labels); defaultEventBasedHold is one it does.
    assert {:ok, %{"defaultEventBasedHold" => true}} =
             GcpGcs.update_bucket(bucket, %{"defaultEventBasedHold" => true})

    assert {:ok, %{"defaultEventBasedHold" => true}} = GcpGcs.get_bucket(bucket)
  end

  @tag :tmp_dir
  test "resumable file upload and streamed download", %{bucket: bucket, tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "upload.bin")
    dest = Path.join(tmp_dir, "download.bin")
    payload = :crypto.strong_rand_bytes(1_000_000)
    File.write!(source, payload)

    assert {:ok, _} = GcpGcs.upload_file(bucket, "big.bin", source)
    assert :ok = GcpGcs.download_to_file(bucket, "big.bin", dest)
    assert File.read!(dest) == payload
    refute File.exists?(dest <> ".part")
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

  defp collect_pages(bucket, token, acc) do
    assert {:ok, %{items: items, next_page_token: next}} =
             GcpGcs.list_objects(bucket, page_size: 1, page_token: token)

    assert length(items) <= 1
    acc = acc ++ Enum.map(items, & &1["name"])

    case next do
      nil -> acc
      next -> collect_pages(bucket, next, acc)
    end
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

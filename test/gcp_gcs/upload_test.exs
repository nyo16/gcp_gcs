defmodule GcpGcs.UploadTest do
  use ExUnit.Case, async: true

  alias GcpGcs.Upload

  describe "content_range/3" do
    test "intermediate chunk with unknown total" do
      assert Upload.content_range(0, 262_144, nil) == "bytes 0-262143/*"
      assert Upload.content_range(262_144, 262_144, nil) == "bytes 262144-524287/*"
    end

    test "final chunk with known total" do
      assert Upload.content_range(0, 100, 100) == "bytes 0-99/100"
      assert Upload.content_range(524_288, 100, 524_388) == "bytes 524288-524387/524388"
    end

    test "zero-length finalize uses '*' for the range" do
      assert Upload.content_range(0, 0, 0) == "bytes */0"
      assert Upload.content_range(1024, 0, 1024) == "bytes */1024"
    end
  end

  describe "next_offset/1" do
    test "parses the persisted byte range from a 308 'range' header" do
      assert Upload.next_offset([{"range", "bytes=0-262143"}]) == {:ok, 262_144}
      assert Upload.next_offset([{"Range", "0-524287"}]) == {:ok, 524_288}
    end

    test "a missing header means nothing has been persisted" do
      assert Upload.next_offset([]) == {:ok, 0}
    end

    test "rejects ranges that don't start at 0 or can't be parsed" do
      assert Upload.next_offset([{"range", "garbage"}]) == :error
      assert Upload.next_offset([{"range", "bytes=5-10"}]) == :error
    end
  end

  describe "chunk_size/1" do
    test "defaults to 8 MiB" do
      assert Upload.chunk_size([]) == 8 * 1024 * 1024
    end

    test "rounds down to a 256 KiB multiple" do
      assert Upload.chunk_size(chunk_size: 300_000) == 262_144
      assert Upload.chunk_size(chunk_size: 600_000) == 524_288
    end

    test "never returns less than 256 KiB" do
      assert Upload.chunk_size(chunk_size: 1) == 262_144
    end
  end
end

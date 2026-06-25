defmodule GcpGcs.ClientTest do
  use ExUnit.Case, async: true

  alias GcpGcs.Client

  describe "encode_object/1" do
    test "leaves unreserved characters untouched" do
      assert Client.encode_object("file.txt") == "file.txt"
      assert Client.encode_object("a-b_c.1~2") == "a-b_c.1~2"
    end

    test "percent-encodes slashes so the name stays a single path segment" do
      assert Client.encode_object("path/to/file.txt") == "path%2Fto%2Ffile.txt"
    end

    test "percent-encodes spaces and other reserved characters" do
      assert Client.encode_object("my file.txt") == "my%20file.txt"
      assert Client.encode_object("a?b&c=d") == "a%3Fb%26c%3Dd"
    end
  end
end

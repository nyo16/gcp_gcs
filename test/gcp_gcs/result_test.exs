defmodule GcpGcs.ResultTest do
  use ExUnit.Case, async: true

  alias GcpGcs.{Error, Result}

  describe "list/2" do
    test "object pages carry prefixes, bucket pages don't" do
      body = %{"items" => [%{"name" => "a"}], "prefixes" => ["p/"], "nextPageToken" => "t"}

      assert {:ok, %{items: [%{"name" => "a"}], prefixes: ["p/"], next_page_token: "t"}} =
               Result.list({:ok, body}, :objects)

      assert {:ok, page} = Result.list({:ok, body}, :buckets)
      assert page == %{items: [%{"name" => "a"}], next_page_token: "t"}
    end

    test "missing keys and non-map bodies are an empty page" do
      assert {:ok, %{items: [], prefixes: [], next_page_token: nil}} =
               Result.list({:ok, %{}}, :objects)

      assert {:ok, %{items: [], next_page_token: nil}} =
               Result.list({:ok, "unexpected"}, :buckets)
    end

    test "passes errors through" do
      error = {:error, Error.new(:not_found, "nope")}
      assert Result.list(error, :objects) == error
    end
  end

  describe "as_ok/1" do
    test "discards a successful body and passes errors through" do
      assert Result.as_ok({:ok, %{}}) == :ok
      error = {:error, Error.new(:not_found, "nope")}
      assert Result.as_ok(error) == error
    end
  end

  describe "stream_pages/2" do
    test "fetches pages lazily and raises a failed page's error" do
      test_pid = self()

      fetch = fn
        nil ->
          send(test_pid, :page1)
          {:ok, %{items: [1, 2], next_page_token: "t2"}}

        "t2" ->
          send(test_pid, :page2)
          {:error, Error.new(:unavailable, "down")}
      end

      assert Enum.take(Result.stream_pages(nil, fetch), 2) == [1, 2]
      assert_received :page1
      refute_received :page2

      assert_raise Error, "down", fn -> nil |> Result.stream_pages(fetch) |> Enum.to_list() end
    end
  end
end

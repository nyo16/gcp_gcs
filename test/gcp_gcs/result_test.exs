defmodule GcpGcs.ResultTest do
  use ExUnit.Case, async: true

  alias GcpGcs.{Error, Result}

  describe "list/2" do
    test "shapes a list body, defaulting missing keys" do
      assert {:ok, %{items: [%{"name" => "a"}], prefixes: ["p/"], next_page_token: "t"}} =
               Result.list(
                 {:ok,
                  %{"items" => [%{"name" => "a"}], "prefixes" => ["p/"], "nextPageToken" => "t"}},
                 "items"
               )

      assert {:ok, %{items: [], prefixes: [], next_page_token: nil}} =
               Result.list({:ok, %{}}, "items")
    end

    test "a non-map body is an empty page" do
      assert {:ok, %{items: [], prefixes: [], next_page_token: nil}} =
               Result.list({:ok, "unexpected"}, "items")
    end

    test "passes errors through" do
      error = {:error, Error.new(:not_found, "nope")}
      assert Result.list(error, "items") == error
    end
  end

  describe "as_ok/1" do
    test "discards a successful body and passes errors through" do
      assert Result.as_ok({:ok, %{}}) == :ok
      error = {:error, Error.new(:not_found, "nope")}
      assert Result.as_ok(error) == error
    end
  end
end

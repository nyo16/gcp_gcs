defmodule GcpGcs.ErrorTest do
  use ExUnit.Case, async: true

  alias GcpGcs.Error

  describe "from_response/2" do
    test "maps common HTTP statuses to codes" do
      assert %Error{code: :not_found, status: 404} = Error.from_response(404, %{})
      assert %Error{code: :unauthenticated, status: 401} = Error.from_response(401, %{})
      assert %Error{code: :permission_denied, status: 403} = Error.from_response(403, %{})
      assert %Error{code: :already_exists, status: 409} = Error.from_response(409, %{})
      assert %Error{code: :invalid_argument, status: 400} = Error.from_response(400, %{})
      assert %Error{code: :unavailable, status: 503} = Error.from_response(503, %{})
    end

    test "uses :unknown for unmapped statuses" do
      assert %Error{code: :unknown, status: 418} = Error.from_response(418, %{})
    end

    test "extracts the message from a GCS JSON error body" do
      body = %{"error" => %{"code" => 404, "message" => "Not Found: my-object"}}
      assert %Error{message: "Not Found: my-object"} = Error.from_response(404, body)
    end

    test "falls back to a generic message when none is present" do
      assert %Error{message: "HTTP 500"} = Error.from_response(500, "boom")
    end
  end

  describe "from_transport/1" do
    test "wraps exceptions" do
      assert %Error{code: :connection_error} = Error.from_transport(%RuntimeError{message: "x"})
    end

    test "wraps arbitrary reasons" do
      assert %Error{code: :connection_error} = Error.from_transport(:timeout)
    end
  end

  describe "new/3" do
    test "builds a struct" do
      assert %Error{code: :validation_error, message: "bad", details: :why} =
               Error.new(:validation_error, "bad", :why)
    end
  end

  describe "String.Chars" do
    test "formats with and without an HTTP status" do
      assert to_string(Error.new(:validation_error, "bad")) == "[validation_error] bad"

      assert to_string(Error.from_response(404, %{"error" => %{"message" => "nope"}})) ==
               "[not_found (HTTP 404)] nope"
    end
  end
end

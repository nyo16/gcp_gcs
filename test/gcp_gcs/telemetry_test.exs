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
end

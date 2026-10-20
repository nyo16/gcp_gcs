defmodule GcpGcs.Telemetry do
  @moduledoc """
  Telemetry events emitted by `GcpGcs`.

  ## Request events

  All operations are wrapped with `:telemetry.span/3` under the
  `[:gcp_gcs, :request]` prefix:

    * `[:gcp_gcs, :request, :start]` — `%{system_time, monotonic_time}`
    * `[:gcp_gcs, :request, :stop]` — `%{duration, monotonic_time}`
    * `[:gcp_gcs, :request, :exception]` — when the wrapped function raises

  Metadata carries the operation context. Typical keys:

    * `:operation` — atom, e.g. `:create_bucket`, `:get_object`, `:upload`, `:download`
    * `:bucket` — bucket name (when applicable)
    * `:object` — object name (when applicable)
    * `:source` / `:destination` — **local file paths** for `upload_file/4`
      and `download_to_file/4`; treat them as sensitive before exporting
    * `:result` — `:ok` for success, `{:error, code}` for known errors

  ## Auth events

  Token fetches emit `[:gcp_gcs, :auth, _]` with the same three suffixes.
  Stop metadata includes `:source` (`:goth | :gcloud`).

  ## Example

      :telemetry.attach(
        "gcp-gcs-logger",
        [:gcp_gcs, :request, :stop],
        fn _event, %{duration: duration}, %{operation: op, result: result}, _config ->
          ms = System.convert_time_unit(duration, :native, :millisecond)
          Logger.info("gcs \#{op} -> \#{inspect(result)} in \#{ms}ms")
        end,
        nil
      )
  """

  @event_prefix [:gcp_gcs, :request]
  @auth_event_prefix [:gcp_gcs, :auth]

  @spec span(atom(), map(), (-> result)) :: result when result: var
  def span(operation, metadata, fun) when is_atom(operation) and is_map(metadata) do
    start_meta = Map.put(metadata, :operation, operation)

    :telemetry.span(@event_prefix, start_meta, fn ->
      result = fun.()
      {result, Map.put(start_meta, :result, classify(result))}
    end)
  end

  @spec auth_span(map(), (-> result)) :: result when result: var
  def auth_span(metadata, fun) when is_map(metadata) do
    :telemetry.span(@auth_event_prefix, metadata, fn ->
      result = fun.()
      {result, Map.put(metadata, :result, classify(result))}
    end)
  end

  defp classify(:ok), do: :ok
  defp classify({:ok, _}), do: :ok
  defp classify({:error, %GcpGcs.Error{code: code}}), do: {:error, code}
  defp classify({:error, _}), do: {:error, :unknown}
  defp classify(_), do: :unknown
end

defmodule GcpGcs.Telemetry do
  @moduledoc """
  Telemetry events emitted by `GcpGcs`.

  ## Request events

  Every public operation is wrapped with `:telemetry.span/3` under the
  `[:gcp_gcs, :request]` prefix:

    * `[:gcp_gcs, :request, :start]` — `%{system_time, monotonic_time}`
    * `[:gcp_gcs, :request, :stop]` — `%{duration, monotonic_time}`
    * `[:gcp_gcs, :request, :exception]` — when the operation raises

  The span is **operation-scoped**, not per HTTP request: its duration
  includes authentication, retries and every HTTP call the operation makes
  (all chunks of a resumable upload, every step of a rewrite). Each page of
  `stream_objects!/2` / `stream_buckets!/2` is its own `:list_*` span.

  Metadata:

    * `:operation` — the function, one of `:create_bucket`, `:get_bucket`,
      `:list_buckets`, `:delete_bucket`, `:update_bucket`, `:get_object`,
      `:list_objects`, `:delete_object`, `:update_object`, `:copy_object`,
      `:compose_object`, `:rewrite_object`, `:move_object`, `:put_object`,
      `:upload_file`, `:upload_stream`, `:start_resumable_upload`,
      `:upload_chunk`, `:download`, `:download_to_file`, `:download_stream`
    * `:bucket` and `:object` — always present (`nil` when not applicable);
      for copy, rewrite and move they name the **destination**, with the
      source in `:src_bucket` / `:src_object`
    * `:strategy` — `:simple | :resumable` for uploads
    * `:project_id` — for bucket creation and listing
    * `:source` / `:destination` — **local file paths** for `upload_file/4`
      and `download_to_file/4`; treat them as sensitive before exporting
    * `:result` (stop only) — `:ok` for success, `{:error, code}` for errors

  ## Auth events

  `[:gcp_gcs, :auth, _]` (same three suffixes) is emitted when the gcloud
  fallback actually runs `gcloud`: on a cache miss or refresh, not on cached
  reads. Stop metadata includes `:source` (`:gcloud`) and `:result`. Goth
  token reads are not reported here; Goth emits its own telemetry for its
  refreshes.

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

  @doc false
  @spec span(atom(), map(), (-> result)) :: result when result: var
  def span(operation, metadata, fun) when is_atom(operation) and is_map(metadata) do
    start_meta =
      %{bucket: nil, object: nil}
      |> Map.merge(metadata)
      |> Map.put(:operation, operation)

    :telemetry.span(@event_prefix, start_meta, fn ->
      result = fun.()
      {result, Map.put(start_meta, :result, classify(result))}
    end)
  end

  @doc false
  @spec auth_span(map(), (-> result)) :: result when result: var
  def auth_span(metadata, fun) when is_map(metadata) do
    :telemetry.span(@auth_event_prefix, metadata, fn ->
      result = fun.()
      {result, Map.put(metadata, :result, classify(result))}
    end)
  end

  defp classify(:ok), do: :ok
  defp classify({:ok, _}), do: :ok
  defp classify({:ok, _, _}), do: :ok
  defp classify({:resume, _}), do: :ok
  defp classify({:error, %GcpGcs.Error{code: code}}), do: {:error, code}
  defp classify({:error, _}), do: {:error, :unknown}
  defp classify(_), do: :unknown
end

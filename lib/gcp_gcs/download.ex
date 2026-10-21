defmodule GcpGcs.Download do
  @moduledoc """
  Downloads object contents from Google Cloud Storage.

  All downloads use the JSON API media endpoint (`?alt=media`). `download/3`
  buffers the whole object in memory; `download_to_file/4` and `stream/5` stream
  the body in chunks for constant-memory transfers of large objects.

  Exposed through the top-level `GcpGcs` module.
  """

  alias GcpGcs.{Client, Error, Telemetry, Validation}

  @doc """
  Downloads an object and returns its full contents as a binary.

  Prefer `download_to_file/4` or `stream/5` for large objects.

  ## Options
  - `:generation` — a specific object generation
  - `:timeout` — request timeout in ms
  """
  @spec download(String.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def download(bucket, object, opts \\ []) do
    Telemetry.span(:download, %{bucket: bucket, object: object}, fn ->
      do_download(bucket, object, opts)
    end)
  end

  defp do_download(bucket, object, opts) do
    with {:ok, _} <- Validation.validate_location(bucket, object) do
      reducer = fn
        {:data, chunk}, acc -> [acc, chunk]
        _other, acc -> acc
      end

      case stream_media(bucket, object, opts, [], reducer) do
        {:ok, {_status, _headers, iodata}} -> {:ok, IO.iodata_to_binary(iodata)}
        {:error, %Error{}} = error -> error
      end
    end
  end

  @doc """
  Streams an object's contents to a local file at `path`, using constant memory.

  The body is written to `path <> ".part"` and renamed to `path` only once the
  download completes, so a partial file never appears at `path`. On any
  error the `.part` file is removed. Write failures return
  `{:error, %GcpGcs.Error{code: :io_error}}`.

  Returns `:ok`.
  """
  @spec download_to_file(String.t(), String.t(), Path.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def download_to_file(bucket, object, path, opts \\ []) do
    Telemetry.span(:download, %{bucket: bucket, object: object, destination: path}, fn ->
      do_download_to_file(bucket, object, path, opts)
    end)
  end

  defp do_download_to_file(bucket, object, path, opts) do
    part = path <> ".part"

    with {:ok, _} <- Validation.validate_location(bucket, object),
         {:ok, io} <- open_file(part) do
      result =
        try do
          stream_media(bucket, object, opts, {io, :ok}, &write_chunk/2)
        after
          File.close(io)
        end

      finish_to_file(result, part, path)
    end
  end

  # Accumulator is `{device, :ok | {:io_error, reason}}`; after the first
  # failed write the remaining chunks are skipped.
  defp write_chunk({:data, chunk}, {device, :ok}) do
    case :file.write(device, chunk) do
      :ok -> {device, :ok}
      {:error, reason} -> {device, {:io_error, reason}}
    end
  end

  defp write_chunk(_other, acc), do: acc

  defp finish_to_file({:ok, {_status, _headers, {_device, :ok}}}, part, path) do
    case File.rename(part, path) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(part)
        {:error, Error.new(:io_error, "could not move download into place at #{path}", reason)}
    end
  end

  defp finish_to_file({:ok, {_status, _headers, {_device, {:io_error, reason}}}}, part, _path) do
    _ = File.rm(part)
    {:error, Error.new(:io_error, "could not write #{part}", reason)}
  end

  defp finish_to_file({:error, %Error{}} = error, part, _path) do
    _ = File.rm(part)
    error
  end

  @doc """
  Streams an object's contents through `reducer`, folding from `acc`.

  `reducer` receives `{:headers, headers}` once, then `{:data, binary}` for each
  body chunk, returning the updated accumulator. Returns `{:ok, acc}`.

  ## Example

      # Count bytes without buffering the object
      {:ok, total} =
        GcpGcs.Download.stream("my-bucket", "big.bin", [], 0, fn
          {:data, chunk}, n -> n + byte_size(chunk)
          _other, n -> n
        end)
  """
  @spec stream(String.t(), String.t(), keyword(), acc, (term(), acc -> acc)) ::
          {:ok, acc} | {:error, Error.t()}
        when acc: term()
  def stream(bucket, object, opts, acc, reducer) do
    Telemetry.span(:download, %{bucket: bucket, object: object}, fn ->
      do_stream(bucket, object, opts, acc, reducer)
    end)
  end

  defp do_stream(bucket, object, opts, acc, reducer) do
    with {:ok, _} <- Validation.validate_location(bucket, object),
         {:ok, _} <- Validation.validate_reducer(reducer) do
      case stream_media(bucket, object, opts, acc, reducer) do
        {:ok, {_status, _headers, final_acc}} -> {:ok, final_acc}
        {:error, %Error{}} = error -> error
      end
    end
  end

  # Private

  defp stream_media(bucket, object, opts, acc, reducer) do
    query = [alt: "media", generation: opts[:generation]]

    Client.stream(
      :get,
      Client.object_path(bucket, object),
      [query: query] ++ Client.transport_opts(opts),
      acc,
      reducer
    )
  end

  defp open_file(path) do
    case File.open(path, [:write, :binary]) do
      {:ok, io} ->
        {:ok, io}

      {:error, reason} ->
        {:error, Error.new(:io_error, "could not open #{path} for writing", reason)}
    end
  end
end

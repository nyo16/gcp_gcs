defmodule GcpGcs.Download do
  @moduledoc """
  Downloads object contents from Google Cloud Storage.

  All downloads use the JSON API media endpoint (`?alt=media`). `download/3`
  buffers the whole object in memory; `download_to_file/4` and `stream/5` stream
  the body in chunks for constant-memory transfers of large objects.

  Every function also accepts the transport options `:timeout`,
  `:pool_timeout`, `:retry`, `:finch`, `:goth` and `:base_url` (see
  `GcpGcs.Config`). Unknown options return
  `{:error, %GcpGcs.Error{code: :validation_error}}`.

  Exposed through the top-level `GcpGcs` module.
  """

  alias GcpGcs.{Client, Error, Telemetry, Validation}

  @opts [:generation, :range]

  @doc """
  Downloads an object and returns its full contents as a binary.

  The body is buffered and then flattened into that one binary, so peak
  memory is about twice the object size. For large objects use
  `download_to_file/4` or `stream/5` (`GcpGcs.download_stream/5`), which use
  constant memory.

  ## Options
  - `:generation` — a specific object generation
  - `:range` — only these bytes: `first..last` or `{first, last}` (inclusive,
    0-based; `{first, nil}` reads to the end). Sent as `Range: bytes=first-last`;
    a `206 Partial Content` response is a success.
  """
  @spec download(String.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def download(bucket, object, opts \\ []) do
    Telemetry.span(:download, %{bucket: bucket, object: object}, fn ->
      reducer = fn
        {:data, chunk}, acc -> [acc, chunk]
        _other, acc -> acc
      end

      with {:ok, _} <- validate(bucket, object, opts),
           {:ok, {_status, _headers, iodata}} <- stream_media(bucket, object, opts, [], reducer) do
        {:ok, IO.iodata_to_binary(iodata)}
      end
    end)
  end

  @doc """
  Streams an object's contents to a local file at `path`, using constant memory.

  The body is written to `path <> ".part"` and renamed to `path` only once the
  download completes, so a partial file never appears at `path`. On any
  error the `.part` file is removed. Write failures stop the download and
  return `{:error, %GcpGcs.Error{code: :io_error}}`.

  Takes the options of `download/3`. Returns `:ok`.
  """
  @spec download_to_file(String.t(), String.t(), Path.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def download_to_file(bucket, object, path, opts \\ []) do
    Telemetry.span(
      :download_to_file,
      %{bucket: bucket, object: object, destination: path},
      fn ->
        with {:ok, _} <- validate(bucket, object, opts) do
          do_download_to_file(bucket, object, path, opts)
        end
      end
    )
  end

  defp do_download_to_file(bucket, object, path, opts) do
    part = path <> ".part"

    with {:ok, io} <- open_file(part) do
      result =
        try do
          stream_media(bucket, object, opts, {io, :ok}, &write_chunk/2)
        catch
          kind, reason ->
            _ = File.close(io)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      result
      |> closed(File.close(io))
      |> finish_to_file(part, path)
    end
  end

  # Writes are buffered (delayed_write), so a write error can first surface
  # when the file is closed: a download is only complete once that succeeds.
  defp closed({:ok, {status, headers, {device, :ok}}}, {:error, reason}),
    do: {:ok, {status, headers, {device, {:io_error, reason}}}}

  defp closed(result, _close_result), do: result

  # Accumulator is `{device, :ok | {:io_error, reason}}`; the first failed
  # write stops reading the body.
  defp write_chunk({:data, chunk}, {device, :ok}) do
    case :file.write(device, chunk) do
      :ok -> {device, :ok}
      {:error, reason} -> {:halt, {device, {:io_error, reason}}}
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
  body chunk. It returns the updated accumulator (or `{:cont, acc}`), or
  `{:halt, acc}` to stop reading the body early. Returns `{:ok, acc}`.

  Takes the options of `download/3`, including `:range`.

  ## Example

      # Count bytes without buffering the object
      {:ok, total} =
        GcpGcs.Download.stream("my-bucket", "big.bin", 0, fn
          {:data, chunk}, n -> n + byte_size(chunk)
          _other, n -> n
        end)

  ## Deprecated argument order

  Before 0.3.0 the order was `stream(bucket, object, opts, acc, reducer)`.
  That order is still accepted for one release, with a warning: a call whose
  **fifth** argument is an arity-2 function and whose third is a keyword list
  is read as the old order. In the new order the fifth argument is the
  options list, so it is never a function. (If `acc` is itself an arity-2
  function, pass the new order — `stream(b, o, acc, reducer)` — which is
  never ambiguous.)
  """
  @spec stream(String.t(), String.t(), acc, (term(), acc -> term()), keyword()) ::
          {:ok, acc} | {:error, Error.t()}
        when acc: term()
  def stream(bucket, object, acc, reducer, opts \\ [])

  def stream(bucket, object, opts, acc, reducer)
      when is_list(opts) and is_function(reducer, 2) do
    if Keyword.keyword?(opts) do
      IO.warn(
        "GcpGcs.download_stream(bucket, object, opts, acc, reducer) is deprecated; " <>
          "use download_stream(bucket, object, acc, reducer, opts)"
      )

      stream(bucket, object, acc, reducer, opts)
    else
      do_stream(bucket, object, opts, acc, reducer)
    end
  end

  def stream(bucket, object, acc, reducer, opts),
    do: do_stream(bucket, object, acc, reducer, opts)

  defp do_stream(bucket, object, acc, reducer, opts) do
    Telemetry.span(:download_stream, %{bucket: bucket, object: object}, fn ->
      with {:ok, _} <- validate(bucket, object, opts),
           {:ok, _} <- Validation.validate_reducer(reducer),
           {:ok, {_status, _headers, final_acc}} <-
             stream_media(bucket, object, opts, acc, reducer) do
        {:ok, final_acc}
      end
    end)
  end

  # Private

  defp validate(bucket, object, opts) do
    with {:ok, _} <- Validation.validate_opts(opts, @opts ++ Client.transport_keys()) do
      Validation.validate_location(bucket, object)
    end
  end

  defp stream_media(bucket, object, opts, acc, reducer) do
    query = [alt: "media", generation: opts[:generation]]

    with {:ok, headers} <- range_headers(Keyword.get(opts, :range)) do
      Client.stream(
        :get,
        Client.object_path(bucket, object),
        [query: query, headers: headers] ++ Client.transport_opts(opts),
        acc,
        reducer
      )
    end
  end

  defp range_headers(nil), do: {:ok, []}

  defp range_headers(first..last//1) when first >= 0 and last >= first,
    do: {:ok, [{"range", "bytes=#{first}-#{last}"}]}

  defp range_headers({first, nil}) when is_integer(first) and first >= 0,
    do: {:ok, [{"range", "bytes=#{first}-"}]}

  defp range_headers({first, last})
       when is_integer(first) and is_integer(last) and first >= 0 and last >= first,
       do: {:ok, [{"range", "bytes=#{first}-#{last}"}]}

  defp range_headers(_range) do
    {:error,
     Error.new(
       :validation_error,
       ":range must be first..last or {first, last} with 0 <= first <= last"
     )}
  end

  # Raw and buffered: the reducer that writes runs in this process (which owns
  # the raw file), and 1 MiB batches replace a file-server message and a
  # write(2) per ~16 KiB body chunk.
  defp open_file(path) do
    case File.open(path, [:raw, :write, :binary, {:delayed_write, 1_048_576, 2_000}]) do
      {:ok, io} ->
        {:ok, io}

      {:error, reason} ->
        {:error, Error.new(:io_error, "could not open #{path} for writing", reason)}
    end
  end
end

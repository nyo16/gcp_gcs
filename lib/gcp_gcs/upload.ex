defmodule GcpGcs.Upload do
  @moduledoc """
  Uploads object contents to Google Cloud Storage.

  Two strategies:

    * **Simple** (`put_object/4`) — a single request for in-memory data.
    * **Resumable** (`upload_file/4`, `upload_stream/4`) — initiates a resumable
      session then streams the body, using constant memory. Best for large
      objects and for data produced incrementally.

  Low-level resumable primitives (`start_resumable_upload/3`, `upload_chunk/3`)
  are provided for callers that need manual control over chunking and retries.

  Successful uploads return the decoded
  [Object resource](https://cloud.google.com/storage/docs/json_api/v1/objects).

  Exposed through the top-level `GcpGcs` module.
  """

  alias GcpGcs.{Client, Config, Error, Telemetry, Validation}

  @default_content_type "application/octet-stream"
  # Resumable chunk sizes must be multiples of 256 KiB (except the final chunk).
  @chunk_multiple 256 * 1024
  @default_chunk_size 8 * 1024 * 1024

  @doc """
  Uploads in-memory `data` in a single request (simple upload).

  ## Options
  - `:content_type` — defaults to `"application/octet-stream"`
  - `:predefined_acl` — e.g. `"publicRead"`
  - `:timeout` — request timeout in ms
  """
  @spec put_object(String.t(), String.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def put_object(bucket, object, data, opts \\ []) do
    Telemetry.span(:upload, %{bucket: bucket, object: object, strategy: :simple}, fn ->
      do_put_object(bucket, object, data, opts)
    end)
  end

  @doc """
  Uploads from a source, choosing a strategy automatically:

    * a binary → simple upload (`put_object/4`)
    * `{:file, path}` → resumable streamed upload (`upload_file/4`)
    * an `Enumerable` of binaries → resumable streamed upload (`upload_stream/4`)
  """
  @spec upload(String.t(), String.t(), binary() | {:file, Path.t()} | Enumerable.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def upload(bucket, object, source, opts \\ [])

  def upload(bucket, object, data, opts) when is_binary(data) do
    put_object(bucket, object, data, opts)
  end

  def upload(bucket, object, {:file, path}, opts) do
    upload_file(bucket, object, path, opts)
  end

  def upload(bucket, object, enum, opts) do
    upload_stream(bucket, object, enum, opts)
  end

  @doc """
  Uploads a local file using a resumable session, streaming it in one request
  with constant memory.

  Content type defaults to a guess from the object's extension.

  ## Options
  - `:content_type` — overrides the guessed content type
  - `:chunk_size` — read size in bytes (rounded to a 256 KiB multiple)
  - `:attrs` — Object resource metadata to set on the new object
  - `:timeout` — request timeout in ms
  """
  @spec upload_file(String.t(), String.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def upload_file(bucket, object, path, opts \\ []) do
    Telemetry.span(
      :upload,
      %{bucket: bucket, object: object, strategy: :resumable, source: path},
      fn ->
        with {:ok, _} <- Validation.validate_bucket(bucket),
             {:ok, _} <- Validation.validate_object(object),
             {:ok, %File.Stat{size: size}} <- stat(path) do
          opts = Keyword.put_new(opts, :content_type, content_type(object, opts))
          upload_file_body(bucket, object, path, size, opts)
        end
      end
    )
  end

  @doc """
  Uploads from an `Enumerable` of binaries using a resumable session.

  The data is rebuffered into 256 KiB-aligned chunks and sent incrementally, so
  the total size need not be known up front and memory stays bounded.

  ## Options
  - `:content_type` — defaults to `"application/octet-stream"`
  - `:chunk_size` — chunk size in bytes (rounded to a 256 KiB multiple)
  - `:attrs` — Object resource metadata to set on the new object
  - `:timeout` — per-request timeout in ms
  """
  @spec upload_stream(String.t(), String.t(), Enumerable.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def upload_stream(bucket, object, enum, opts \\ []) do
    Telemetry.span(:upload, %{bucket: bucket, object: object, strategy: :resumable}, fn ->
      with {:ok, _} <- Validation.validate_bucket(bucket),
           {:ok, _} <- Validation.validate_object(object),
           {:ok, session} <- start_resumable_upload(bucket, object, opts) do
        stream_to_session(session, enum, chunk_size(opts), opts)
      end
    end)
  end

  @doc """
  Initiates a resumable upload session and returns its session URI.

  ## Options
  - `:content_type` — value sent as `X-Upload-Content-Type`
  - `:attrs` — Object resource metadata (sent as the JSON request body)
  - `:origin` — browser origin to forward as the `Origin` header. Required for
    browser-based resumable uploads (initiate the session server-side, hand the
    session URI to the browser): GCS only returns CORS headers on requests to
    the session URI if the session was initiated with an `Origin` — the
    bucket's CORS configuration alone does not apply. Must be the origin the
    browser will upload from. Mirrors `origin` in Google's official clients
    (e.g. `createResumableUpload` in google-cloud-node,
    `Blob.create_resumable_upload_session` in google-cloud-python).
  - `:timeout` — request timeout in ms
  """
  @spec start_resumable_upload(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def start_resumable_upload(bucket, object, opts \\ []) do
    with {:ok, _} <- Validation.validate_bucket(bucket),
         {:ok, _} <- Validation.validate_object(object) do
      do_start_resumable_upload(bucket, object, opts)
    end
  end

  defp do_start_resumable_upload(bucket, object, opts) do
    url = Config.upload_base() <> "/b/#{bucket}/o"
    query = compact(uploadType: "resumable", name: object, predefinedAcl: opts[:predefined_acl])
    ct = opts[:content_type] || @default_content_type

    # GCS returns 411 Length Required if the initiation POST has no
    # Content-Length. Finch/Mint set it automatically for a binary (JSON) body,
    # but a bodyless request needs it declared explicitly as 0. (The
    # fake-gcs-server emulator used in tests does not enforce this, so the
    # failure only surfaces against the real API.)
    {body, headers} =
      case opts[:attrs] do
        nil -> {nil, [{"content-length", "0"}, {"x-upload-content-type", ct}]}
        attrs -> {{:json, attrs}, [{"x-upload-content-type", ct}]}
      end

    headers = put_origin(headers, opts)

    case Client.raw_request(:post, url,
           query: query,
           headers: headers,
           body: body,
           timeout: opts[:timeout]
         ) do
      {:ok, %Finch.Response{status: status} = resp} when status in 200..299 ->
        case location_header(resp.headers) do
          nil ->
            {:error, Error.new(:internal, "resumable upload session missing Location header")}

          uri ->
            {:ok, uri}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, Error.from_response(status, decode_body(body))}

      {:error, %Error{}} = error ->
        error
    end
  end

  @doc """
  Uploads a single chunk to a resumable `session_uri`.

  ## Options (required: `:offset`)
  - `:offset` — byte offset of this chunk within the object
  - `:total` — total object size if known, or `nil`/omitted for the streaming
    case (intermediate chunks send `/*`)
  - `:timeout` — request timeout in ms

  ## Returns
  - `{:resume, next_offset}` — chunk stored, more expected (HTTP 308)
  - `{:ok, object}` — upload complete (HTTP 200/201)
  - `{:error, %GcpGcs.Error{}}`
  """
  @spec upload_chunk(String.t(), binary(), keyword()) ::
          {:ok, map()} | {:resume, non_neg_integer()} | {:error, Error.t()}
  def upload_chunk(session_uri, data, opts) when is_binary(data) do
    offset = Keyword.fetch!(opts, :offset)
    total = Keyword.get(opts, :total)
    headers = [{"content-range", content_range(offset, byte_size(data), total)}]
    body = {:binary, data, @default_content_type}

    case Client.raw_request(:put, session_uri,
           headers: headers,
           body: body,
           timeout: opts[:timeout]
         ) do
      {:ok, %Finch.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, decode_body(body)}

      {:ok, %Finch.Response{status: 308} = resp} ->
        {:resume, next_offset(resp.headers, offset, byte_size(data))}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, Error.from_response(status, decode_body(body))}

      {:error, %Error{}} = error ->
        error
    end
  end

  # Private --------------------------------------------------------------------

  defp do_put_object(bucket, object, data, opts) do
    with {:ok, _} <- Validation.validate_bucket(bucket),
         {:ok, _} <- Validation.validate_object(object),
         {:ok, _} <- Validation.validate_binary(data, "data") do
      url = Config.upload_base() <> "/b/#{bucket}/o"
      query = compact(uploadType: "media", name: object, predefinedAcl: opts[:predefined_acl])
      ct = opts[:content_type] || @default_content_type
      Client.request(:post, url, query: query, body: {:binary, data, ct}, timeout: opts[:timeout])
    end
  end

  defp upload_file_body(bucket, object, _path, 0, opts) do
    # Empty file: a simple upload is simplest and correct.
    do_put_object(bucket, object, "", opts)
  end

  defp upload_file_body(bucket, object, path, size, opts) do
    with {:ok, session} <- start_resumable_upload(bucket, object, opts) do
      body = {:stream, File.stream!(path, chunk_size(opts)), opts[:content_type]}

      # Declaring Content-Length keeps Mint from sending the stream body with
      # transfer-encoding: chunked, which GCS rejects with 411 on the session
      # PUT. The size is known from File.stat here, so this costs nothing.
      headers = [
        {"content-range", content_range(0, size, size)},
        {"content-length", Integer.to_string(size)}
      ]

      case Client.raw_request(:put, session,
             headers: headers,
             body: body,
             timeout: opts[:timeout]
           ) do
        {:ok, %Finch.Response{status: status, body: body}} when status in [200, 201] ->
          {:ok, decode_body(body)}

        {:ok, %Finch.Response{status: status, body: body}} ->
          {:error, Error.from_response(status, decode_body(body))}

        {:error, %Error{}} = error ->
          error
      end
    end
  end

  # Folds an enumerable into the resumable session: full chunks are sent as
  # intermediate PUTs (`/*`); the remainder is finalized with the known total.
  defp stream_to_session(session, enum, chunk, opts) do
    result =
      Enum.reduce_while(enum, {:ok, 0, ""}, fn data, {:ok, offset, buf} ->
        case flush_chunks(session, offset, buf <> data, chunk, opts) do
          {:ok, new_offset, rest} -> {:cont, {:ok, new_offset, rest}}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, offset, buf} -> finalize(session, offset, buf, opts)
      {:error, %Error{}} = error -> error
    end
  end

  defp flush_chunks(session, offset, buf, chunk, opts) when byte_size(buf) >= chunk do
    <<piece::binary-size(^chunk), rest::binary>> = buf

    case upload_chunk(session, piece, offset: offset, total: nil, timeout: opts[:timeout]) do
      {:resume, next} ->
        flush_chunks(session, next, rest, chunk, opts)

      {:ok, _object} ->
        {:error, Error.new(:internal, "resumable upload finished before final chunk")}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp flush_chunks(_session, offset, buf, _chunk, _opts), do: {:ok, offset, buf}

  defp finalize(session, offset, buf, opts) do
    total = offset + byte_size(buf)

    case upload_chunk(session, buf, offset: offset, total: total, timeout: opts[:timeout]) do
      {:ok, object} ->
        {:ok, object}

      {:resume, _next} ->
        {:error, Error.new(:internal, "resumable upload did not complete on finalize")}

      {:error, %Error{}} = error ->
        error
    end
  end

  # Forward the browser Origin so GCS CORS-tags the session; without it the
  # subsequent browser PUT succeeds (200) but its response carries no
  # Access-Control-Allow-Origin header, so the browser blocks reading it and
  # the upload is reported as failed client-side.
  defp put_origin(headers, opts) do
    case opts[:origin] do
      origin when is_binary(origin) -> [{"origin", origin} | headers]
      _ -> headers
    end
  end

  defp stat(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, Error.new(:io_error, "could not stat #{path}", reason)}
    end
  end

  @doc false
  @spec content_range(non_neg_integer(), non_neg_integer(), non_neg_integer() | nil) :: String.t()
  def content_range(_offset, 0, total) when is_integer(total), do: "bytes */#{total}"
  def content_range(offset, len, nil), do: "bytes #{offset}-#{offset + len - 1}/*"

  def content_range(offset, len, total) when is_integer(total),
    do: "bytes #{offset}-#{offset + len - 1}/#{total}"

  @doc false
  @spec next_offset([{String.t(), String.t()}], non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def next_offset(headers, offset, len) do
    with {_k, value} <- List.keyfind(headers, "range", 0),
         [_, last] <- Regex.run(~r/(\d+)\s*$/, value) do
      String.to_integer(last) + 1
    else
      _ -> offset + len
    end
  end

  @doc false
  @spec chunk_size(keyword()) :: pos_integer()
  def chunk_size(opts) do
    requested = Keyword.get(opts, :chunk_size, @default_chunk_size)
    multiples = max(div(requested, @chunk_multiple), 1)
    multiples * @chunk_multiple
  end

  defp content_type(object, opts) do
    opts[:content_type] || guess_content_type(object)
  end

  @content_types %{
    ".txt" => "text/plain",
    ".json" => "application/json",
    ".csv" => "text/csv",
    ".html" => "text/html",
    ".htm" => "text/html",
    ".css" => "text/css",
    ".js" => "text/javascript",
    ".xml" => "application/xml",
    ".pdf" => "application/pdf",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".svg" => "image/svg+xml",
    ".zip" => "application/zip",
    ".gz" => "application/gzip",
    ".mp4" => "video/mp4"
  }

  defp guess_content_type(object) do
    ext = object |> Path.extname() |> String.downcase()
    Map.get(@content_types, ext, @default_content_type)
  end

  defp location_header(headers), do: header_value(headers, "location")

  defp header_value(headers, name) do
    case Enum.find(headers, fn {k, _v} -> String.downcase(k) == name end) do
      {_k, value} -> value
      nil -> nil
    end
  end

  defp decode_body(body) when is_binary(body) and body != "" do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode_body(_), do: %{}

  defp compact(pairs), do: Enum.reject(pairs, fn {_k, v} -> is_nil(v) end)
end

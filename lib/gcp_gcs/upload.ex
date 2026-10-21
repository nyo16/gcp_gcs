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

  alias GcpGcs.{Client, Error, Telemetry, Validation}

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

  Any other source returns `{:error, %GcpGcs.Error{code: :validation_error}}`
  without making a request.
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
        with {:ok, _} <- Validation.validate_location(bucket, object),
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
      with {:ok, _} <- Validation.validate_location(bucket, object),
           {:ok, _} <- Validation.validate_enumerable(enum, "source"),
           {:ok, session} <- start_resumable_upload(bucket, object, opts) do
        stream_to_session(session, enum, chunk_size(opts), opts)
      end
    end)
  end

  @doc """
  Initiates a resumable upload session and returns its session URI.

  The session URI is a bearer capability: whoever holds it can upload the
  object until the session expires, without other credentials. Never log it,
  and hand it only to the user it was created for.

  ## Options
  - `:content_type` — value sent as `X-Upload-Content-Type`
  - `:attrs` — Object resource metadata (sent as the JSON request body)
  - `:origin` — browser origin to forward as the `Origin` header. Required for
    browser-based resumable uploads (initiate the session server-side, hand the
    session URI to the browser): GCS only returns CORS headers on requests to
    the session URI if the session was initiated with an `Origin` — the
    bucket's CORS configuration alone does not apply. Must be the origin the
    browser will upload from, taken from an allow-list of your own origins —
    never echoed from an incoming request. Mirrors `origin` in Google's official clients
    (e.g. `createResumableUpload` in google-cloud-node,
    `Blob.create_resumable_upload_session` in google-cloud-python).
  - `:timeout` — request timeout in ms
  """
  @spec start_resumable_upload(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def start_resumable_upload(bucket, object, opts \\ []) do
    with {:ok, _} <- Validation.validate_location(bucket, object) do
      do_start_resumable_upload(bucket, object, opts)
    end
  end

  defp do_start_resumable_upload(bucket, object, opts) do
    query = [uploadType: "resumable", name: object, predefinedAcl: opts[:predefined_acl]]
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

    request_opts =
      [api: :upload, query: query, headers: put_origin(headers, opts), body: body] ++
        Client.transport_opts(opts)

    with {:ok, _status, resp_headers, _body} <-
           Client.exchange(:post, "/b/#{bucket}/o", request_opts) do
      case header_value(resp_headers, "location") do
        nil -> {:error, Error.new(:internal, "resumable upload session missing Location header")}
        uri -> {:ok, uri}
      end
    end
  end

  @doc """
  Uploads a single chunk to a resumable `session_uri`.

  `session_uri` must be a URI returned by `start_resumable_upload/3`: it is
  checked against the configured endpoint (scheme, host, port and the
  `/upload/storage/v1/` path) and rejected with `:validation_error` otherwise.
  The session URI is itself the credential, so no `authorization` header is
  sent with the chunk.

  ## Options (required: `:offset`)
  - `:offset` — byte offset of this chunk within the object
  - `:total` — total object size if known, or `nil`/omitted for the streaming
    case (intermediate chunks send `/*`)
  - `:timeout` — request timeout in ms

  ## Returns
  - `{:resume, persisted}` — the session holds bytes `0..persisted - 1` and
    expects more (HTTP 308). `persisted` may be less than `offset +
    byte_size(data)`: resend from `persisted`.
  - `{:ok, object}` — upload complete (HTTP 200/201)
  - `{:error, %GcpGcs.Error{}}`
  """
  @spec upload_chunk(String.t(), binary(), keyword()) ::
          {:ok, map()} | {:resume, non_neg_integer()} | {:error, Error.t()}
  def upload_chunk(session_uri, data, opts) do
    with {:ok, _} <- Validation.validate_session_uri(session_uri),
         {:ok, _} <- Validation.validate_binary(data, "data"),
         {:ok, offset} <- Validation.validate_non_neg_integer(opts[:offset], ":offset"),
         {:ok, total} <- Validation.validate_optional_non_neg_integer(opts[:total], ":total") do
      do_upload_chunk(session_uri, data, offset, total, opts)
    end
  end

  defp do_upload_chunk(session_uri, data, offset, total, opts) do
    request_opts =
      [
        headers: [{"content-range", content_range(offset, byte_size(data), total)}],
        body: {:binary, data, @default_content_type},
        # The session URI is the credential: no bearer token on session PUTs.
        auth: false,
        expect: [200, 201, 308]
      ] ++ Client.transport_opts(opts)

    case Client.exchange(:put, session_uri, request_opts) do
      {:ok, 308, headers, _body} ->
        case next_offset(headers) do
          {:ok, next} ->
            {:resume, next}

          :error ->
            {:error,
             Error.new(:internal, "malformed Range header in resumable upload response", headers)}
        end

      {:ok, _status, _headers, object} ->
        {:ok, object}

      {:error, %Error{}} = error ->
        error
    end
  end

  # Private --------------------------------------------------------------------

  defp do_put_object(bucket, object, data, opts) do
    with {:ok, _} <- Validation.validate_location(bucket, object),
         {:ok, _} <- Validation.validate_binary(data, "data") do
      query = [uploadType: "media", name: object, predefinedAcl: opts[:predefined_acl]]
      ct = opts[:content_type] || @default_content_type

      Client.request(
        :post,
        "/b/#{bucket}/o",
        [api: :upload, query: query, body: {:binary, data, ct}] ++ Client.transport_opts(opts)
      )
    end
  end

  defp upload_file_body(bucket, object, _path, 0, opts) do
    # Empty file: a simple upload is simplest and correct.
    do_put_object(bucket, object, "", opts)
  end

  defp upload_file_body(bucket, object, path, size, opts) do
    with {:ok, session} <- start_resumable_upload(bucket, object, opts),
         {:ok, _} <- Validation.validate_session_uri(session) do
      body = {:stream, File.stream!(path, chunk_size(opts)), opts[:content_type]}

      # Declaring Content-Length keeps Mint from sending the stream body with
      # transfer-encoding: chunked, which GCS rejects with 411 on the session
      # PUT. The size is known from File.stat here, so this costs nothing.
      headers = [
        {"content-range", content_range(0, size, size)},
        {"content-length", Integer.to_string(size)}
      ]

      # The session URI is the credential: no bearer token on the PUT.
      Client.request(
        :put,
        session,
        [headers: headers, body: body, auth: false, expect: [200, 201]] ++
          Client.transport_opts(opts)
      )
    end
  end

  # Folds an enumerable into the resumable session: full chunks are sent as
  # intermediate PUTs (`/*`); the remainder is finalized with the known total.
  defp stream_to_session(session, enum, chunk, opts) do
    result =
      Enum.reduce_while(enum, {:ok, 0, ""}, fn
        data, {:ok, offset, buf} when is_binary(data) ->
          case flush_chunks(session, offset, buf <> data, chunk, opts) do
            {:ok, new_offset, rest} -> {:cont, {:ok, new_offset, rest}}
            {:error, %Error{}} = error -> {:halt, error}
          end

        _data, _acc ->
          {:halt, {:error, Error.new(:validation_error, "source elements must be binaries")}}
      end)

    case result do
      {:ok, offset, buf} -> finalize(session, offset, buf, opts)
      {:error, %Error{}} = error -> error
    end
  end

  # `stalled?` records that the previous 308 made no progress. One stall is
  # tolerated (e.g. a 308 without `Range` on the first chunk: nothing persisted,
  # resend it), a second consecutive one is an error rather than a resend loop.
  defp flush_chunks(session, offset, buf, chunk, opts, stalled? \\ false)

  defp flush_chunks(session, offset, buf, chunk, opts, stalled?) when byte_size(buf) >= chunk do
    <<piece::binary-size(^chunk), rest::binary>> = buf

    case upload_chunk(session, piece, [offset: offset, total: nil] ++ Client.transport_opts(opts)) do
      {:resume, next} ->
        with {:ok, unsent, stalled?} <- unsent_tail(piece, offset, next, stalled?) do
          flush_chunks(session, next, prepend(unsent, rest), chunk, opts, stalled?)
        end

      {:ok, _object} ->
        {:error, Error.new(:internal, "resumable upload finished before final chunk")}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp flush_chunks(_session, offset, buf, _chunk, _opts, _stalled?), do: {:ok, offset, buf}

  defp finalize(session, offset, buf, opts, stalled? \\ false) do
    total = offset + byte_size(buf)

    case upload_chunk(session, buf, [offset: offset, total: total] ++ Client.transport_opts(opts)) do
      {:ok, object} ->
        {:ok, object}

      {:resume, next} ->
        with {:ok, unsent, stalled?} <- unsent_tail(buf, offset, next, stalled?) do
          finalize(session, next, unsent, opts, stalled?)
        end

      {:error, %Error{}} = error ->
        error
    end
  end

  # `sent` covered bytes `offset..offset + byte_size(sent) - 1`; the server
  # reports it has persisted bytes `0..next - 1`. Returns the bytes of `sent`
  # that still have to be (re)sent. Bytes before `offset` were already
  # discarded (streams can't be rewound), so a server behind `offset` is data
  # loss; a server ahead of what was sent is a protocol violation.
  defp unsent_tail(sent, offset, next, stalled?) do
    sent_end = offset + byte_size(sent)

    cond do
      next < offset ->
        {:error,
         Error.new(
           :data_loss,
           "resumable session persisted #{next} bytes, but bytes from #{next} to #{offset} " <>
             "were already discarded",
           %{persisted: next, offset: offset}
         )}

      next > sent_end ->
        {:error,
         Error.new(
           :internal,
           "resumable session reported #{next} bytes persisted, but only #{sent_end} were sent",
           %{persisted: next, sent: sent_end}
         )}

      next == offset and stalled? ->
        {:error,
         Error.new(
           :internal,
           "resumable upload made no progress at offset #{offset}",
           %{persisted: next, offset: offset}
         )}

      true ->
        {:ok, binary_part(sent, next - offset, sent_end - next), next == offset}
    end
  end

  defp prepend("", rest), do: rest
  defp prepend(unsent, rest), do: unsent <> rest

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
  # Bytes persisted by the session, from the `Range: bytes=0-N` header of a
  # 308. GCS omits the header when nothing has been persisted yet.
  @spec next_offset([{String.t(), String.t()}]) :: {:ok, non_neg_integer()} | :error
  def next_offset(headers) do
    case header_value(headers, "range") do
      nil ->
        {:ok, 0}

      value ->
        case Regex.run(~r/\A(?:bytes=)?0-(\d+)\z/, String.trim(value)) do
          [_, last] -> {:ok, String.to_integer(last) + 1}
          nil -> :error
        end
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

  defp header_value(headers, name) do
    case Enum.find(headers, fn {k, _v} -> String.downcase(k) == name end) do
      {_k, value} -> value
      nil -> nil
    end
  end
end

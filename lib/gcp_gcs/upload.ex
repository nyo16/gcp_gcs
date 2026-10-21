defmodule GcpGcs.Upload do
  @moduledoc """
  Uploads object contents to Google Cloud Storage.

  Two strategies:

    * **Simple** (`put_object/4`) — a single request for in-memory data.
    * **Resumable** (`upload_file/4`, `upload_stream/4`) — initiates a resumable
      session then sends the body in chunks, using bounded memory. Best for
      large objects and for data produced incrementally.

  Resumable uploads recover from transient failures (5xx, 408, 429, dropped
  connections): they ask the session how many bytes it has persisted and
  resume from there, within the retry budget of `GcpGcs.Config` (`retry:
  false` disables this). `upload_file/4` can re-read any part of the file;
  `upload_stream/4` can only resend the bytes it still holds (at most one
  chunk), and fails with `:data_loss` if the session lost more than that.

  The final request of a resumable upload carries an `X-Goog-Hash` MD5 of the
  whole object, so Cloud Storage rejects a corrupted upload (`checksum: false`
  disables it). Once a session exists, every error's `details` is
  `%{session_uri: uri, cause: original_details}` so callers can resume
  manually — the session URI is a bearer capability, never log it.

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

  @session_opts [:content_type, :attrs, :origin, :predefined_acl]
  @resumable_opts @session_opts ++ [:chunk_size, :checksum]
  @put_opts [:content_type, :predefined_acl, :attrs, :checksum]

  @doc """
  Uploads in-memory `data`.

  Without `:attrs` this is a single simple-upload request. With `:attrs` the
  upload goes through a resumable session with a known size and a single
  PUT, so the object metadata is applied (and the `X-Goog-Hash` MD5 is sent).

  ## Options
  - `:content_type` — defaults to `"application/octet-stream"`
  - `:predefined_acl` — e.g. `"publicRead"`
  - `:attrs` — Object resource metadata to set on the new object
  - `:checksum` — with `:attrs`, `false` skips the MD5 (default `true`)
  """
  @spec put_object(String.t(), String.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def put_object(bucket, object, data, opts \\ []) do
    strategy =
      if Keyword.keyword?(opts) and Keyword.get(opts, :attrs), do: :resumable, else: :simple

    Telemetry.span(:put_object, %{bucket: bucket, object: object, strategy: strategy}, fn ->
      with {:ok, _} <- validate_opts(opts, @put_opts),
           {:ok, _} <- Validation.validate_location(bucket, object),
           {:ok, _} <- Validation.validate_binary(data, "data"),
           {:ok, _} <- validate_headers(opts) do
        put_with(strategy, bucket, object, data, opts)
      end
    end)
  end

  defp put_with(:simple, bucket, object, data, opts),
    do: do_put_object(bucket, object, data, opts)

  defp put_with(:resumable, bucket, object, data, opts),
    do: resumable_put(bucket, object, data, opts)

  @doc """
  Uploads from a source, choosing a strategy automatically:

    * a binary → `put_object/4`
    * `{:file, path}` → resumable upload (`upload_file/4`)
    * an `Enumerable` of binaries → resumable streamed upload (`upload_stream/4`)

  Takes the options of the function it dispatches to. Any other source
  returns `{:error, %GcpGcs.Error{code: :validation_error}}` without making a
  request.
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
  Uploads a local file using a resumable session, in chunks read from disk
  (bounded memory). Transient failures resume from the persisted offset.

  Content type defaults to a guess from the object's extension. An empty
  file is a single simple upload, unless `:attrs` or `:origin` is given (then
  it goes through a resumable session, so they are applied).

  ## Options
  - `:content_type` — overrides the guessed content type
  - `:chunk_size` — bytes per request (rounded to a 256 KiB multiple;
    default 8 MiB)
  - `:attrs` — Object resource metadata to set on the new object
  - `:predefined_acl` — e.g. `"publicRead"`
  - `:origin` — see `start_resumable_upload/3`
  - `:checksum` — `false` to skip the `X-Goog-Hash` MD5 (default `true`)
  """
  @spec upload_file(String.t(), String.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def upload_file(bucket, object, path, opts \\ []) do
    Telemetry.span(
      :upload_file,
      %{bucket: bucket, object: object, strategy: :resumable, source: path},
      fn ->
        with {:ok, _} <- validate_opts(opts, @resumable_opts),
             {:ok, _} <- Validation.validate_location(bucket, object),
             {:ok, _} <- validate_headers(opts),
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
  the total size need not be known up front and memory stays bounded (about
  one chunk plus the largest element).

  ## Options
  - `:content_type` — defaults to `"application/octet-stream"`
  - `:chunk_size` — chunk size in bytes (rounded to a 256 KiB multiple)
  - `:attrs` — Object resource metadata to set on the new object
  - `:predefined_acl` — e.g. `"publicRead"`
  - `:origin` — see `start_resumable_upload/3`
  - `:checksum` — `false` to skip the `X-Goog-Hash` MD5 (default `true`)
  """
  @spec upload_stream(String.t(), String.t(), Enumerable.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def upload_stream(bucket, object, enum, opts \\ []) do
    Telemetry.span(:upload_stream, %{bucket: bucket, object: object, strategy: :resumable}, fn ->
      with {:ok, _} <- validate_opts(opts, @resumable_opts),
           {:ok, _} <- Validation.validate_location(bucket, object),
           {:ok, _} <- validate_headers(opts),
           {:ok, _} <- Validation.validate_enumerable(enum, "source"),
           {:ok, session} <- start_session(bucket, object, opts) do
        session
        |> transfer(opts)
        |> stream_to_session(enum, chunk_size(opts))
        |> with_session(session)
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
  - `:predefined_acl` — e.g. `"publicRead"`
  - `:origin` — browser origin to forward as the `Origin` header. Required for
    browser-based resumable uploads (initiate the session server-side, hand the
    session URI to the browser): GCS only returns CORS headers on requests to
    the session URI if the session was initiated with an `Origin` — the
    bucket's CORS configuration alone does not apply. Must be the origin the
    browser will upload from, taken from an allow-list of your own origins —
    never echoed from an incoming request. Mirrors `origin` in Google's official clients
    (e.g. `createResumableUpload` in google-cloud-node,
    `Blob.create_resumable_upload_session` in google-cloud-python).

  `:content_type` and `:origin` must be printable ASCII; anything else is a
  `:validation_error`.
  """
  @spec start_resumable_upload(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def start_resumable_upload(bucket, object, opts \\ []) do
    Telemetry.span(:start_resumable_upload, %{bucket: bucket, object: object}, fn ->
      with {:ok, _} <- validate_opts(opts, @session_opts),
           {:ok, _} <- Validation.validate_location(bucket, object),
           {:ok, _} <- validate_headers(opts) do
        do_start_resumable_upload(bucket, object, opts)
      end
    end)
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
        nil ->
          {:error, Error.new(:protocol_error, "resumable upload session missing Location header")}

        uri ->
          {:ok, uri}
      end
    end
  end

  @doc """
  Uploads a single chunk to a resumable `session_uri`.

  `session_uri` must be a URI returned by `start_resumable_upload/3`: it is
  checked against the endpoint in use (scheme, host, port and the
  `/upload/storage/v1/` path) and rejected with `:validation_error` otherwise.
  The session URI is itself the credential, so no `authorization` header is
  sent with the chunk.

  ## Options (required: `:offset`)
  - `:offset` — byte offset of this chunk within the object
  - `:total` — total object size if known, or `nil`/omitted for the streaming
    case (intermediate chunks send `/*`)
  - `:timeout` and the other transport options

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
    {bucket, object} = session_location(session_uri)

    Telemetry.span(:upload_chunk, %{bucket: bucket, object: object}, fn ->
      with {:ok, _} <- validate_opts(opts, [:offset, :total]),
           {:ok, _} <- Validation.validate_session_uri(session_uri, Client.base_url(opts)),
           {:ok, _} <- Validation.validate_binary(data, "data"),
           {:ok, offset} <- Validation.validate_non_neg_integer(opts[:offset], ":offset"),
           {:ok, total} <- Validation.validate_optional_non_neg_integer(opts[:total], ":total") do
        put_session(session_uri, data, offset, total, opts, [])
      end
    end)
  end

  # Bucket and object name from a session URI
  # (`.../upload/storage/v1/b/<bucket>/o?...&name=<object>&...`), for telemetry.
  defp session_location(session_uri) when is_binary(session_uri) do
    uri = URI.parse(session_uri)

    bucket =
      case String.split(uri.path || "", "/") do
        ["", "upload", "storage", "v1", "b", bucket | _] -> URI.decode(bucket)
        _ -> nil
      end

    {bucket, uri.query && URI.decode_query(uri.query)["name"]}
  end

  defp session_location(_), do: {nil, nil}

  @doc false
  # Asks a resumable session how many bytes it has persisted (`total` if
  # known): `{:resume, persisted}`, or `{:ok, object}` if it is complete.
  @spec query_status(String.t(), non_neg_integer() | nil, keyword()) ::
          {:ok, map()} | {:resume, non_neg_integer()} | {:error, Error.t()}
  def query_status(session_uri, total, opts) do
    put_session(session_uri, "", 0, total, opts, [{"content-length", "0"}])
  end

  # A session PUT. Not retried by the transport (a blind resend of a partly
  # persisted chunk is wrong); `transfer/2` recovers via query_status/3.
  defp put_session(session_uri, data, offset, total, opts, extra_headers) do
    request_opts =
      [
        headers: [
          {"content-range", content_range(offset, byte_size(data), total)} | extra_headers
        ],
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
             Error.new(
               :protocol_error,
               "malformed Range header in resumable upload response",
               headers
             )}
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

  # Metadata in `:attrs` (and a browser `:origin`) only apply through a
  # resumable session, so in-memory data with :attrs goes through one: known
  # size, a single PUT (`bytes 0-n/n`, or `bytes */0` when empty).
  defp resumable_put(bucket, object, data, opts) do
    with {:ok, session} <- start_session(bucket, object, opts) do
      session
      |> transfer(opts)
      |> finalize(0, data)
      |> with_session(session)
    end
  end

  defp upload_file_body(bucket, object, _path, 0, opts) do
    if opts[:attrs] || opts[:origin] do
      resumable_put(bucket, object, "", opts)
    else
      # Empty file without metadata: a simple upload is simplest and correct.
      do_put_object(bucket, object, "", opts)
    end
  end

  defp upload_file_body(bucket, object, path, size, opts) do
    with {:ok, session} <- start_session(bucket, object, opts) do
      session
      |> transfer(opts)
      |> file_to_session(path, size, chunk_size(opts))
      |> with_session(session)
    end
  end

  # Callers have validated their options and the location already.
  defp start_session(bucket, object, opts) do
    with {:ok, session} <- do_start_resumable_upload(bucket, object, opts),
         {:ok, _} <- Validation.validate_session_uri(session, Client.base_url(opts)) do
      {:ok, session}
    end
  end

  defp validate_opts(opts, keys),
    do: Validation.validate_opts(opts, keys ++ Client.transport_keys())

  defp validate_headers(opts) do
    with {:ok, _} <- Validation.validate_header_value(opts[:content_type], ":content_type") do
      Validation.validate_header_value(opts[:origin], ":origin")
    end
  end

  # Failures after the session exists carry its URI so callers can resume.
  defp with_session({:error, %Error{details: details} = error}, session) do
    {:error, %{error | details: %{session_uri: session, cause: details}}}
  end

  defp with_session(result, _session), do: result

  # Resumable transfer engine ----------------------------------------------------
  #
  # State of one transfer into a session:
  #   * `failures` — consecutive transient failures (reset on progress)
  #   * `stalled?` — the previous 308 made no progress; one stall is
  #     tolerated (e.g. a 308 without `Range` on the first chunk: nothing
  #     persisted, resend it), a second consecutive one is an error
  #   * `hash` — `{md5_ctx, hashed_upto}` over the bytes sent so far, or nil

  defp transfer(session, opts) do
    %{
      session: session,
      opts: opts,
      policy: Client.retry_policy(opts),
      failures: 0,
      stalled?: false,
      hash: if(Keyword.get(opts, :checksum, true), do: {:crypto.hash_init(:md5), 0})
    }
  end

  # Sends bytes `offset..offset + byte_size(data) - 1`. Returns
  # `{:resume, persisted, t}`, `{:ok, object}` or `{:error, error}`.
  defp send_range(t, offset, data, total) do
    t = advance_hash(t, offset, data)
    extra = hash_header(t, offset + byte_size(data), total)

    case put_session(t.session, data, offset, total, t.opts, extra) do
      {:resume, persisted} -> {:resume, persisted, t}
      {:ok, object} -> {:ok, object}
      {:error, %Error{} = error} -> recover(t, total, error)
    end
  end

  # On a transient failure: back off, ask the session what it holds and resume
  # from there. A recovery is not a stall.
  defp recover(t, total, error) do
    failures = t.failures + 1

    if t.policy && Client.retryable_error?(error) && failures < t.policy[:max_attempts] do
      Client.backoff(t.policy, failures)
      t = %{t | failures: failures, stalled?: false}

      case query_status(t.session, total, t.opts) do
        {:resume, persisted} -> {:resume, persisted, t}
        {:ok, object} -> {:ok, object}
        {:error, %Error{} = error} -> recover(t, total, error)
      end
    else
      {:error, error}
    end
  end

  # Records a 308: progress resets the failure count; no progress twice in a
  # row is an error rather than a resend loop.
  defp note_progress(t, offset, persisted) do
    cond do
      persisted > offset ->
        {:ok, %{t | failures: 0, stalled?: false}}

      t.stalled? ->
        {:error,
         Error.new(
           :protocol_error,
           "resumable upload made no progress at offset #{offset}",
           %{persisted: persisted, offset: offset}
         )}

      true ->
        {:ok, %{t | stalled?: true}}
    end
  end

  # Streams: full chunks are sent as intermediate PUTs (`/*`); the remainder
  # is finalized with the known total. Only the current chunk can be resent.
  defp stream_to_session(t, enum, chunk) do
    result =
      Enum.reduce_while(enum, {:ok, t, 0, ""}, fn
        data, {:ok, t, offset, buf} when is_binary(data) ->
          case flush_chunks(t, offset, buf <> data, chunk) do
            {:ok, t, offset, rest} -> {:cont, {:ok, t, offset, rest}}
            {:error, %Error{}} = error -> {:halt, error}
          end

        _data, _acc ->
          {:halt, {:error, Error.new(:validation_error, "source elements must be binaries")}}
      end)

    case result do
      {:ok, t, offset, buf} -> finalize(t, offset, buf)
      {:error, %Error{}} = error -> error
    end
  end

  defp flush_chunks(t, offset, buf, chunk) when byte_size(buf) >= chunk do
    <<piece::binary-size(^chunk), rest::binary>> = buf

    case send_range(t, offset, piece, nil) do
      {:resume, next, t} ->
        with {:ok, t} <- note_progress(t, offset, next),
             {:ok, unsent} <- unsent_tail(piece, offset, next) do
          flush_chunks(t, next, prepend(unsent, rest), chunk)
        end

      {:ok, _object} ->
        {:error, Error.new(:protocol_error, "resumable upload finished before final chunk")}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp flush_chunks(t, offset, buf, _chunk), do: {:ok, t, offset, buf}

  defp finalize(t, offset, buf) do
    total = offset + byte_size(buf)

    case send_range(t, offset, buf, total) do
      {:ok, object} ->
        {:ok, object}

      {:resume, next, t} ->
        with {:ok, t} <- note_progress(t, offset, next),
             {:ok, unsent} <- unsent_tail(buf, offset, next) do
          finalize(t, next, unsent)
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
  defp unsent_tail(sent, offset, next) do
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
        {:error, ahead_of_sent(next, sent_end)}

      true ->
        {:ok, binary_part(sent, next - offset, sent_end - next)}
    end
  end

  defp ahead_of_sent(next, sent_end) do
    Error.new(
      :protocol_error,
      "resumable session reported #{next} bytes persisted, but only #{sent_end} were sent",
      %{persisted: next, sent: sent_end}
    )
  end

  defp prepend("", rest), do: rest
  defp prepend(unsent, rest), do: unsent <> rest

  # Files: chunks are read with pread from wherever the session says it is,
  # so any persisted offset can be resumed from.
  defp file_to_session(t, path, size, chunk) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          file_chunks(t, fd, path, 0, size, chunk)
        after
          File.close(fd)
        end

      {:error, reason} ->
        {:error, Error.new(:io_error, "could not open #{path}", reason)}
    end
  end

  defp file_chunks(t, fd, path, offset, size, chunk) do
    len = min(chunk, size - offset)

    with {:ok, data} <- pread(fd, path, offset, len),
         {:resume, next, t} <- send_range(t, offset, data, size),
         :ok <- within_sent(next, offset + len),
         {:ok, t} <- note_progress(t, offset, next) do
      file_chunks(t, fd, path, next, size, chunk)
    end
  end

  defp within_sent(next, sent_end) when next > sent_end,
    do: {:error, ahead_of_sent(next, sent_end)}

  defp within_sent(_next, _sent_end), do: :ok

  defp pread(fd, path, offset, len) do
    case :file.pread(fd, offset, len) do
      {:ok, data} when byte_size(data) == len ->
        {:ok, data}

      {:ok, _short} ->
        {:error, Error.new(:io_error, "#{path} shrank during upload")}

      :eof ->
        {:error, Error.new(:io_error, "#{path} shrank during upload")}

      {:error, reason} ->
        {:error, Error.new(:io_error, "could not read #{path}", reason)}
    end
  end

  # Integrity hash -------------------------------------------------------------

  # Hashes the part of `data` past what has been hashed already (resent bytes
  # are hashed once).
  defp advance_hash(%{hash: {ctx, upto}} = t, offset, data)
       when offset <= upto and offset + byte_size(data) > upto do
    new = binary_part(data, upto - offset, offset + byte_size(data) - upto)
    %{t | hash: {:crypto.hash_update(ctx, new), offset + byte_size(data)}}
  end

  defp advance_hash(t, _offset, _data), do: t

  # The final request (it reaches the known total) carries the whole-object MD5.
  defp hash_header(%{hash: {ctx, total}}, total, total) do
    [{"x-goog-hash", "md5=" <> Base.encode64(:crypto.hash_final(ctx))}]
  end

  defp hash_header(_t, _end, _total), do: []

  # Helpers --------------------------------------------------------------------

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
  # `bytes */*` / `bytes */total` (no bytes: a status query or empty finalize).
  @spec content_range(non_neg_integer(), non_neg_integer(), non_neg_integer() | nil) :: String.t()
  def content_range(_offset, 0, nil), do: "bytes */*"
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

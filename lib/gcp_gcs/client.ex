defmodule GcpGcs.Client do
  @moduledoc false
  # HTTP transport for the Google Cloud Storage JSON API (internal).
  #
  # Wraps Finch and handles URL building, authentication, query/body encoding,
  # JSON decoding, response streaming, retries, and error normalization.
  #
  # Three entry points, sharing one response-interpretation path:
  #
  #   * request/3 — JSON operations; success is any 2xx, returns the decoded body
  #   * exchange/3 — success is any status listed in :expect (e.g. 308 for
  #     resumable uploads); returns status, headers and the decoded body
  #   * stream/5 — streams the response body through a reducer (downloads)
  #
  # `path` is either relative to the API root ("/b/bucket/o", resolved against
  # the JSON or upload API with `api: :json | :upload`) or an absolute URL (a
  # resumable session URI).
  #
  # Retries: idempotent requests (GET and HEAD, or any request marked
  # `idempotent: true`) are retried on 408, 429, 500, 502, 503 and 504
  # responses and on closed, timed-out or refused connections, with
  # exponential backoff and full jitter, honouring Retry-After. Streams are
  # retried only while the reducer has not been called. A 401 on an
  # authenticated request clears the token cache and is retried once.

  alias GcpGcs.{Auth, Config, Error}

  @json_content_type "application/json; charset=UTF-8"

  # Options domain modules forward from the caller to the transport.
  @transport_opts [:timeout, :pool_timeout, :request_timeout, :finch, :base_url, :goth, :retry]

  @retry_statuses [408, 429, 500, 502, 503, 504]
  @retry_transport_reasons [:closed, :timeout, :econnrefused]

  # Non-2xx stream bodies are buffered for the error; cap what we keep.
  @max_error_body 64 * 1024

  @type method :: :get | :post | :put | :patch | :delete | :head
  @type body ::
          nil
          | {:json, term()}
          | {:binary, binary(), String.t()}
          | {:stream, Enumerable.t(), String.t()}
  @type headers :: [{String.t(), String.t()}]

  @doc """
  Performs a request and decodes the response body.

  ## Options
  - `:api` — `:json` (default) or `:upload`; which API root a relative path
    is resolved against
  - `:query` — keyword list or map appended as the query string (`nil`
    values are dropped)
  - `:headers` — extra request headers (list of `{name, value}`)
  - `:body` — request body, see `t:body/0` (default `nil`)
  - `:auth` — set `false` to skip authentication (default `true`)
  - `:idempotent` — `true` allows retrying a non-GET/HEAD request
  - `:timeout` — receive timeout in ms (default `GcpGcs.Config.default_timeout/0`)
  - `:request_timeout` — overall deadline in ms (default: `:timeout`)
  - `:pool_timeout` — max wait in ms for a pooled connection (default
    `GcpGcs.Config.pool_timeout/0`); exceeding it returns
    `{:error, %GcpGcs.Error{code: :resource_exhausted}}`
  - `:finch` — Finch instance name (default `GcpGcs.Config.finch_name/0`)
  - `:base_url` — API host, e.g. `"https://storage.googleapis.com"`
    (default: the configured endpoint); never implies emulator mode
  - `:goth` — Goth instance name for this request
  - `:retry` — `false`, or a keyword list overriding `GcpGcs.Config.retry/0`

  Returns `{:ok, decoded}` on a 2xx response (`%{}` when the body is empty),
  or `{:error, %GcpGcs.Error{}}`.
  """
  @spec request(method(), String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def request(method, path, opts \\ []) do
    with {:ok, _status, _headers, body} <- exchange(method, path, opts) do
      {:ok, body}
    end
  end

  @doc """
  Performs a request and accepts the statuses listed in `:expect` (default:
  any 2xx) as success.

  Takes the options of `request/3` plus `:expect`. Returns
  `{:ok, status, headers, decoded_body}`; any other status becomes
  `{:error, %GcpGcs.Error{}}`, as do transport and authentication failures.
  """
  @spec exchange(method(), String.t(), keyword()) ::
          {:ok, non_neg_integer(), headers(), term()} | {:error, Error.t()}
  def exchange(method, path, opts \\ []) do
    url = url(path, opts)
    outcome = with_retries(method, opts, fn -> exchange_attempt(method, url, opts) end)

    case outcome do
      {:response, status, headers, body} ->
        if expected?(status, Keyword.get(opts, :expect)),
          do: {:ok, status, headers, decode_body(body)},
          else: {:error, Error.from_response(status, decode_body(body))}

      {:transport_error, reason, _touched?} ->
        {:error, Error.from_transport(reason)}

      {:error, %Error{}} = error ->
        error
    end
  end

  @doc """
  Streams a response body through `reducer`, starting from `acc`.

  `reducer` receives `{:headers, headers}` and `{:data, binary}` chunks and
  returns the new accumulator, `{:cont, acc}`, or `{:halt, acc}` to stop
  reading the body. (A plain accumulator that is itself a `{:cont, _}` or
  `{:halt, _}` tuple is read as that instruction.) On a non-2xx status the
  reducer is not called; up to 64 KiB of the body is collected and returned as
  `{:error, %GcpGcs.Error{}}` instead.

  Takes the options of `request/3` except `:body` and `:request_timeout`.
  Returns `{:ok, {status, headers, acc}}` on success.
  """
  @spec stream(method(), String.t(), keyword(), acc, (term(), acc -> term())) ::
          {:ok, {non_neg_integer(), headers(), acc}} | {:error, Error.t()}
        when acc: term()
  def stream(method, path, opts, acc, reducer) when is_function(reducer, 2) do
    url = url(path, opts)

    outcome =
      with_retries(method, opts, fn -> stream_attempt(method, url, opts, acc, reducer) end)

    case outcome do
      {:response, status, headers, user_acc} when status in 200..299 ->
        {:ok, {status, headers, user_acc}}

      {:response, status, _headers, body} ->
        {:error, Error.from_response(status, decode_body(body))}

      {:transport_error, reason, _touched?} ->
        {:error, Error.from_transport(reason)}

      {:error, %Error{}} = error ->
        error
    end
  end

  # One attempt of exchange/3, as a retry outcome (see with_retries/3).
  defp exchange_attempt(method, url, opts) do
    with {:ok, auth_headers} <- auth_headers(opts) do
      {body_iodata, body_headers} = encode_body(Keyword.get(opts, :body))
      headers = auth_headers ++ body_headers ++ Keyword.get(opts, :headers, [])
      request = Finch.build(method, url, headers, body_iodata)

      request
      |> checkout_safe(&Finch.request(&1, finch(opts), request_opts(opts)))
      |> exchange_outcome()
    end
  end

  defp exchange_outcome({:ok, %Finch.Response{status: status, headers: headers, body: body}}),
    do: {:response, status, headers, body}

  defp exchange_outcome({:error, %Error{}} = error), do: error
  defp exchange_outcome({:error, reason}), do: {:transport_error, reason, false}

  # One attempt of stream/5, as a retry outcome. The payload of a 2xx is the
  # user accumulator, otherwise the (capped) error body.
  defp stream_attempt(method, url, opts, acc, reducer) do
    with {:ok, auth_headers} <- auth_headers(opts) do
      request = Finch.build(method, url, auth_headers ++ Keyword.get(opts, :headers, []))
      # {phase, status, headers, user_acc, {error_chunks, error_bytes}}
      init = {:status, nil, [], acc, {[], 0}}
      step = &stream_step(&1, &2, reducer)

      request
      |> checkout_safe(&Finch.stream_while(&1, finch(opts), init, step, stream_opts(opts)))
      |> stream_outcome()
    end
  end

  defp stream_outcome({:ok, {:ok, status, headers, user_acc, _err}}),
    do: {:response, status, headers, user_acc}

  defp stream_outcome({:ok, {_phase, status, headers, _user_acc, {chunks, _size}}}),
    do: {:response, status, headers, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp stream_outcome({:error, %Error{}} = error), do: error

  defp stream_outcome({:error, reason, {phase, _, _, _, _}}),
    do: {:transport_error, reason, phase == :ok}

  @doc false
  # The caller options that domain modules forward to the transport.
  @spec transport_opts(keyword()) :: keyword()
  def transport_opts(opts), do: Keyword.take(opts, @transport_opts)

  @doc false
  # The transport option names every public function accepts.
  @spec transport_keys() :: [atom()]
  def transport_keys, do: @transport_opts

  @doc false
  @spec object_path(String.t(), String.t()) :: String.t()
  def object_path(bucket, object), do: "/b/#{bucket}/o/#{encode_object(object)}"

  @doc false
  # Base URL of the API host for this call.
  @spec base_url(keyword()) :: String.t()
  def base_url(opts), do: Keyword.get(opts, :base_url) || Config.base_url()

  @doc """
  Percent-encodes an object name for use in a URL path (encodes `/` as `%2F`).
  """
  @spec encode_object(String.t()) :: String.t()
  def encode_object(name) when is_binary(name) do
    URI.encode(name, &URI.char_unreserved?/1)
  end

  # Retries --------------------------------------------------------------------

  # `attempt` returns an outcome: {:response, status, headers, payload},
  # {:transport_error, reason, reducer_touched?} or {:error, %Error{}}.
  defp with_retries(method, opts, attempt) do
    policy = retry_policy(method, opts)
    reauth? = Keyword.get(opts, :auth, true) != false
    retry_loop(attempt, policy, 1, reauth?)
  end

  defp retry_loop(attempt, policy, n, reauth?) do
    outcome = attempt.()

    cond do
      reauth? and match?({:response, 401, _, _}, outcome) ->
        # The cached token may have been revoked or rotated: refetch once.
        :ok = Auth.clear_cache()
        retry_loop(attempt, policy, n, false)

      retryable?(outcome) and policy != nil and n < policy[:max_attempts] ->
        Process.sleep(delay(outcome, policy, n))
        retry_loop(attempt, policy, n + 1, reauth?)

      true ->
        outcome
    end
  end

  defp retry_policy(method, opts) do
    if method in [:get, :head] or Keyword.get(opts, :idempotent) == true,
      do: retry_policy(opts),
      else: nil
  end

  @doc false
  # The retry settings for a call (`nil` when retries are disabled), for
  # callers that retry at a higher level (resumable uploads).
  @spec retry_policy(keyword()) :: keyword() | nil
  def retry_policy(opts) do
    case Keyword.get(opts, :retry) do
      false -> nil
      overrides when is_list(overrides) -> Keyword.merge(Config.retry(), overrides)
      _ -> Config.retry()
    end
  end

  @doc false
  # Whether a returned error is transient by the same rules as request retries.
  @spec retryable_error?(Error.t()) :: boolean()
  def retryable_error?(%Error{status: status}) when status in @retry_statuses, do: true

  def retryable_error?(%Error{code: :connection_error, details: %{reason: reason}}),
    do: reason in @retry_transport_reasons

  def retryable_error?(%Error{}), do: false

  @doc false
  # Sleeps the backoff before attempt `n + 1`.
  @spec backoff(keyword(), pos_integer()) :: :ok
  def backoff(policy, n), do: Process.sleep(jitter(policy, n))

  defp retryable?({:response, status, _headers, _payload}), do: status in @retry_statuses

  defp retryable?({:transport_error, %{reason: reason}, false}),
    do: reason in @retry_transport_reasons

  defp retryable?(_outcome), do: false

  # Full jitter: uniform in [0, min(max_delay, base_delay * 2^(n-1))].
  defp delay({:response, _status, headers, _payload}, policy, n) do
    case retry_after_ms(headers) do
      nil -> jitter(policy, n)
      ms -> min(ms, policy[:max_delay])
    end
  end

  defp delay(_outcome, policy, n), do: jitter(policy, n)

  defp jitter(policy, n) do
    cap = min(policy[:max_delay], policy[:base_delay] * Integer.pow(2, n - 1))
    if cap > 0, do: :rand.uniform(cap + 1) - 1, else: 0
  end

  defp retry_after_ms(headers) do
    with {_, value} <- List.keyfind(headers, "retry-after", 0),
         {seconds, ""} <- Integer.parse(String.trim(value)) do
      seconds * 1000
    else
      _ -> nil
    end
  end

  # Transport options ----------------------------------------------------------

  defp finch(opts), do: Keyword.get(opts, :finch) || Config.finch_name()

  # `|| default` (not Keyword.get/3 default) so an explicit `timeout: nil`
  # from callers still resolves to the default rather than reaching Finch.
  defp stream_opts(opts) do
    [
      receive_timeout: Keyword.get(opts, :timeout) || Config.default_timeout(),
      pool_timeout: Keyword.get(opts, :pool_timeout) || Config.pool_timeout()
    ]
  end

  defp request_opts(opts) do
    stream_opts = stream_opts(opts)

    Keyword.put(
      stream_opts,
      :request_timeout,
      Keyword.get(opts, :request_timeout) || stream_opts[:receive_timeout]
    )
  end

  # Finch *raises* when no pooled connection frees up within `:pool_timeout`:
  # its HTTP/1 pool turns NimblePool's checkout exit into a plain RuntimeError
  # with this message (finch 0.24 `Finch.HTTP1.Pool.request/6`). Only that
  # error becomes a tuple; anything else is a bug and keeps propagating.
  @checkout_timeout_message "Finch was unable to provide a connection within the timeout"

  defp checkout_safe(request, fun) do
    fun.(request)
  rescue
    e in RuntimeError ->
      if String.starts_with?(e.message, @checkout_timeout_message) do
        {:error,
         Error.new(
           :resource_exhausted,
           "no pooled connection became available within the pool timeout",
           :pool_timeout
         )}
      else
        reraise e, __STACKTRACE__
      end
  end

  # Streaming internals --------------------------------------------------------

  defp stream_step({:status, status}, {_, _, _headers, acc, err}, _reducer) do
    {:cont, {phase(status), status, [], acc, err}}
  end

  defp stream_step({:headers, headers}, {:ok, status, _, acc, err}, reducer) do
    {instruction, acc} = reduce(reducer, {:headers, headers}, acc)
    {instruction, {:ok, status, headers, acc, err}}
  end

  defp stream_step({:headers, headers}, {:error, status, _, acc, err}, _reducer) do
    {:cont, {:error, status, headers, acc, err}}
  end

  defp stream_step({:data, data}, {:ok, status, headers, acc, err}, reducer) do
    {instruction, acc} = reduce(reducer, {:data, data}, acc)
    {instruction, {:ok, status, headers, acc, err}}
  end

  defp stream_step({:data, data}, {:error, status, headers, acc, {chunks, size}}, _reducer) do
    # Non-2xx: buffer the body (newest chunk first) for the error, up to
    # @max_error_body bytes; then stop reading.
    room = @max_error_body - size

    if byte_size(data) >= room do
      {:halt,
       {:error, status, headers, acc, {[binary_part(data, 0, room) | chunks], @max_error_body}}}
    else
      {:cont, {:error, status, headers, acc, {[data | chunks], size + byte_size(data)}}}
    end
  end

  defp stream_step(_trailers, state, _reducer), do: {:cont, state}

  defp reduce(reducer, event, acc) do
    case reducer.(event, acc) do
      {:cont, acc} -> {:cont, acc}
      {:halt, acc} -> {:halt, acc}
      acc -> {:cont, acc}
    end
  end

  defp phase(status) when status in 200..299, do: :ok
  defp phase(_status), do: :error

  # Request building -----------------------------------------------------------

  defp url("/" <> _ = path, opts) do
    root =
      case Keyword.get(opts, :api, :json) do
        :json -> base_url(opts) <> "/storage/v1"
        :upload -> base_url(opts) <> "/upload/storage/v1"
      end

    append_query(root <> path, Keyword.get(opts, :query))
  end

  defp url(absolute, opts), do: append_query(absolute, Keyword.get(opts, :query))

  defp auth_headers(opts) do
    if Keyword.get(opts, :auth, true) do
      Auth.request_headers(opts)
    else
      {:ok, []}
    end
  end

  defp encode_body(nil), do: {nil, []}

  defp encode_body({:json, term}) do
    {JSON.encode!(term), [{"content-type", @json_content_type}]}
  end

  defp encode_body({:binary, data, content_type}) when is_binary(data) do
    {data, [{"content-type", content_type}]}
  end

  defp encode_body({:stream, enum, content_type}) do
    {{:stream, enum}, [{"content-type", content_type}]}
  end

  defp append_query(url, nil), do: url
  defp append_query(url, []), do: url
  defp append_query(url, query) when is_map(query), do: append_query(url, Map.to_list(query))

  defp append_query(url, query) when is_list(query) do
    encoded =
      query
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {k, to_string(v)} end)
      |> URI.encode_query()

    case encoded do
      "" -> url
      qs -> url <> "?" <> qs
    end
  end

  # Response interpretation ----------------------------------------------------

  defp expected?(status, nil), do: status in 200..299
  defp expected?(status, expect), do: status in expect

  # An empty body decodes to `%{}`; a non-JSON body is returned as-is.
  defp decode_body(""), do: %{}

  defp decode_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end
end

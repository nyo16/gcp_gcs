defmodule GcpGcs.Client do
  @moduledoc """
  HTTP transport for the Google Cloud Storage JSON API.

  Wraps `Finch` and handles URL building, authentication, query/body encoding,
  JSON decoding, response streaming, and error normalization. Most users
  should use the high-level `GcpGcs` API instead of calling this module
  directly.

  Three entry points, sharing one response-interpretation path:

    * `request/3` — JSON operations; success is any 2xx, returns the decoded body
    * `exchange/3` — success is any status listed in `:expect` (e.g. `308`
      for resumable uploads); returns status, headers and the decoded body
    * `stream/5` — streams the response body through a reducer (used by downloads)

  `path` is either relative to the API root (`"/b/bucket/o"`, resolved against
  the JSON or upload API with `api: :json | :upload`) or an absolute URL (a
  resumable session URI).
  """

  alias GcpGcs.{Auth, Config, Error}

  @json_content_type "application/json; charset=UTF-8"

  # Options domain modules forward from the caller to the transport.
  @transport_opts [:timeout, :pool_timeout, :finch]

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
  - `:timeout` — receive timeout in ms (default `GcpGcs.Config.default_timeout/0`)
  - `:pool_timeout` — max wait in ms for a pooled connection (default
    `GcpGcs.Config.pool_timeout/0`); exceeding it returns
    `{:error, %GcpGcs.Error{code: :resource_exhausted}}`
  - `:finch` — Finch instance name (default `GcpGcs.Config.finch_name/0`)

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
    with {:ok, auth_headers} <- auth_headers(opts),
         {body_iodata, body_headers} <- encode_body(Keyword.get(opts, :body)) do
      headers = auth_headers ++ body_headers ++ Keyword.get(opts, :headers, [])
      request = Finch.build(method, url(path, opts), headers, body_iodata)

      case checkout_safe(request, &Finch.request(&1, finch(opts), finch_opts(opts))) do
        {:ok, %Finch.Response{} = response} -> interpret(response, Keyword.get(opts, :expect))
        {:error, %Error{}} = error -> error
        {:error, reason} -> {:error, Error.from_transport(reason)}
      end
    end
  end

  @doc """
  Streams a response body through `reducer`, starting from `acc`.

  `reducer` receives `{:headers, headers}` and `{:data, binary}` chunks. On a
  non-2xx status the reducer is not called; the body is collected and
  returned as `{:error, %GcpGcs.Error{}}` instead.

  Takes the options of `request/3` (except `:body`). Returns
  `{:ok, {status, headers, acc}}` on success.
  """
  @spec stream(method(), String.t(), keyword(), acc, (term(), acc -> acc)) ::
          {:ok, {non_neg_integer(), headers(), acc}} | {:error, Error.t()}
        when acc: term()
  def stream(method, path, opts, acc, reducer) when is_function(reducer, 2) do
    with {:ok, auth_headers} <- auth_headers(opts) do
      headers = auth_headers ++ Keyword.get(opts, :headers, [])
      request = Finch.build(method, url(path, opts), headers)

      # Track status so we can divert the body into an error buffer on failure.
      init = {:status, nil, [], acc, []}
      step = &stream_step(&1, &2, reducer)

      case checkout_safe(request, &Finch.stream(&1, finch(opts), init, step, finch_opts(opts))) do
        {:ok, {_, status, resp_headers, user_acc, err_buf}} ->
          finish_stream(status, resp_headers, user_acc, err_buf)

        {:error, %Error{}} = error ->
          error

        {:error, reason, _partial_acc} ->
          {:error, Error.from_transport(reason)}
      end
    end
  end

  @doc false
  # The caller options that domain modules forward to the transport.
  @spec transport_opts(keyword()) :: keyword()
  def transport_opts(opts), do: Keyword.take(opts, @transport_opts)

  @doc false
  @spec object_path(String.t(), String.t()) :: String.t()
  def object_path(bucket, object), do: "/b/#{bucket}/o/#{encode_object(object)}"

  @doc """
  Percent-encodes an object name for use in a URL path (encodes `/` as `%2F`).
  """
  @spec encode_object(String.t()) :: String.t()
  def encode_object(name) when is_binary(name) do
    URI.encode(name, &URI.char_unreserved?/1)
  end

  # Transport options ----------------------------------------------------------

  defp finch(opts), do: Keyword.get(opts, :finch) || Config.finch_name()

  # `|| default` (not Keyword.get/3 default) so an explicit `timeout: nil`
  # from callers still resolves to the default rather than reaching Finch.
  defp finch_opts(opts) do
    [
      receive_timeout: Keyword.get(opts, :timeout) || Config.default_timeout(),
      pool_timeout: Keyword.get(opts, :pool_timeout) || Config.pool_timeout()
    ]
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

  # State: {phase, status, headers, user_acc, error_buffer}
  defp stream_step({:status, status}, {_, _, _headers, acc, err}, _reducer) do
    {phase(status), status, [], acc, err}
  end

  defp stream_step({:headers, headers}, {phase, status, _, acc, err}, reducer) do
    case phase do
      :ok -> {:ok, status, headers, reducer.({:headers, headers}, acc), err}
      :error -> {:error, status, headers, acc, err}
    end
  end

  defp stream_step({:data, data}, {:ok, status, headers, acc, err}, reducer) do
    {:ok, status, headers, reducer.({:data, data}, acc), err}
  end

  defp stream_step({:data, data}, {:error, status, headers, acc, err}, _reducer) do
    # Non-2xx: buffer the body (newest chunk first) so we can build a useful
    # error. finish_stream/4 reverses before joining.
    {:error, status, headers, acc, [data | err]}
  end

  defp phase(status) when status in 200..299, do: :ok
  defp phase(_status), do: :error

  defp finish_stream(status, headers, acc, _err) when status in 200..299 do
    {:ok, {status, headers, acc}}
  end

  defp finish_stream(status, _headers, _acc, err_buf) do
    body = err_buf |> Enum.reverse() |> IO.iodata_to_binary()
    {:error, Error.from_response(status, decode_body(body))}
  end

  # Request building -----------------------------------------------------------

  defp url("/" <> _ = path, opts) do
    root =
      case Keyword.get(opts, :api, :json) do
        :json -> Config.json_base()
        :upload -> Config.upload_base()
      end

    append_query(root <> path, Keyword.get(opts, :query))
  end

  defp url(absolute, opts), do: append_query(absolute, Keyword.get(opts, :query))

  defp auth_headers(opts) do
    if Keyword.get(opts, :auth, true) do
      Auth.request_headers()
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

  defp interpret(%Finch.Response{status: status, headers: headers, body: body}, expect) do
    if expected?(status, expect) do
      {:ok, status, headers, decode_body(body)}
    else
      {:error, Error.from_response(status, decode_body(body))}
    end
  end

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

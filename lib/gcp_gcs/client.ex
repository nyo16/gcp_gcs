defmodule GcpGcs.Client do
  @moduledoc """
  HTTP transport for the Google Cloud Storage JSON API.

  Wraps `Finch` and handles authentication, query/body encoding, JSON
  decoding, response streaming, and error normalization. Most users should
  use the high-level `GcpGcs` API instead of calling this module directly.

  Three entry points:

    * `request/3` — JSON metadata operations (decodes the body, success = 2xx)
    * `raw_request/3` — returns the raw response for any status (used by
      resumable uploads, which rely on `308 Resume Incomplete`)
    * `stream/5` — streams the response body through a reducer (used by downloads)
  """

  alias GcpGcs.{Auth, Config, Error}

  @json_content_type "application/json; charset=UTF-8"

  @type method :: :get | :post | :put | :patch | :delete | :head
  @type body ::
          nil
          | {:json, term()}
          | {:binary, binary(), String.t()}
          | {:stream, Enumerable.t(), String.t()}

  @doc """
  Performs a JSON request and decodes the response body.

  ## Options
  - `:query` — keyword list or map appended as the query string
  - `:headers` — extra request headers (list of `{name, value}`)
  - `:body` — request body, see `t:body/0` (default `nil`)
  - `:auth` — set `false` to skip authentication (default `true`)
  - `:timeout` — receive timeout in ms (default `GcpGcs.Config.default_timeout/0`)

  Returns `{:ok, decoded}` on a 2xx response (`%{}` when the body is empty),
  or `{:error, %GcpGcs.Error{}}`.
  """
  @spec request(method(), String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def request(method, url, opts \\ []) do
    with {:ok, response} <- raw_request(method, url, opts) do
      interpret_json(response)
    end
  end

  @doc """
  Performs a request and returns the raw `%Finch.Response{}` for any HTTP status.

  Only transport and authentication failures produce `{:error, _}`; HTTP
  statuses (including `4xx` and `308`) are returned as `{:ok, response}` so the
  caller can interpret them (e.g. resumable upload chunking).
  """
  @spec raw_request(method(), String.t(), keyword()) ::
          {:ok, Finch.Response.t()} | {:error, Error.t()}
  def raw_request(method, url, opts \\ []) do
    with {:ok, auth_headers} <- auth_headers(opts),
         {body_iodata, body_headers} <- encode_body(Keyword.get(opts, :body)) do
      headers = auth_headers ++ body_headers ++ Keyword.get(opts, :headers, [])
      full_url = append_query(url, Keyword.get(opts, :query))
      # `|| default` (not Keyword.get/3 default) so an explicit `timeout: nil`
      # from callers still resolves to the default rather than reaching Finch.
      timeout = Keyword.get(opts, :timeout) || Config.default_timeout()

      method
      |> Finch.build(full_url, headers, body_iodata)
      |> Finch.request(Config.finch_name(), receive_timeout: timeout)
      |> case do
        {:ok, %Finch.Response{} = response} -> {:ok, response}
        {:error, reason} -> {:error, Error.from_transport(reason)}
      end
    end
  end

  @doc """
  Streams a response body through `reducer`, starting from `acc`.

  `reducer` receives `{:status, integer}`, `{:headers, headers}`, and
  `{:data, binary}` chunks (as `Finch.stream/5`). On a non-2xx status the body
  is collected and returned as `{:error, %GcpGcs.Error{}}` instead.

  Returns `{:ok, {status, headers, acc}}` on success.
  """
  @spec stream(method(), String.t(), keyword(), acc, (term(), acc -> acc)) ::
          {:ok, {non_neg_integer(), list(), acc}} | {:error, Error.t()}
        when acc: term()
  def stream(method, url, opts, acc, reducer) when is_function(reducer, 2) do
    with {:ok, auth_headers} <- auth_headers(opts) do
      headers = auth_headers ++ Keyword.get(opts, :headers, [])
      full_url = append_query(url, Keyword.get(opts, :query))
      # `|| default` (not Keyword.get/3 default) so an explicit `timeout: nil`
      # from callers still resolves to the default rather than reaching Finch.
      timeout = Keyword.get(opts, :timeout) || Config.default_timeout()

      # Track status so we can divert the body into an error buffer on failure.
      init = {:status, nil, [], acc, []}

      request = Finch.build(method, full_url, headers)

      case Finch.stream(request, Config.finch_name(), init, &stream_step(&1, &2, reducer),
             receive_timeout: timeout
           ) do
        {:ok, {_, status, resp_headers, user_acc, err_buf}} ->
          finish_stream(status, resp_headers, user_acc, err_buf)

        {:error, reason} ->
          {:error, Error.from_transport(reason)}
      end
    end
  end

  @doc """
  Percent-encodes an object name for use in a URL path (encodes `/` as `%2F`).
  """
  @spec encode_object(String.t()) :: String.t()
  def encode_object(name) when is_binary(name) do
    URI.encode(name, &URI.char_unreserved?/1)
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
    {:error, Error.from_response(status, decode_maybe_json(body))}
  end

  # Request building -----------------------------------------------------------

  defp auth_headers(opts) do
    if Keyword.get(opts, :auth, true) do
      Auth.request_headers()
    else
      {:ok, []}
    end
  end

  defp encode_body(nil), do: {nil, []}

  defp encode_body({:json, term}) do
    {Jason.encode!(term), [{"content-type", @json_content_type}]}
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

  defp interpret_json(%Finch.Response{status: status, body: body}) when status in 200..299 do
    case body do
      "" -> {:ok, %{}}
      nil -> {:ok, %{}}
      data -> {:ok, decode_maybe_json(data)}
    end
  end

  defp interpret_json(%Finch.Response{status: status, body: body}) do
    {:error, Error.from_response(status, decode_maybe_json(body))}
  end

  defp decode_maybe_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode_maybe_json(body), do: body
end

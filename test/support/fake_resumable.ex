defmodule GcpGcs.FakeResumable do
  @moduledoc false
  # A minimal GCS resumable-upload session for Bypass, faithful to the wire
  # protocol: the initiation POST returns a session URI in `Location`; each
  # session PUT carries `Content-Range`, and the server answers `308` with
  # `Range: bytes=0-N` (omitted when nothing is persisted) until the final byte
  # arrives, then `200` with the object resource.
  #
  # A `policy` function decides, per PUT, how many of the new bytes to
  # persist, to simulate partial persistence and server-side data loss:
  #
  #     policy.(put_index, %{start: start, body: body, persisted: persisted})
  #       :all            -> persist every new byte (default)
  #       {:partial, k}   -> persist only the first `k` new bytes
  #       :none           -> persist nothing
  #       :forget         -> drop everything persisted so far (no `Range` header)
  #       {:status, code} -> reply with `code` and persist nothing
  #
  # Every PUT is recorded as `%{content_range: ..., body: ..., headers: ...}`.

  use Agent

  @session_path "/upload/storage/v1/b/test-bucket/o"

  @type t :: pid()

  @spec start(Bypass.t(), (non_neg_integer(), map() -> term())) :: t()
  def start(bypass, policy \\ fn _i, _req -> :all end) do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{data: "", puts: [], posts: [], policy: policy, total: nil}
      end)

    Bypass.expect(bypass, fn conn -> handle(conn, pid, bypass) end)
    pid
  end

  @spec session_uri(Bypass.t()) :: String.t()
  def session_uri(bypass) do
    "http://localhost:#{bypass.port}#{@session_path}?uploadType=resumable&upload_id=fake"
  end

  @doc "Bytes the server has persisted so far."
  @spec data(t()) :: binary()
  def data(pid), do: Agent.get(pid, & &1.data)

  @doc "Session PUTs received, oldest first."
  @spec puts(t()) :: [map()]
  def puts(pid), do: pid |> Agent.get(& &1.puts) |> Enum.reverse()

  @doc "Initiation POSTs received (`%{headers: ..., body: ...}`), oldest first."
  @spec posts(t()) :: [map()]
  def posts(pid), do: pid |> Agent.get(& &1.posts) |> Enum.reverse()

  defp handle(%Plug.Conn{method: "POST"} = conn, pid, bypass) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    post = %{headers: conn.req_headers, body: body}
    Agent.update(pid, &%{&1 | posts: [post | &1.posts]})

    conn
    |> Plug.Conn.put_resp_header("location", session_uri(bypass))
    |> Plug.Conn.resp(200, "")
  end

  defp handle(%Plug.Conn{method: "PUT"} = conn, pid, _bypass) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 64 * 1024 * 1024)
    [content_range] = Plug.Conn.get_req_header(conn, "content-range")
    {start, total} = parse_content_range(content_range)

    put = %{content_range: content_range, body: body, headers: conn.req_headers}

    reply =
      Agent.get_and_update(pid, fn state ->
        index = length(state.puts)
        state = %{state | puts: [put | state.puts], total: total || state.total}
        decision = state.policy.(index, %{start: start, body: body, persisted: state.data})
        apply_decision(decision, state, start, body)
      end)

    respond(conn, reply)
  end

  defp apply_decision({:status, code}, state, _start, _body), do: {{:status, code}, state}

  defp apply_decision(:forget, state, _start, _body) do
    state = %{state | data: ""}
    {reply_for(state), state}
  end

  defp apply_decision(decision, state, start, body) do
    persisted = byte_size(state.data)
    # New bytes are those past what the server already holds; a PUT starting
    # beyond the persisted end leaves a gap and is ignored, like GCS would. A
    # `bytes */total` PUT (`start == nil`) carries no bytes.
    new =
      if is_integer(start) and start <= persisted and start + byte_size(body) > persisted,
        do: binary_part(body, persisted - start, start + byte_size(body) - persisted),
        else: ""

    new =
      case decision do
        :all -> new
        :none -> ""
        {:partial, k} -> binary_part(new, 0, min(k, byte_size(new)))
      end

    state = %{state | data: state.data <> new}
    {reply_for(state), state}
  end

  defp reply_for(%{data: data, total: total}) when byte_size(data) == total, do: :done
  defp reply_for(%{data: ""}), do: {:resume, nil}
  defp reply_for(%{data: data}), do: {:resume, byte_size(data) - 1}

  defp respond(conn, :done) do
    Plug.Conn.resp(conn, 200, JSON.encode!(%{"name" => "object.bin"}))
  end

  defp respond(conn, {:resume, nil}), do: Plug.Conn.resp(conn, 308, "")

  defp respond(conn, {:resume, last}) do
    conn
    |> Plug.Conn.put_resp_header("range", "bytes=0-#{last}")
    |> Plug.Conn.resp(308, "")
  end

  defp respond(conn, {:status, code}), do: Plug.Conn.resp(conn, code, "")

  defp parse_content_range("bytes */" <> total), do: {nil, parse_total(total)}

  defp parse_content_range("bytes " <> spec) do
    [range, total] = String.split(spec, "/")
    [first, _last] = String.split(range, "-")
    {String.to_integer(first), parse_total(total)}
  end

  defp parse_total("*"), do: nil
  defp parse_total(total), do: String.to_integer(total)
end

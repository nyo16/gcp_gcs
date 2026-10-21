defmodule GcpGcs.FakeServer do
  @moduledoc false
  # A local HTTP server for tests, replacing Bypass (unmaintained; its
  # plug_cowboy/cowboy stack pins vulnerable cowlib). Runs Bandit with a Plug
  # that dispatches each request to a per-test handler function.
  #
  # The subset of the Bypass API the suite uses:
  #
  #   * open/0 — starts a server on a free loopback port (`server.port`)
  #   * expect/2, expect/4 — handler called at least once (any route, or a
  #     method + exact request path; route-specific handlers win)
  #   * expect_once/2, expect_once/4 — handler called exactly once
  #   * down/1 — stops listening (requests are refused)
  #   * pass/1 — skip verification (e.g. a handler shut down by a client that
  #     gave up; the test asserts outcomes itself)
  #
  # When the test exits, unmet expectations, unexpected requests and handler
  # crashes (including failed assertions inside handlers) fail the test.

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1, stop_supervised!: 1]

  defstruct [:port, :state, :listener]

  @type t :: %__MODULE__{port: pos_integer(), state: pid(), listener: term()}

  @spec open() :: t()
  def open do
    {:ok, state} =
      Agent.start(fn -> %{expectations: [], errors: [], passed?: false} end)

    listener = {__MODULE__, make_ref()}

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {GcpGcs.FakeServer.Plug, state}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: listener
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    on_exit(fn -> verify!(state) end)
    %__MODULE__{port: port, state: state, listener: listener}
  end

  @spec expect(t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect(server, fun), do: add(server, nil, nil, fun, :at_least_once)

  @spec expect(t(), String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect(server, method, path, fun), do: add(server, method, path, fun, :at_least_once)

  @spec expect_once(t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect_once(server, fun), do: add(server, nil, nil, fun, :once)

  @spec expect_once(t(), String.t(), String.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def expect_once(server, method, path, fun), do: add(server, method, path, fun, :once)

  @spec down(t()) :: :ok
  def down(%__MODULE__{listener: listener}), do: stop_supervised!(listener)

  @spec pass(t()) :: :ok
  def pass(%__MODULE__{state: state}), do: Agent.update(state, &%{&1 | passed?: true})

  defp add(%__MODULE__{state: state}, method, path, fun, mode) do
    expectation = %{method: method, path: path, fun: fun, mode: mode, calls: 0}
    Agent.update(state, &%{&1 | expectations: &1.expectations ++ [expectation]})
  end

  @doc false
  # Picks the handler for a request and counts the call.
  @spec claim(pid(), String.t(), String.t()) :: {:ok, function()} | :unexpected
  def claim(state, method, path) do
    Agent.get_and_update(state, fn %{expectations: expectations} = s ->
      specific = Enum.find_index(expectations, &(&1.method == method and &1.path == path))
      any = Enum.find_index(expectations, &is_nil(&1.method))

      case specific || any do
        nil ->
          {:unexpected, s}

        index ->
          expectations = List.update_at(expectations, index, &%{&1 | calls: &1.calls + 1})
          {{:ok, Enum.at(expectations, index).fun}, %{s | expectations: expectations}}
      end
    end)
  end

  @doc false
  @spec record_error(pid(), term()) :: :ok
  def record_error(state, error), do: Agent.update(state, &%{&1 | errors: [error | &1.errors]})

  defp verify!(state) do
    %{expectations: expectations, errors: errors, passed?: passed?} = Agent.get(state, & &1)
    Agent.stop(state)

    problems =
      Enum.reverse(errors) ++
        for %{mode: mode, calls: calls} = e <- expectations,
            (mode == :once and calls != 1) or (mode == :at_least_once and calls == 0) do
          "expected #{route(e)} #{if mode == :once, do: "exactly once", else: "at least once"}, " <>
            "got #{calls} call(s)"
        end

    if problems != [] and not passed? do
      raise ExUnit.AssertionError,
        message: "FakeServer: " <> Enum.map_join(problems, "\n", &format/1)
    end
  end

  defp route(%{method: nil}), do: "a request"
  defp route(%{method: method, path: path}), do: "#{method} #{path}"

  defp format(message) when is_binary(message), do: message

  defp format({:crash, kind, reason, stacktrace}),
    do: "handler crashed:\n" <> Exception.format(kind, reason, stacktrace)

  defp format({:unexpected, method, path}), do: "unexpected request #{method} #{path}"
end

defmodule GcpGcs.FakeServer.Plug do
  @moduledoc false
  @behaviour Plug

  alias GcpGcs.FakeServer

  @impl true
  def init(state), do: state

  @impl true
  def call(conn, state) do
    case FakeServer.claim(state, conn.method, conn.request_path) do
      {:ok, fun} ->
        run(fun, conn, state)

      :unexpected ->
        FakeServer.record_error(state, {:unexpected, conn.method, conn.request_path})
        Plug.Conn.send_resp(conn, 500, "unexpected request")
    end
  end

  defp run(fun, conn, state) do
    fun.(conn)
  catch
    kind, reason ->
      FakeServer.record_error(state, {:crash, kind, reason, __STACKTRACE__})
      Plug.Conn.send_resp(conn, 500, "fake server handler crashed")
  end
end

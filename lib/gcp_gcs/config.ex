defmodule GcpGcs.Config do
  @moduledoc """
  Resolves endpoint, emulator, transport and auth settings for `GcpGcs`.

  ## Production (default)

  No configuration is required. Requests go to `https://storage.googleapis.com`
  and authenticate via `GcpGcs.Auth`.

  ## Emulator (development / test)

  Point the client at a local emulator such as
  [fake-gcs-server](https://github.com/fsouza/fake-gcs-server):

      config :gcp_gcs, :emulator,
        scheme: "http",
        host: "localhost",
        port: 4443

  Alternatively, set the `STORAGE_EMULATOR_HOST` environment variable
  (honored by the official Google client libraries), e.g.
  `STORAGE_EMULATOR_HOST=http://localhost:4443`. To ignore that variable (for
  example in production releases), set:

      config :gcp_gcs, :emulator_env, false

  When an emulator is configured, authentication is skipped; an emulator on a
  non-loopback host is logged as an error at boot. The endpoint is resolved
  once, when the application starts.

  ## Finch pool

      config :gcp_gcs, :finch,
        pool_size: 50,          # connections per shard
        pool_count: 1,          # shards
        protocols: [:http1]     # opt in to [:http2] explicitly

      # Use your own Finch instance instead of the one GcpGcs starts:
      config :gcp_gcs, :start_finch, false
      config :gcp_gcs, :finch_name, MyApp.Finch

  Concurrent transfers each hold a connection for their whole duration, so
  `pool_size * pool_count` is the transfer concurrency: size it for the
  number of simultaneous uploads/downloads plus metadata calls. Raise
  `pool_size` first. Finch picks a shard at random per request, so several
  shards start queueing (and returning `:resource_exhausted` after
  `:pool_timeout`) while one shard of the same total size still has free
  connections; add shards only if a single pool process becomes a
  bottleneck (well beyond 1,000 requests per second).

  ## TLS

  HTTPS pools use `verify: :verify_peer` with TLS 1.2/1.3. Mint loads the OS
  trust store (`:public_key.cacerts_get/0`) when it connects, or CAStore's
  bundle if the OS store is unavailable and `castore` is a dependency. The
  store is loaded once at application start, which fails if neither is
  available. To replace these options (then nothing is checked at start):

      config :gcp_gcs, :ssl_opts,
        verify: :verify_peer,
        cacertfile: "/etc/ssl/certs/ca-certificates.crt"

  Prefer `:cacertfile` (or no CA option at all) over a decoded `:cacerts`
  list: Finch keeps these options in every pool shard and copies them with
  the connection on every checkout and checkin, so a large `:cacerts` list
  adds hundreds of microseconds to each request.

  ## Timeouts

      # Receive timeout per request (ms)
      config :gcp_gcs, :default_timeout, 30_000

      # Max wait for a free pooled connection (ms). When exceeded, requests
      # return {:error, %GcpGcs.Error{code: :resource_exhausted}}.
      config :gcp_gcs, :pool_timeout, 5_000

  Per call: `:timeout`, `:pool_timeout`, and `:request_timeout` (an overall
  deadline for metadata requests, defaulting to `:timeout`; not applied to
  streamed downloads).

  ## Retries

      config :gcp_gcs, :retry, max_attempts: 4, base_delay: 200, max_delay: 10_000

  Idempotent requests are retried on 408, 429, 5xx (500, 502, 503, 504) and
  connection errors (closed, timeout, refused) with exponential backoff and
  full jitter, honouring `Retry-After`. Pass `retry: false` (or a keyword list
  overriding the settings above) per call.

  ## gcloud CLI fallback

      config :gcp_gcs, :gcloud_path, "/usr/local/bin/gcloud"  # default: "gcloud" on PATH
      config :gcp_gcs, :gcloud_fallback, false                # disable it entirely
      config :gcp_gcs, :gcloud_timeout, 30_000                # ms per gcloud run

  A bare `:gcloud_path` name is looked up on `PATH` only (never in the working
  directory). `:gcloud_timeout` is a positive integer; a gcloud run that
  exceeds it is killed (with any child processes) and the request fails with
  `:unauthenticated`; that failure is cached for 5 seconds like any other. The
  gcloud fallback is meant for development; production deployments should
  use Goth (`config :gcp_gcs, :goth, MyApp.Goth`).

  ## Per-call overrides

  Every operation accepts `:goth` (a Goth instance name), `:finch` (a Finch
  instance name) and `:base_url` (e.g. a regional or private endpoint). A
  per-call `:base_url` never implies emulator mode: authentication stays on.
  """

  require Logger

  @prod_host "storage.googleapis.com"
  @default_timeout 30_000
  @default_pool_timeout 5_000
  @default_finch_name GcpGcs.Finch
  @default_pool_size 50
  @default_retry [max_attempts: 4, base_delay: 200, max_delay: 10_000]
  @default_gcloud_timeout 30_000

  @type emulator :: %{scheme: String.t(), host: String.t(), port: pos_integer()}

  @doc false
  # The Finch instance used for requests (`config :gcp_gcs, :finch_name`).
  @spec finch_name() :: atom()
  def finch_name, do: Application.get_env(:gcp_gcs, :finch_name, @default_finch_name)

  @doc false
  # Whether GcpGcs.Application starts its own Finch (`config :gcp_gcs, :start_finch`).
  @spec start_finch?() :: boolean()
  def start_finch?, do: Application.get_env(:gcp_gcs, :start_finch, true)

  @doc false
  @spec default_timeout() :: pos_integer()
  def default_timeout do
    Application.get_env(:gcp_gcs, :default_timeout, @default_timeout)
  end

  @doc false
  @spec pool_timeout() :: pos_integer()
  def pool_timeout do
    Application.get_env(:gcp_gcs, :pool_timeout, @default_pool_timeout)
  end

  @doc false
  # Retry settings: `max_attempts`, `base_delay` and `max_delay` (ms).
  @spec retry() :: keyword()
  def retry do
    Keyword.merge(@default_retry, Application.get_env(:gcp_gcs, :retry, []))
  end

  @doc false
  @spec gcloud_path() :: String.t()
  def gcloud_path, do: Application.get_env(:gcp_gcs, :gcloud_path, "gcloud")

  @doc false
  @spec gcloud_fallback?() :: boolean()
  def gcloud_fallback?, do: Application.get_env(:gcp_gcs, :gcloud_fallback, true)

  @doc false
  # Deadline (ms) for one gcloud run; the process is killed when it expires.
  # Anything but a positive integer falls back to the default, with a warning.
  @spec gcloud_timeout() :: pos_integer()
  def gcloud_timeout do
    case Application.get_env(:gcp_gcs, :gcloud_timeout, @default_gcloud_timeout) do
      ms when is_integer(ms) and ms > 0 ->
        ms

      other ->
        Logger.warning(
          "GcpGcs: :gcloud_timeout must be a positive integer (ms), got #{inspect(other)}; " <>
            "using #{@default_gcloud_timeout}"
        )

        @default_gcloud_timeout
    end
  end

  # The endpoint is resolved from app env / STORAGE_EMULATOR_HOST once, at
  # application start, and served from :persistent_term on every request.
  @endpoint_key {__MODULE__, :endpoint}

  @doc false
  # `{scheme, host, port}` requests go to (and the Finch pool connects to).
  @spec endpoint() :: {:http | :https, String.t(), pos_integer()}
  def endpoint do
    %{scheme: scheme, host: host, port: port} = resolved()
    {scheme, host, port}
  end

  @doc false
  @spec base_url() :: String.t()
  def base_url, do: resolved().base_url

  @doc false
  @spec json_base() :: String.t()
  def json_base, do: base_url() <> "/storage/v1"

  @doc false
  @spec upload_base() :: String.t()
  def upload_base, do: base_url() <> "/upload/storage/v1"

  @doc false
  # Whether an emulator is configured (auth is skipped when true).
  @spec emulator?() :: boolean()
  def emulator?, do: resolved().emulator?

  @doc false
  # Re-resolves the endpoint from the current app env and environment
  # variables. Called at application start; tests that change the emulator
  # at runtime call it too.
  @spec refresh() :: map()
  def refresh do
    endpoint = resolve_endpoint()
    :persistent_term.put(@endpoint_key, endpoint)
    endpoint
  end

  defp resolved do
    case :persistent_term.get(@endpoint_key, nil) do
      nil -> refresh()
      endpoint -> endpoint
    end
  end

  defp resolve_endpoint do
    case emulator() do
      nil ->
        %{
          scheme: :https,
          host: @prod_host,
          port: 443,
          base_url: "https://#{@prod_host}",
          emulator?: false
        }

      %{scheme: scheme, host: host, port: port} ->
        %{
          scheme: scheme_atom(scheme),
          host: host,
          port: port,
          base_url: "#{scheme}://#{host}:#{port}",
          emulator?: true
        }
    end
  end

  @doc false
  # The emulator settings from app env or STORAGE_EMULATOR_HOST, read live
  # (unlike the functions above). `nil` when no emulator is configured.
  @spec emulator() :: emulator() | nil
  def emulator do
    case Application.get_env(:gcp_gcs, :emulator) do
      nil -> emulator_from_env()
      false -> nil
      opts when is_list(opts) -> normalize_emulator(opts)
      %{} = opts -> normalize_emulator(Map.to_list(opts))
    end
  end

  @doc false
  # Logs the emulator mode at boot: a warning on loopback hosts, an error on
  # any other host, where unauthenticated plaintext requests could reach a
  # machine the operator didn't intend.
  @spec log_emulator_mode() :: :ok
  def log_emulator_mode do
    {_scheme, host, port} = endpoint()

    cond do
      not emulator?() ->
        :ok

      loopback?(host) ->
        Logger.warning(
          "GcpGcs: emulator mode is active — authentication will be skipped. " <>
            "Remove the `:gcp_gcs, :emulator` config (and STORAGE_EMULATOR_HOST) for production."
        )

      true ->
        Logger.error(
          "GcpGcs: emulator mode targets non-loopback host #{host}:#{port} — requests are " <>
            "sent unauthenticated to it. Set `config :gcp_gcs, :emulator_env, false` to " <>
            "ignore STORAGE_EMULATOR_HOST."
        )
    end
  end

  @doc false
  @spec loopback?(String.t()) :: boolean()
  def loopback?("localhost"), do: true

  def loopback?(host) do
    address = host |> String.trim_leading("[") |> String.trim_trailing("]") |> to_charlist()

    case :inet.parse_address(address) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  @doc false
  @spec finch_opts() :: keyword()
  def finch_opts do
    finch = Application.get_env(:gcp_gcs, :finch, [])
    {scheme, host, port} = endpoint()

    pool =
      [
        size: Keyword.get(finch, :pool_size, @default_pool_size),
        count: Keyword.get(finch, :pool_count, 1)
      ] ++ protocols(finch)

    # The :default entry covers origins other than the endpoint (e.g. a
    # per-call base URL): it gets the same strict TLS settings, so an
    # unmatched https origin never falls back to Finch's defaults. Finch drops
    # TLS options for plain-http origins.
    [
      name: finch_name(),
      pools: %{
        :default => pool ++ conn_opts(:https),
        "#{scheme}://#{host}:#{port}" => pool ++ conn_opts(scheme)
      }
    ]
  end

  defp protocols(finch) do
    case Keyword.fetch(finch, :protocols) do
      {:ok, protocols} -> [protocols: protocols]
      :error -> []
    end
  end

  @doc false
  # Loads the trust store Mint will use (OTP caches it), so a host without
  # one fails at boot rather than on every HTTPS request. Skipped when
  # `:ssl_opts` is configured: the CA options are the application's then.
  @spec check_trust_store!() :: :ok
  def check_trust_store! do
    if Application.get_env(:gcp_gcs, :ssl_opts) do
      :ok
    else
      _ = :public_key.cacerts_get()
      :ok
    end
  rescue
    e ->
      if Code.ensure_loaded?(CAStore) do
        Logger.warning(
          "GcpGcs: no OS trust store (#{inspect(e.__struct__)}); Mint will use CAStore"
        )

        :ok
      else
        reraise RuntimeError,
                [
                  message:
                    "GcpGcs: no OS CA trust store is available for HTTPS certificate " <>
                      "verification (#{Exception.message(e)}). Install the OS CA certificates, " <>
                      "add :castore to your dependencies, or set `config :gcp_gcs, :ssl_opts` " <>
                      "with a :cacertfile."
                ],
                __STACKTRACE__
      end
  end

  # Strict TLS for HTTPS: verify the server certificate. With no `:cacerts` or
  # `:cacertfile` given, Mint loads the OS trust store
  # (`:public_key.cacerts_get/0`) at connect time. Keeping the decoded
  # certificates out of these options matters: Finch stores them in every pool
  # shard and copies them with the connection on every checkout and checkin.
  # The whole point of this client is authenticated requests carrying OAuth
  # bearer tokens, so we never want an unverified connection. Override via
  # `config :gcp_gcs, :ssl_opts, [...]`. No TLS options for plaintext
  # emulator endpoints.
  defp conn_opts(:https) do
    ssl =
      Application.get_env(
        :gcp_gcs,
        :ssl_opts,
        verify: :verify_peer,
        versions: [:"tlsv1.2", :"tlsv1.3"]
      )

    [conn_opts: [transport_opts: ssl]]
  end

  defp conn_opts(_scheme), do: []

  # Private

  defp emulator_from_env do
    with true <- Application.get_env(:gcp_gcs, :emulator_env, true),
         url when url not in [nil, ""] <- System.get_env("STORAGE_EMULATOR_HOST") do
      parse_emulator_url(url)
    else
      _ -> nil
    end
  end

  defp parse_emulator_url(url) do
    uri = URI.parse(maybe_prefix_scheme(url))

    %{
      scheme: uri.scheme || "http",
      host: uri.host || "localhost",
      port: uri.port || default_port(uri.scheme)
    }
  end

  defp maybe_prefix_scheme(url) do
    if String.contains?(url, "://"), do: url, else: "http://" <> url
  end

  defp normalize_emulator(opts) do
    scheme = to_string(Keyword.get(opts, :scheme, "http"))

    %{
      scheme: scheme,
      host: to_string(Keyword.get(opts, :host, "localhost")),
      port: Keyword.get(opts, :port, default_port(scheme))
    }
  end

  defp default_port("https"), do: 443
  defp default_port(_), do: 80

  defp scheme_atom("https"), do: :https
  defp scheme_atom(_), do: :http
end

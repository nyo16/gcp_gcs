defmodule GcpGcs.Config do
  @moduledoc """
  Resolves endpoint, emulator, and Finch settings for `GcpGcs`.

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
  `STORAGE_EMULATOR_HOST=http://localhost:4443`.

  When an emulator is configured, authentication is skipped.

  ## Finch pool

      config :gcp_gcs, :finch,
        pool_size: 50,
        pool_count: 1

  ## Timeouts

      # Receive timeout per request (ms)
      config :gcp_gcs, :default_timeout, 30_000

      # Max wait for a free pooled connection (ms). When exceeded, requests
      # return {:error, %GcpGcs.Error{code: :resource_exhausted}}.
      config :gcp_gcs, :pool_timeout, 5_000

  Both can be overridden per call with the `:timeout` and `:pool_timeout`
  options.
  """

  @prod_host "storage.googleapis.com"
  @default_timeout 30_000
  @default_pool_timeout 5_000
  @finch_name GcpGcs.Finch

  @type emulator :: %{scheme: String.t(), host: String.t(), port: pos_integer()}

  @doc "The registered name of the Finch pool started by `GcpGcs.Application`."
  @spec finch_name() :: atom()
  def finch_name, do: @finch_name

  @doc "Default request timeout in milliseconds."
  @spec default_timeout() :: pos_integer()
  def default_timeout do
    Application.get_env(:gcp_gcs, :default_timeout, @default_timeout)
  end

  @doc "Max wait in milliseconds for a pooled connection."
  @spec pool_timeout() :: pos_integer()
  def pool_timeout do
    Application.get_env(:gcp_gcs, :pool_timeout, @default_pool_timeout)
  end

  # The endpoint is resolved from app env / STORAGE_EMULATOR_HOST once, at
  # application start, and served from :persistent_term on every request.
  @endpoint_key {__MODULE__, :endpoint}

  @doc """
  The scheme/host/port requests go to (and the Finch pool connects to).

  Returns `{scheme, host, port}` where `scheme` is `:http` or `:https`.
  """
  @spec endpoint() :: {:http | :https, String.t(), pos_integer()}
  def endpoint do
    %{scheme: scheme, host: host, port: port} = resolved()
    {scheme, host, port}
  end

  @doc "Base URL of the API host, e.g. `https://storage.googleapis.com`."
  @spec base_url() :: String.t()
  def base_url, do: resolved().base_url

  @doc "Base URL for JSON metadata operations, e.g. `.../storage/v1`."
  @spec json_base() :: String.t()
  def json_base, do: base_url() <> "/storage/v1"

  @doc "Base URL for media/resumable uploads, e.g. `.../upload/storage/v1`."
  @spec upload_base() :: String.t()
  def upload_base, do: base_url() <> "/upload/storage/v1"

  @doc "Whether an emulator is configured (auth is skipped when true)."
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
  @spec finch_opts() :: keyword()
  def finch_opts do
    finch = Application.get_env(:gcp_gcs, :finch, [])
    {scheme, host, port} = endpoint()

    pool = [
      size: Keyword.get(finch, :pool_size, 25),
      count: Keyword.get(finch, :pool_count, 1)
    ]

    # The :default entry covers origins other than the endpoint (e.g. a
    # per-call base URL): it gets the same strict TLS settings, so an
    # unmatched https origin never falls back to Finch's defaults. Finch drops
    # TLS options for plain-http origins.
    [
      name: @finch_name,
      pools: %{
        :default => pool ++ conn_opts(:https),
        "#{scheme}://#{host}:#{port}" => pool ++ conn_opts(scheme)
      }
    ]
  end

  # Strict TLS for HTTPS: verify the server certificate against the OS trust
  # store. The whole point of this client is authenticated requests carrying
  # OAuth bearer tokens, so we never want an unverified connection. Override
  # via `config :gcp_gcs, :ssl_opts, [...]`. No TLS options for plaintext
  # emulator endpoints.
  defp conn_opts(:https) do
    ssl =
      Application.get_env(
        :gcp_gcs,
        :ssl_opts,
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        versions: [:"tlsv1.2", :"tlsv1.3"]
      )

    [conn_opts: [transport_opts: ssl]]
  end

  defp conn_opts(_scheme), do: []

  # Private

  defp emulator_from_env do
    case System.get_env("STORAGE_EMULATOR_HOST") do
      nil -> nil
      "" -> nil
      url -> parse_emulator_url(url)
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

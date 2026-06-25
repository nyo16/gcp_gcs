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

      config :gcp_gcs, :default_timeout, 30_000
  """

  @prod_host "storage.googleapis.com"
  @default_timeout 30_000
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

  @doc """
  The scheme/host/port the Finch pool should connect to.

  Returns `{scheme, host, port}` where `scheme` is `:http` or `:https`.
  """
  @spec endpoint() :: {:http | :https, String.t(), pos_integer()}
  def endpoint do
    case emulator() do
      nil -> {:https, @prod_host, 443}
      %{scheme: scheme, host: host, port: port} -> {scheme_atom(scheme), host, port}
    end
  end

  @doc "Base URL for the JSON API, e.g. `https://storage.googleapis.com`."
  @spec base_url() :: String.t()
  def base_url do
    case emulator() do
      nil -> "https://#{@prod_host}"
      %{scheme: scheme, host: host, port: port} -> "#{scheme}://#{host}:#{port}"
    end
  end

  @doc "Base URL for JSON metadata operations, e.g. `.../storage/v1`."
  @spec json_base() :: String.t()
  def json_base, do: base_url() <> "/storage/v1"

  @doc "Base URL for media/resumable uploads, e.g. `.../upload/storage/v1`."
  @spec upload_base() :: String.t()
  def upload_base, do: base_url() <> "/upload/storage/v1"

  @doc "Whether an emulator is configured (auth is skipped when true)."
  @spec emulator?() :: boolean()
  def emulator?, do: emulator() != nil

  @doc false
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

    pool = pool ++ conn_opts(scheme)

    [name: @finch_name, pools: %{"#{scheme}://#{host}:#{port}" => pool}]
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

defmodule GcpGcs.Auth do
  @moduledoc """
  Authentication for Google Cloud Storage.

  Retrieves OAuth2 access tokens using, in order of preference:

  1. **Goth** — a per-call `:goth` option, or `config :gcp_gcs, :goth, MyApp.Goth`.
     Goth caches and refreshes its own tokens.
  2. **gcloud CLI** — `gcloud auth application-default print-access-token`,
     meant for development. Tokens are cached until shortly before their real
     expiry and refreshed once even under concurrent demand; failures are
     cached for 5 seconds. Disable with `config :gcp_gcs, :gcloud_fallback, false`;
     point at a specific binary with `config :gcp_gcs, :gcloud_path, "..."`.
  3. Returns a structured `GcpGcs.Error` if no credentials are available

  When an emulator is configured (see `GcpGcs.Config`), authentication is
  skipped entirely and requests are sent without an `authorization` header.
  A per-call `:base_url` keeps authentication on.

  A `401` response clears the cached token and the request is retried once
  with a fresh one.

  ## Using Goth

  Goth is an optional dependency: add `{:goth, "~> 1.4"}` to your deps to use
  it. Without it the gcloud CLI is used.

      children = [
        {Goth, name: MyApp.Goth, source: {:service_account, credentials,
          scopes: ["https://www.googleapis.com/auth/devstorage.read_write"]}}
      ]

      config :gcp_gcs, :goth, MyApp.Goth
  """

  # Goth is an optional dependency; calls are guarded by Code.ensure_loaded?/1.
  @compile {:no_warn_undefined, Goth}

  require Logger

  alias GcpGcs.Auth.Cache
  alias GcpGcs.{Config, Error, Telemetry}

  # Used when gcloud doesn't report an expiry (access tokens last ~60 min).
  @default_ttl_ms 50 * 60 * 1000
  # Stop using a token this long before it expires.
  @expiry_margin_ms 60_000

  @doc """
  Clears the cached access token, forcing a refresh on the next request.

  Useful after rotating credentials.
  """
  @spec clear_cache() :: :ok
  def clear_cache, do: Cache.clear()

  @doc """
  Returns the HTTP headers needed to authenticate a request.

  In emulator mode (without a per-call `:base_url`) returns `{:ok, []}`.
  Otherwise returns `{:ok, [{"authorization", "Bearer <token>"}]}`.

  ## Options
  - `:goth` — Goth instance name, overriding `config :gcp_gcs, :goth`
  - `:base_url` — when set, authentication is never skipped
  """
  @spec request_headers(keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, Error.t()}
  def request_headers(opts \\ []) do
    if is_nil(opts[:base_url]) and Config.emulator?() do
      {:ok, []}
    else
      case get_token(opts) do
        {:ok, token} -> {:ok, [{"authorization", token}]}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Returns a bearer token string (`"Bearer <token>"`).

  Takes the `:goth` option of `request_headers/1`.
  """
  @spec get_token(keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def get_token(opts \\ []) do
    case opts[:goth] || Application.get_env(:gcp_gcs, :goth) do
      nil -> gcloud_token()
      goth -> Telemetry.auth_span(%{source: :goth}, fn -> get_token_from_goth(goth) end)
    end
  end

  @doc false
  # Cache TTL for a token expiring at `expires` (`DateTime`, or integer Unix
  # seconds): until 60 s before expiry, never negative; 50 minutes when the
  # expiry is unknown.
  @spec expiry_ttl_ms(DateTime.t() | integer() | nil) :: non_neg_integer()
  def expiry_ttl_ms(nil), do: @default_ttl_ms

  def expiry_ttl_ms(expires) when is_integer(expires),
    do: expires |> DateTime.from_unix!() |> expiry_ttl_ms()

  def expiry_ttl_ms(%DateTime{} = expires) do
    max(DateTime.diff(expires, DateTime.utc_now(), :millisecond) - @expiry_margin_ms, 0)
  end

  # Goth ----------------------------------------------------------------------

  defp get_token_from_goth(goth_name) do
    if Code.ensure_loaded?(Goth) do
      goth_name |> Goth.fetch() |> handle_goth_result()
    else
      Logger.error("GcpGcs: :goth configured but Goth module not loaded")

      {:error,
       Error.new(
         :unauthenticated,
         "Goth configured but not loaded; add :goth to your deps or remove the :gcp_gcs :goth config"
       )}
    end
  rescue
    e ->
      Logger.error("GcpGcs: Goth.fetch raised: #{inspect(e.__struct__)}")
      {:error, Error.new(:unauthenticated, "Goth authentication crashed", e)}
  catch
    kind, reason ->
      Logger.error("GcpGcs: Goth.fetch exited: #{kind}")
      {:error, Error.new(:unauthenticated, "Goth authentication crashed", {kind, reason})}
  end

  defp handle_goth_result({:ok, %{token: token, type: type}})
       when is_binary(token) and is_binary(type) do
    {:ok, "#{type} #{token}"}
  end

  defp handle_goth_result({:error, reason}) do
    # Goth was explicitly configured — surface the failure rather than silently
    # falling back to the gcloud CLI.
    Logger.warning("GcpGcs: Goth.fetch failed (#{error_tag(reason)})")
    {:error, Error.new(:unauthenticated, "Goth authentication failed", reason)}
  end

  # gcloud --------------------------------------------------------------------

  defp gcloud_token do
    if Config.gcloud_fallback?() do
      Cache.fetch(fn -> Telemetry.auth_span(%{source: :gcloud}, &fetch_from_gcloud/0) end)
    else
      {:error,
       Error.new(
         :unauthenticated,
         "no credentials: configure :goth (the gcloud fallback is disabled)"
       )}
    end
  end

  # gcloud's stderr is merged into stdout so failures stay diagnosable, which
  # means a successful run can also carry warning lines (e.g. "Updates are
  # available"). The JSON projection limits the output to the token and its
  # expiry; older gcloud versions that ignore it print the bare token, so a
  # single line of visible ASCII is accepted as the token as a fallback.
  @gcloud_args [
    "auth",
    "application-default",
    "print-access-token",
    "--format=json(token,expiry.datetime)"
  ]
  @token_line ~r/\A[\x21-\x7E]+\z/
  @max_token_bytes 4096

  # Returns {:ok, bearer, ttl_ms} | {:error, error} for GcpGcs.Auth.Cache.
  defp fetch_from_gcloud do
    case System.cmd(Config.gcloud_path(), @gcloud_args, stderr_to_stdout: true) do
      {output, 0} ->
        case parse_gcloud_output(output) do
          {:ok, token, ttl_ms} ->
            {:ok, "Bearer " <> token, ttl_ms}

          :error ->
            Logger.error("GcpGcs: gcloud returned malformed output")
            {:error, Error.new(:unauthenticated, "gcloud returned malformed output")}
        end

      {error_output, exit_code} ->
        # Raw stderr at debug only (may contain ADC paths / account emails).
        Logger.debug(fn -> "GcpGcs: gcloud stderr: #{String.trim(error_output)}" end)
        Logger.error("GcpGcs: gcloud CLI auth failed (exit #{exit_code})")

        {:error,
         Error.new(
           :unauthenticated,
           "gcloud CLI auth failed (exit #{exit_code})",
           {:gcloud_exit, exit_code}
         )}
    end
  rescue
    # System.cmd/3 raises ErlangError (e.g. `:enoent`) when gcloud can't be run.
    e in ErlangError ->
      Logger.error("GcpGcs: auth unavailable: gcloud could not be run (#{inspect(e.original)})")
      {:error, Error.new(:unauthenticated, "no authentication available", e)}
  end

  defp parse_gcloud_output(output) do
    case parse_gcloud_json(output) do
      {:ok, _token, _ttl} = ok -> ok
      :error -> with {:ok, token} <- extract_token_line(output), do: {:ok, token, @default_ttl_ms}
    end
  end

  # `{"expiry": {"datetime": "2026-10-21 01:04:18.861013"}, "token": "..."}`,
  # possibly surrounded by warning lines; the datetime is UTC.
  defp parse_gcloud_json(output) do
    with [_, json] <- Regex.run(~r/(\{.*\})/s, output),
         {:ok, %{"token" => token} = decoded} <- JSON.decode(json),
         true <- valid_token?(token) do
      {:ok, token, expiry_ttl_ms(gcloud_expiry(decoded))}
    else
      _ -> :error
    end
  end

  defp gcloud_expiry(%{"expiry" => %{"datetime" => datetime}}) when is_binary(datetime) do
    case NaiveDateTime.from_iso8601(datetime) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      {:error, _} -> nil
    end
  end

  defp gcloud_expiry(_), do: nil

  # The last line of the output that looks like a token.
  defp extract_token_line(output) do
    output
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reverse()
    |> Enum.find(&valid_token?/1)
    |> case do
      nil -> :error
      token -> {:ok, token}
    end
  end

  defp valid_token?(token) when is_binary(token),
    do: byte_size(token) < @max_token_bytes and Regex.match?(@token_line, token)

  defp valid_token?(_), do: false

  # Best-effort tag for logging: an atom describing the error shape, never its contents.
  defp error_tag(%{__struct__: mod}), do: mod
  defp error_tag(reason) when is_atom(reason), do: reason
  defp error_tag({tag, _}) when is_atom(tag), do: tag
  defp error_tag(_), do: :unknown
end

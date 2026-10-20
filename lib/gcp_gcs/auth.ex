defmodule GcpGcs.Auth do
  @moduledoc """
  Authentication for Google Cloud Storage.

  Retrieves OAuth2 access tokens (with ETS-based caching) using, in order of
  preference:

  1. **Goth** — if configured (`config :gcp_gcs, :goth, MyApp.Goth`)
  2. **gcloud CLI** — `gcloud auth application-default print-access-token`
  3. Returns a structured `GcpGcs.Error` if no credentials are available

  When an emulator is configured (see `GcpGcs.Config`), authentication is
  skipped entirely and requests are sent without an `authorization` header.

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

  alias GcpGcs.{Error, Telemetry}

  @table :gcp_gcs_auth_cache
  @cache_key :token
  # Cache gcloud CLI tokens for 50 minutes (access tokens last ~60 min).
  @cli_token_ttl_ms 50 * 60 * 1000

  @doc """
  Clears the cached access token, forcing a refresh on the next request.

  Useful after rotating credentials.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  @doc """
  Returns the HTTP headers needed to authenticate a request.

  In emulator mode returns `{:ok, []}`. In production returns
  `{:ok, [{"authorization", "Bearer <token>"}]}`.
  """
  @spec request_headers() :: {:ok, [{String.t(), String.t()}]} | {:error, Error.t()}
  def request_headers do
    if GcpGcs.Config.emulator?() do
      {:ok, []}
    else
      case get_token() do
        {:ok, token} -> {:ok, [{"authorization", token}]}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Returns a bearer token string (`"Bearer <token>"`), cached in ETS.
  """
  @spec get_token() :: {:ok, String.t()} | {:error, Error.t()}
  def get_token do
    case get_cached_token() do
      {:ok, token} -> {:ok, token}
      :miss -> fetch_and_cache_token()
    end
  end

  # Private

  defp get_cached_token do
    case :ets.lookup(@table, @cache_key) do
      [{@cache_key, token, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, token}, else: :miss

      [] ->
        :miss
    end
  rescue
    # Table doesn't exist yet (Cache GenServer not started, or torn down).
    ArgumentError -> :miss
  end

  defp cache_token(token, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {@cache_key, token, expires_at})
    :ok
  rescue
    ArgumentError ->
      # Cache table gone (GcpGcs.Auth.Cache not started/crashed). Returning the
      # token still works, but every request will re-fetch until the cache is
      # back — warn so that token-fetch storms are diagnosable.
      Logger.warning("GcpGcs: auth cache table unavailable; token not cached")
      :ok
  end

  defp fetch_and_cache_token do
    {source, fun} =
      case Application.get_env(:gcp_gcs, :goth) do
        nil -> {:gcloud, fn -> get_token_from_gcloud() end}
        goth_name -> {:goth, fn -> get_token_from_goth(goth_name) end}
      end

    Telemetry.auth_span(%{source: source}, fun)
  end

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

  defp handle_goth_result({:ok, %{token: token, type: type} = result})
       when is_binary(token) and is_binary(type) do
    bearer = "#{type} #{token}"
    cache_token(bearer, goth_ttl_ms(result))
    {:ok, bearer}
  end

  defp handle_goth_result({:error, reason}) do
    # Goth was explicitly configured — surface the failure rather than silently
    # falling back to the gcloud CLI.
    Logger.warning("GcpGcs: Goth.fetch failed (#{error_tag(reason)})")
    {:error, Error.new(:unauthenticated, "Goth authentication failed", reason)}
  end

  @doc false
  # Cache TTL for a Goth token: until 60 s before its expiry (integer Unix
  # seconds or `DateTime`), never negative; 50 minutes when the expiry is unknown.
  @spec goth_ttl_ms(map()) :: non_neg_integer()
  def goth_ttl_ms(%{expires: expires}) when not is_nil(expires) do
    expires_dt =
      cond do
        is_integer(expires) -> DateTime.from_unix!(expires)
        match?(%DateTime{}, expires) -> expires
        true -> nil
      end

    case expires_dt do
      nil -> @cli_token_ttl_ms
      dt -> max(DateTime.diff(dt, DateTime.utc_now(), :millisecond) - 60_000, 0)
    end
  end

  def goth_ttl_ms(_), do: @cli_token_ttl_ms

  # gcloud's stderr is merged into stdout so failures stay diagnosable, which
  # means a successful run can also carry warning lines (e.g. "Updates are
  # available"). Only a single line of visible ASCII is accepted as the token.
  @token_line ~r/\A[\x21-\x7E]+\z/
  @max_token_bytes 4096

  defp get_token_from_gcloud do
    case System.cmd("gcloud", ["auth", "application-default", "print-access-token"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case extract_token(output) do
          {:ok, token} ->
            bearer = "Bearer " <> token
            cache_token(bearer, @cli_token_ttl_ms)
            {:ok, bearer}

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

  # The last line of the output that looks like a token.
  defp extract_token(output) do
    output
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reverse()
    |> Enum.find(&(byte_size(&1) < @max_token_bytes and Regex.match?(@token_line, &1)))
    |> case do
      nil -> :error
      token -> {:ok, token}
    end
  end

  # Best-effort tag for logging: an atom describing the error shape, never its contents.
  defp error_tag(%{__struct__: mod}), do: mod
  defp error_tag(reason) when is_atom(reason), do: reason
  defp error_tag({tag, _}) when is_atom(tag), do: tag
  defp error_tag(_), do: :unknown
end

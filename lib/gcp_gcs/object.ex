defmodule GcpGcs.Object do
  @moduledoc """
  Object metadata operations for the Google Cloud Storage JSON API.

  Responses are the decoded JSON
  [Object resource](https://cloud.google.com/storage/docs/json_api/v1/objects)
  as a map with string keys. For transferring object *bytes*, see
  `GcpGcs.Upload` and `GcpGcs.Download`.

  These functions are exposed through the top-level `GcpGcs` module.
  """

  alias GcpGcs.{Client, Config, Error, Result, Telemetry, Validation}

  @doc """
  Gets an object's metadata (not its contents).

  ## Options
  - `:generation` — a specific object generation
  - `:timeout` — request timeout in ms
  """
  @spec get(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(bucket, object, opts \\ []) do
    Telemetry.span(:get_object, %{bucket: bucket, object: object}, fn ->
      with {:ok, _} <- Validation.validate_bucket(bucket),
           {:ok, _} <- Validation.validate_object(object) do
        query = compact(generation: opts[:generation])

        Client.request(:get, object_url(bucket, object), query: query, timeout: opts[:timeout])
      end
    end)
  end

  @doc """
  Lists objects in a bucket.

  ## Options
  - `:prefix` — filter to names starting with this prefix
  - `:delimiter` — collapse names with this delimiter into `:prefixes`
    (use `"/"` to list a single "directory" level)
  - `:page_size` — maximum results per page (maps to `maxResults`)
  - `:page_token` — pagination token
  - `:start_offset` / `:end_offset` — lexicographic range filters
  - `:versions` — `true` to include non-current object versions

  Returns `{:ok, %{items: [...], prefixes: [...], next_page_token: token}}`.
  """
  @spec list(String.t(), keyword()) ::
          {:ok, %{items: list(), prefixes: list(), next_page_token: String.t() | nil}}
          | {:error, Error.t()}
  def list(bucket, opts \\ []) do
    Telemetry.span(:list_objects, %{bucket: bucket}, fn ->
      with {:ok, _} <- Validation.validate_bucket(bucket) do
        query =
          compact(
            prefix: opts[:prefix],
            delimiter: opts[:delimiter],
            maxResults: opts[:page_size],
            pageToken: opts[:page_token],
            startOffset: opts[:start_offset],
            endOffset: opts[:end_offset],
            versions: opts[:versions]
          )

        :get
        |> Client.request(Config.json_base() <> "/b/#{bucket}/o",
          query: query,
          timeout: opts[:timeout]
        )
        |> Result.list("items")
      end
    end)
  end

  @doc "Deletes an object. Returns `:ok` on success."
  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(bucket, object, opts \\ []) do
    Telemetry.span(:delete_object, %{bucket: bucket, object: object}, fn ->
      with {:ok, _} <- Validation.validate_bucket(bucket),
           {:ok, _} <- Validation.validate_object(object) do
        query = compact(generation: opts[:generation])

        :delete
        |> Client.request(object_url(bucket, object), query: query, timeout: opts[:timeout])
        |> Result.as_ok()
      end
    end)
  end

  @doc """
  Patches an object's metadata with `attrs` (a map of Object resource fields,
  e.g. `%{"contentType" => "text/plain", "metadata" => %{"key" => "value"}}`).
  """
  @spec update(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def update(bucket, object, attrs, opts \\ []) when is_map(attrs) do
    Telemetry.span(:update_object, %{bucket: bucket, object: object}, fn ->
      with {:ok, _} <- Validation.validate_bucket(bucket),
           {:ok, _} <- Validation.validate_object(object) do
        Client.request(:patch, object_url(bucket, object),
          body: {:json, attrs},
          timeout: opts[:timeout]
        )
      end
    end)
  end

  @doc """
  Copies an object. Suitable for same-location copies; for large or
  cross-location copies prefer `rewrite/5`.

  ## Options
  - `:attrs` — destination Object resource fields to set
  - `:timeout` — request timeout in ms
  """
  @spec copy(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def copy(src_bucket, src_object, dst_bucket, dst_object, opts \\ []) do
    meta = %{
      src_bucket: src_bucket,
      src_object: src_object,
      dst_bucket: dst_bucket,
      dst_object: dst_object
    }

    Telemetry.span(:copy_object, meta, fn ->
      with {:ok, _} <- Validation.validate_bucket(src_bucket),
           {:ok, _} <- Validation.validate_object(src_object),
           {:ok, _} <- Validation.validate_bucket(dst_bucket),
           {:ok, _} <- Validation.validate_object(dst_object) do
        url =
          "#{object_url(src_bucket, src_object)}/copyTo/b/#{dst_bucket}/o/#{Client.encode_object(dst_object)}"

        Client.request(:post, url, body: {:json, opts[:attrs] || %{}}, timeout: opts[:timeout])
      end
    end)
  end

  @doc """
  Concatenates up to 32 source objects in the same bucket into `dest_object`.

  `sources` is a list of object names (strings) or maps with a `"name"` key.

  ## Options
  - `:attrs` — destination Object resource fields (e.g. `%{"contentType" => ...}`)
  - `:timeout` — request timeout in ms
  """
  @spec compose(String.t(), String.t(), [String.t() | map()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def compose(bucket, dest_object, sources, opts \\ []) do
    Telemetry.span(:compose_object, %{bucket: bucket, object: dest_object}, fn ->
      with {:ok, _} <- Validation.validate_bucket(bucket),
           {:ok, _} <- Validation.validate_object(dest_object),
           {:ok, _} <- Validation.validate_source_objects(sources) do
        body = %{
          "sourceObjects" => Enum.map(sources, &normalize_source/1),
          "destination" => opts[:attrs] || %{}
        }

        url = "#{object_url(bucket, dest_object)}/compose"
        Client.request(:post, url, body: {:json, body}, timeout: opts[:timeout])
      end
    end)
  end

  @doc """
  Rewrites (copies) an object, following GCS rewrite tokens until the operation
  completes. Handles large and cross-location/cross-storage-class copies that a
  single `copy/5` cannot.

  ## Options
  - `:attrs` — destination Object resource fields to set
  - `:max_bytes_per_call` — `maxBytesRewrittenPerCall` (must be a multiple of 1 MiB)
  - `:timeout` — request timeout per underlying call, in ms

  Returns `{:ok, object_resource}` for the finished object.
  """
  @spec rewrite(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def rewrite(src_bucket, src_object, dst_bucket, dst_object, opts \\ []) do
    meta = %{
      src_bucket: src_bucket,
      src_object: src_object,
      dst_bucket: dst_bucket,
      dst_object: dst_object
    }

    Telemetry.span(:rewrite_object, meta, fn ->
      with {:ok, _} <- Validation.validate_bucket(src_bucket),
           {:ok, _} <- Validation.validate_object(src_object),
           {:ok, _} <- Validation.validate_bucket(dst_bucket),
           {:ok, _} <- Validation.validate_object(dst_object) do
        url =
          "#{object_url(src_bucket, src_object)}/rewriteTo/b/#{dst_bucket}/o/#{Client.encode_object(dst_object)}"

        rewrite_loop(url, opts[:attrs] || %{}, opts, nil)
      end
    end)
  end

  @doc """
  Moves (renames) an object within a bucket. Requires a bucket with
  [hierarchical namespace](https://cloud.google.com/storage/docs/hns-overview)
  enabled.
  """
  @spec move(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def move(bucket, src_object, dst_object, opts \\ []) do
    Telemetry.span(
      :move_object,
      %{bucket: bucket, src_object: src_object, dst_object: dst_object},
      fn ->
        with {:ok, _} <- Validation.validate_bucket(bucket),
             {:ok, _} <- Validation.validate_object(src_object),
             {:ok, _} <- Validation.validate_object(dst_object) do
          url = "#{object_url(bucket, src_object)}/moveTo/o/#{Client.encode_object(dst_object)}"
          Client.request(:post, url, timeout: opts[:timeout])
        end
      end
    )
  end

  # Private

  defp rewrite_loop(url, attrs, opts, token) do
    query = compact(rewriteToken: token, maxBytesRewrittenPerCall: opts[:max_bytes_per_call])

    case Client.request(:post, url, query: query, body: {:json, attrs}, timeout: opts[:timeout]) do
      {:ok, %{"done" => true, "resource" => resource}} ->
        {:ok, resource}

      {:ok, %{"rewriteToken" => next}} when is_binary(next) ->
        rewrite_loop(url, attrs, opts, next)

      {:ok, %{"resource" => resource}} ->
        {:ok, resource}

      {:ok, other} ->
        {:ok, other}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp object_url(bucket, object) do
    Config.json_base() <> "/b/#{bucket}/o/#{Client.encode_object(object)}"
  end

  defp normalize_source(name) when is_binary(name), do: %{"name" => name}
  defp normalize_source(%{} = m), do: Map.new(m, fn {k, v} -> {to_string(k), v} end)

  defp compact(pairs), do: Enum.reject(pairs, fn {_k, v} -> is_nil(v) end)
end

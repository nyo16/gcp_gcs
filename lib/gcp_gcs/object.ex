defmodule GcpGcs.Object do
  @moduledoc """
  Object metadata operations for the Google Cloud Storage JSON API.

  Responses are the decoded JSON
  [Object resource](https://cloud.google.com/storage/docs/json_api/v1/objects)
  as a map with string keys. For transferring object *bytes*, see
  `GcpGcs.Upload` and `GcpGcs.Download`.

  Every function also accepts the transport options `:timeout`,
  `:pool_timeout`, `:request_timeout`, `:retry`, `:finch`, `:goth` and
  `:base_url` (see `GcpGcs.Config`). Unknown options return
  `{:error, %GcpGcs.Error{code: :validation_error}}`.

  These functions are exposed through the top-level `GcpGcs` module.
  """

  alias GcpGcs.{Client, Error, Result, Telemetry, Validation}

  @doc """
  Gets an object's metadata (not its contents).

  ## Options
  - `:generation` — a specific object generation
  """
  @spec get(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(bucket, object, opts \\ []) do
    Telemetry.span(:get_object, %{bucket: bucket, object: object}, fn ->
      with {:ok, _} <- validate_opts(opts, [:generation]),
           {:ok, _} <- Validation.validate_location(bucket, object) do
        Client.request(
          :get,
          Client.object_path(bucket, object),
          [query: [generation: opts[:generation]]] ++ Client.transport_opts(opts)
        )
      end
    end)
  end

  @list_opts [
    :prefix,
    :delimiter,
    :page_size,
    :page_token,
    :start_offset,
    :end_offset,
    :versions,
    :fields
  ]

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
  - `:fields` — partial-response field selector, e.g.
    `"items(name,size),prefixes,nextPageToken"` (keep `nextPageToken` to
    paginate)

  Returns `{:ok, %{items: [object], prefixes: [prefix], next_page_token:
  token | nil}}`, an atom-keyed page around string-keyed Object resources.
  """
  @spec list(String.t(), keyword()) :: {:ok, GcpGcs.object_page()} | {:error, Error.t()}
  def list(bucket, opts \\ []) do
    Telemetry.span(:list_objects, %{bucket: bucket, object: nil}, fn ->
      with {:ok, _} <- validate_opts(opts, @list_opts),
           {:ok, _} <- Validation.validate_bucket(bucket) do
        query = [
          prefix: opts[:prefix],
          delimiter: opts[:delimiter],
          maxResults: opts[:page_size],
          pageToken: opts[:page_token],
          startOffset: opts[:start_offset],
          endOffset: opts[:end_offset],
          versions: opts[:versions],
          fields: opts[:fields]
        ]

        :get
        |> Client.request("/b/#{bucket}/o", [query: query] ++ Client.transport_opts(opts))
        |> Result.list(:objects)
      end
    end)
  end

  @doc """
  Lazily lists every object in a bucket, following page tokens.

  Takes the options of `list/2`; `:page_size` sets how many objects each
  request fetches. Pages are requested only as the stream is consumed, so
  `Enum.take(stream, 10)` stops after the pages it needs. Only `items` are
  emitted (not `prefixes`).

  **Raises** `GcpGcs.Error` when a page request fails (including invalid
  options), since a stream cannot return an error tuple. This (with
  `GcpGcs.Bucket.stream!/2`) is the only raising API.
  """
  @spec stream!(String.t(), keyword()) :: Enumerable.t()
  def stream!(bucket, opts \\ []) do
    case validate_opts(opts, @list_opts) do
      {:ok, _} ->
        Result.stream_pages(opts[:page_token], fn token ->
          list(bucket, Keyword.put(opts, :page_token, token))
        end)

      {:error, %Error{} = error} ->
        raise error
    end
  end

  @doc """
  Deletes an object. Returns `:ok` on success.

  ## Options
  - `:generation` — delete a specific generation
  """
  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(bucket, object, opts \\ []) do
    Telemetry.span(:delete_object, %{bucket: bucket, object: object}, fn ->
      with {:ok, _} <- validate_opts(opts, [:generation]),
           {:ok, _} <- Validation.validate_location(bucket, object) do
        :delete
        |> Client.request(
          Client.object_path(bucket, object),
          [query: [generation: opts[:generation]]] ++ Client.transport_opts(opts)
        )
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
  def update(bucket, object, attrs, opts \\ []) do
    Telemetry.span(:update_object, %{bucket: bucket, object: object}, fn ->
      with {:ok, _} <- validate_opts(opts, []),
           {:ok, _} <- Validation.validate_location(bucket, object),
           {:ok, _} <- Validation.validate_map(attrs, "attrs") do
        Client.request(
          :patch,
          Client.object_path(bucket, object),
          [body: {:json, attrs}] ++ Client.transport_opts(opts)
        )
      end
    end)
  end

  @doc """
  Copies an object. Suitable for same-location copies; for large or
  cross-location copies prefer `rewrite/5`.

  ## Options
  - `:attrs` — destination Object resource fields to set
  """
  @spec copy(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def copy(src_bucket, src_object, dst_bucket, dst_object, opts \\ []) do
    meta = transfer_meta(src_bucket, src_object, dst_bucket, dst_object)

    Telemetry.span(:copy_object, meta, fn ->
      with {:ok, _} <- validate_opts(opts, [:attrs]),
           {:ok, _} <- Validation.validate_location(src_bucket, src_object),
           {:ok, _} <- Validation.validate_location(dst_bucket, dst_object),
           {:ok, attrs} <- Validation.validate_map(Keyword.get(opts, :attrs, %{}), ":attrs") do
        path =
          Client.object_path(src_bucket, src_object) <>
            "/copyTo" <> Client.object_path(dst_bucket, dst_object)

        Client.request(:post, path, [body: {:json, attrs}] ++ Client.transport_opts(opts))
      end
    end)
  end

  @doc """
  Concatenates up to 32 source objects in the same bucket into `dest_object`.

  `sources` is a list of object names (strings) or maps with a `"name"` key.

  ## Options
  - `:attrs` — destination Object resource fields (e.g. `%{"contentType" => ...}`)
  """
  @spec compose(String.t(), String.t(), [String.t() | map()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def compose(bucket, dest_object, sources, opts \\ []) do
    Telemetry.span(:compose_object, %{bucket: bucket, object: dest_object}, fn ->
      with {:ok, _} <- validate_opts(opts, [:attrs]),
           {:ok, _} <- Validation.validate_location(bucket, dest_object),
           {:ok, _} <- Validation.validate_source_objects(sources),
           {:ok, attrs} <- Validation.validate_map(Keyword.get(opts, :attrs, %{}), ":attrs") do
        body = %{
          "sourceObjects" => Enum.map(sources, &normalize_source/1),
          "destination" => attrs
        }

        Client.request(
          :post,
          Client.object_path(bucket, dest_object) <> "/compose",
          [body: {:json, body}] ++ Client.transport_opts(opts)
        )
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

  Transport options such as `:timeout` apply per underlying call.

  Returns `{:ok, object_resource}` for the finished object.
  """
  @spec rewrite(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def rewrite(src_bucket, src_object, dst_bucket, dst_object, opts \\ []) do
    meta = transfer_meta(src_bucket, src_object, dst_bucket, dst_object)

    Telemetry.span(:rewrite_object, meta, fn ->
      with {:ok, _} <- validate_opts(opts, [:attrs, :max_bytes_per_call]),
           {:ok, _} <- Validation.validate_location(src_bucket, src_object),
           {:ok, _} <- Validation.validate_location(dst_bucket, dst_object),
           {:ok, attrs} <- Validation.validate_map(Keyword.get(opts, :attrs, %{}), ":attrs") do
        path =
          Client.object_path(src_bucket, src_object) <>
            "/rewriteTo" <> Client.object_path(dst_bucket, dst_object)

        rewrite_loop(path, attrs, opts, nil)
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
    meta = transfer_meta(bucket, src_object, bucket, dst_object)

    Telemetry.span(:move_object, meta, fn ->
      with {:ok, _} <- validate_opts(opts, []),
           {:ok, _} <- Validation.validate_location(bucket, src_object),
           {:ok, _} <- Validation.validate_object(dst_object) do
        path =
          Client.object_path(bucket, src_object) <>
            "/moveTo/o/" <> Client.encode_object(dst_object)

        Client.request(:post, path, Client.transport_opts(opts))
      end
    end)
  end

  # Private

  # `:bucket`/`:object` name the destination; the source is in `:src_*`.
  defp transfer_meta(src_bucket, src_object, dst_bucket, dst_object) do
    %{
      bucket: dst_bucket,
      object: dst_object,
      src_bucket: src_bucket,
      src_object: src_object
    }
  end

  defp validate_opts(opts, keys),
    do: Validation.validate_opts(opts, keys ++ Client.transport_keys())

  defp rewrite_loop(path, attrs, opts, token) do
    query = [rewriteToken: token, maxBytesRewrittenPerCall: opts[:max_bytes_per_call]]
    request_opts = [query: query, body: {:json, attrs}] ++ Client.transport_opts(opts)

    case Client.request(:post, path, request_opts) do
      {:ok, %{"done" => true, "resource" => resource}} ->
        {:ok, resource}

      {:ok, %{"rewriteToken" => next}} when is_binary(next) ->
        rewrite_loop(path, attrs, opts, next)

      {:ok, %{"resource" => resource}} ->
        {:ok, resource}

      {:ok, other} ->
        {:error, Error.new(:protocol_error, "unexpected rewrite response", other)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp normalize_source(name) when is_binary(name), do: %{"name" => name}
  defp normalize_source(%{} = m), do: Map.new(m, fn {k, v} -> {to_string(k), v} end)
end

defmodule GcpGcs.Bucket do
  @moduledoc """
  Bucket operations for the Google Cloud Storage JSON API.

  Responses are the decoded JSON
  [Bucket resource](https://cloud.google.com/storage/docs/json_api/v1/buckets)
  as a map with string keys (e.g. `%{"name" => ..., "location" => ...}`).

  Every function also accepts the transport options `:timeout`,
  `:pool_timeout`, `:request_timeout`, `:retry`, `:finch`, `:goth` and
  `:base_url` (see `GcpGcs.Config`). Unknown options return
  `{:error, %GcpGcs.Error{code: :validation_error}}`.

  These functions are exposed through the top-level `GcpGcs` module; call them
  there unless you need the focused namespace.
  """

  alias GcpGcs.{Client, Error, Result, Telemetry, Validation}

  @doc """
  Creates a bucket in `project_id`.

  ## Options
  - `:location` — e.g. `"US"`, `"EU"`, `"us-central1"`
  - `:storage_class` — e.g. `"STANDARD"`, `"NEARLINE"`, `"COLDLINE"`, `"ARCHIVE"`
  - `:predefined_acl` — e.g. `"private"`, `"publicRead"`
  - `:attrs` — a map of any additional
    [Bucket resource](https://cloud.google.com/storage/docs/json_api/v1/buckets#resource)
    fields, merged into the request body
  """
  @spec create(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(project_id, bucket, opts \\ []) do
    Telemetry.span(:create_bucket, %{project_id: project_id, bucket: bucket, object: nil}, fn ->
      with {:ok, _} <- validate_opts(opts, [:location, :storage_class, :predefined_acl, :attrs]),
           {:ok, _} <- Validation.validate_project_id(project_id),
           {:ok, _} <- Validation.validate_bucket(bucket),
           {:ok, attrs} <- Validation.validate_map(Keyword.get(opts, :attrs, %{}), ":attrs") do
        body =
          attrs
          |> Map.merge(%{"name" => bucket})
          |> maybe_put("location", opts[:location])
          |> maybe_put("storageClass", opts[:storage_class])

        query = [project: project_id, predefinedAcl: opts[:predefined_acl]]

        Client.request(
          :post,
          "/b",
          [query: query, body: {:json, body}] ++ Client.transport_opts(opts)
        )
      end
    end)
  end

  @doc "Gets a bucket's metadata."
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(bucket, opts \\ []) do
    Telemetry.span(:get_bucket, %{bucket: bucket, object: nil}, fn ->
      with {:ok, _} <- validate_opts(opts, []),
           {:ok, _} <- Validation.validate_bucket(bucket) do
        Client.request(:get, "/b/#{bucket}", Client.transport_opts(opts))
      end
    end)
  end

  @list_opts [:prefix, :page_size, :page_token, :fields]

  @doc """
  Lists buckets in `project_id`.

  ## Options
  - `:prefix` — filter results to names starting with this prefix
  - `:page_size` — maximum results per page (maps to `maxResults`)
  - `:page_token` — pagination token
  - `:fields` — partial-response field selector, e.g.
    `"items(name,location),nextPageToken"` (keep `nextPageToken` to paginate)

  Returns `{:ok, %{items: [bucket], next_page_token: token | nil}}`, an
  atom-keyed page around string-keyed Bucket resources.
  """
  @spec list(String.t(), keyword()) :: {:ok, GcpGcs.bucket_page()} | {:error, Error.t()}
  def list(project_id, opts \\ []) do
    Telemetry.span(:list_buckets, %{project_id: project_id, bucket: nil, object: nil}, fn ->
      with {:ok, _} <- validate_opts(opts, @list_opts),
           {:ok, _} <- Validation.validate_project_id(project_id) do
        query = [
          project: project_id,
          prefix: opts[:prefix],
          maxResults: opts[:page_size],
          pageToken: opts[:page_token],
          fields: opts[:fields]
        ]

        :get
        |> Client.request("/b", [query: query] ++ Client.transport_opts(opts))
        |> Result.list(:buckets)
      end
    end)
  end

  @doc """
  Lazily lists every bucket in `project_id`, following page tokens.

  Takes the options of `list/2`. Pages are requested only as the stream is
  consumed.

  **Raises** `GcpGcs.Error` when a page request fails (including invalid
  options), since a stream cannot return an error tuple. This (with
  `GcpGcs.Object.stream!/2`) is the only raising API.
  """
  @spec stream!(String.t(), keyword()) :: Enumerable.t()
  def stream!(project_id, opts \\ []) do
    case validate_opts(opts, @list_opts) do
      {:ok, _} ->
        Result.stream_pages(opts[:page_token], fn token ->
          list(project_id, Keyword.put(opts, :page_token, token))
        end)

      {:error, %Error{} = error} ->
        raise error
    end
  end

  @doc "Deletes a bucket. Returns `:ok` on success."
  @spec delete(String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(bucket, opts \\ []) do
    Telemetry.span(:delete_bucket, %{bucket: bucket, object: nil}, fn ->
      with {:ok, _} <- validate_opts(opts, []),
           {:ok, _} <- Validation.validate_bucket(bucket) do
        :delete
        |> Client.request("/b/#{bucket}", Client.transport_opts(opts))
        |> Result.as_ok()
      end
    end)
  end

  @doc """
  Patches a bucket's metadata with `attrs` (a map of Bucket resource fields).
  """
  @spec update(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def update(bucket, attrs, opts \\ []) do
    Telemetry.span(:update_bucket, %{bucket: bucket, object: nil}, fn ->
      with {:ok, _} <- validate_opts(opts, []),
           {:ok, _} <- Validation.validate_bucket(bucket),
           {:ok, _} <- Validation.validate_map(attrs, "attrs") do
        Client.request(
          :patch,
          "/b/#{bucket}",
          [body: {:json, attrs}] ++ Client.transport_opts(opts)
        )
      end
    end)
  end

  # Private

  defp validate_opts(opts, keys),
    do: Validation.validate_opts(opts, keys ++ Client.transport_keys())

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

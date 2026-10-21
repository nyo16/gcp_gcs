defmodule GcpGcs.Bucket do
  @moduledoc """
  Bucket operations for the Google Cloud Storage JSON API.

  Responses are the decoded JSON
  [Bucket resource](https://cloud.google.com/storage/docs/json_api/v1/buckets)
  as a map with string keys (e.g. `%{"name" => ..., "location" => ...}`).

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
  - `:timeout` — request timeout in ms
  """
  @spec create(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(project_id, bucket, opts \\ []) do
    Telemetry.span(:create_bucket, %{project_id: project_id, bucket: bucket}, fn ->
      do_create(project_id, bucket, opts)
    end)
  end

  defp do_create(project_id, bucket, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_bucket(bucket) do
      body =
        opts
        |> Keyword.get(:attrs, %{})
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
  end

  @doc "Gets a bucket's metadata."
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(bucket, opts \\ []) do
    Telemetry.span(:get_bucket, %{bucket: bucket}, fn ->
      with {:ok, _} <- Validation.validate_bucket(bucket) do
        Client.request(:get, "/b/#{bucket}", Client.transport_opts(opts))
      end
    end)
  end

  @doc """
  Lists buckets in `project_id`.

  ## Options
  - `:prefix` — filter results to names starting with this prefix
  - `:page_size` — maximum results per page (maps to `maxResults`)
  - `:page_token` — pagination token

  Returns `{:ok, %{items: [...], next_page_token: token}}`.
  """
  @spec list(String.t(), keyword()) ::
          {:ok, %{items: list(), next_page_token: String.t() | nil}} | {:error, Error.t()}
  def list(project_id, opts \\ []) do
    Telemetry.span(:list_buckets, %{project_id: project_id}, fn ->
      with {:ok, _} <- Validation.validate_project_id(project_id) do
        query = [
          project: project_id,
          prefix: opts[:prefix],
          maxResults: opts[:page_size],
          pageToken: opts[:page_token]
        ]

        :get
        |> Client.request("/b", [query: query] ++ Client.transport_opts(opts))
        |> Result.list("items")
      end
    end)
  end

  @doc "Deletes a bucket. Returns `:ok` on success."
  @spec delete(String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(bucket, opts \\ []) do
    Telemetry.span(:delete_bucket, %{bucket: bucket}, fn ->
      with {:ok, _} <- Validation.validate_bucket(bucket) do
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
    Telemetry.span(:update_bucket, %{bucket: bucket}, fn ->
      with {:ok, _} <- Validation.validate_bucket(bucket),
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

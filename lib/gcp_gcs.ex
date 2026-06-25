defmodule GcpGcs do
  @moduledoc """
  Google Cloud Storage client for Elixir, built on the JSON API over `Finch`.

  Provides bucket and object management, simple and resumable uploads, and
  streamed downloads. Responses are decoded JSON resources (maps with string
  keys); errors are `t:GcpGcs.Error.t/0` structs.

  ## Configuration

  ### Production (default)

  No configuration is required — requests go to `storage.googleapis.com`.
  Authentication uses, in order: a configured Goth instance, then the
  `gcloud` CLI. See `GcpGcs.Auth`.

      # Optional: use Goth
      config :gcp_gcs, :goth, MyApp.Goth

  ### Development / test (emulator)

      config :gcp_gcs, :emulator,
        scheme: "http",
        host: "localhost",
        port: 4443

  See `GcpGcs.Config` for the full set of options.

  ## Error handling

  All functions return `{:ok, result}`/`:ok` or `{:error, %GcpGcs.Error{}}`.
  Pattern match on the error code:

      case GcpGcs.get_object("my-bucket", "missing.txt") do
        {:ok, object} -> object
        {:error, %GcpGcs.Error{code: :not_found}} -> :missing
        {:error, %GcpGcs.Error{} = err} -> raise "GCS error: \#{err}"
      end

  ## Examples

      # Buckets
      {:ok, _bucket} = GcpGcs.create_bucket("my-project", "my-bucket", location: "US")
      {:ok, %{items: buckets}} = GcpGcs.list_buckets("my-project")

      # Upload + download
      {:ok, _object} = GcpGcs.put_object("my-bucket", "hello.txt", "Hello!")
      {:ok, "Hello!"} = GcpGcs.download("my-bucket", "hello.txt")

      # Stream a large file in and out with constant memory
      {:ok, _} = GcpGcs.upload_file("my-bucket", "big.bin", "/tmp/big.bin")
      :ok = GcpGcs.download_to_file("my-bucket", "big.bin", "/tmp/copy.bin")

      # List a "directory"
      {:ok, %{items: items, prefixes: dirs}} =
        GcpGcs.list_objects("my-bucket", prefix: "logs/", delimiter: "/")
  """

  alias GcpGcs.{Auth, Bucket, Download, Object, Upload}

  # Buckets --------------------------------------------------------------------

  @doc "Creates a bucket. See `GcpGcs.Bucket.create/3`."
  defdelegate create_bucket(project_id, bucket, opts \\ []), to: Bucket, as: :create

  @doc "Gets a bucket's metadata. See `GcpGcs.Bucket.get/2`."
  defdelegate get_bucket(bucket, opts \\ []), to: Bucket, as: :get

  @doc "Lists buckets in a project. See `GcpGcs.Bucket.list/2`."
  defdelegate list_buckets(project_id, opts \\ []), to: Bucket, as: :list

  @doc "Deletes a bucket. See `GcpGcs.Bucket.delete/2`."
  defdelegate delete_bucket(bucket, opts \\ []), to: Bucket, as: :delete

  @doc "Patches a bucket's metadata. See `GcpGcs.Bucket.update/3`."
  defdelegate update_bucket(bucket, attrs, opts \\ []), to: Bucket, as: :update

  # Object metadata ------------------------------------------------------------

  @doc "Gets an object's metadata. See `GcpGcs.Object.get/3`."
  defdelegate get_object(bucket, object, opts \\ []), to: Object, as: :get

  @doc "Lists objects in a bucket. See `GcpGcs.Object.list/2`."
  defdelegate list_objects(bucket, opts \\ []), to: Object, as: :list

  @doc "Deletes an object. See `GcpGcs.Object.delete/3`."
  defdelegate delete_object(bucket, object, opts \\ []), to: Object, as: :delete

  @doc "Patches an object's metadata. See `GcpGcs.Object.update/4`."
  defdelegate update_object(bucket, object, attrs, opts \\ []), to: Object, as: :update

  @doc "Copies an object. See `GcpGcs.Object.copy/5`."
  defdelegate copy_object(src_bucket, src_object, dst_bucket, dst_object, opts \\ []),
    to: Object,
    as: :copy

  @doc "Concatenates source objects into a new object. See `GcpGcs.Object.compose/4`."
  defdelegate compose_object(bucket, dest_object, sources, opts \\ []), to: Object, as: :compose

  @doc "Rewrites/copies an object, following rewrite tokens. See `GcpGcs.Object.rewrite/5`."
  defdelegate rewrite_object(src_bucket, src_object, dst_bucket, dst_object, opts \\ []),
    to: Object,
    as: :rewrite

  @doc "Moves/renames an object (HNS buckets). See `GcpGcs.Object.move/4`."
  defdelegate move_object(bucket, src_object, dst_object, opts \\ []), to: Object, as: :move

  # Uploads --------------------------------------------------------------------

  @doc "Uploads in-memory data in one request. See `GcpGcs.Upload.put_object/4`."
  defdelegate put_object(bucket, object, data, opts \\ []), to: Upload

  @doc "Uploads from a binary, `{:file, path}`, or stream. See `GcpGcs.Upload.upload/4`."
  defdelegate upload(bucket, object, source, opts \\ []), to: Upload

  @doc "Resumable streamed upload of a local file. See `GcpGcs.Upload.upload_file/4`."
  defdelegate upload_file(bucket, object, path, opts \\ []), to: Upload

  @doc "Resumable upload from an enumerable of binaries. See `GcpGcs.Upload.upload_stream/4`."
  defdelegate upload_stream(bucket, object, enum, opts \\ []), to: Upload

  @doc "Starts a resumable upload session. See `GcpGcs.Upload.start_resumable_upload/3`."
  defdelegate start_resumable_upload(bucket, object, opts \\ []), to: Upload

  @doc "Uploads one chunk to a resumable session. See `GcpGcs.Upload.upload_chunk/3`."
  defdelegate upload_chunk(session_uri, data, opts), to: Upload

  # Downloads ------------------------------------------------------------------

  @doc "Downloads an object into memory. See `GcpGcs.Download.download/3`."
  defdelegate download(bucket, object, opts \\ []), to: Download

  @doc "Streams an object to a local file. See `GcpGcs.Download.download_to_file/4`."
  defdelegate download_to_file(bucket, object, path, opts \\ []), to: Download

  @doc "Folds an object's body through a reducer. See `GcpGcs.Download.stream/5`."
  defdelegate download_stream(bucket, object, opts, acc, reducer), to: Download, as: :stream

  # Auth -----------------------------------------------------------------------

  @doc "Clears the cached access token, forcing a refresh. See `GcpGcs.Auth.clear_cache/0`."
  defdelegate clear_auth_cache(), to: Auth, as: :clear_cache
end

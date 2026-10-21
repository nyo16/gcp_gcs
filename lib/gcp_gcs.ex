defmodule GcpGcs do
  @moduledoc """
  Google Cloud Storage client for Elixir, built on the JSON API over `Finch`.

  Provides bucket and object management, simple and resumable uploads, and
  streamed downloads. Single resources (buckets, objects) are the decoded JSON
  resources: maps with **string** keys. List results are **atom-keyed**
  wrappers (`%{items: [...], next_page_token: ...}`, plus `prefixes:` for
  objects) around string-keyed items. Errors are `t:GcpGcs.Error.t/0`
  structs.

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

  See `GcpGcs.Config` for the full set of options, including per-call
  overrides (`:goth`, `:finch`, `:base_url`, `:retry`, timeouts).

  ## Error handling

  All functions return `{:ok, result}`/`:ok` or `{:error, %GcpGcs.Error{}}`
  and never raise for invalid input, HTTP failures or transport errors. The
  one extra return shape is `upload_chunk/3`'s `{:resume, persisted}` for an
  incomplete resumable session; the only raising functions are the lazy
  `stream_objects!/2` and `stream_buckets!/2`. Unknown options are a
  `:validation_error`. Pattern match on the error code (see
  `t:GcpGcs.Error.code/0`):

      case GcpGcs.get_object("my-bucket", "missing.txt") do
        {:ok, object} -> object
        {:error, %GcpGcs.Error{code: :not_found}} -> :missing
        {:error, %GcpGcs.Error{} = err} -> raise err
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

      # Every object, lazily
      "my-bucket" |> GcpGcs.stream_objects!() |> Enum.count()
  """

  alias GcpGcs.{Auth, Bucket, Download, Error, Object, Upload}

  @typedoc "A bucket or object resource: the decoded JSON, with string keys."
  @type resource :: map()

  @typedoc "A page of `list_buckets/2`: atom keys around string-keyed Bucket resources."
  @type bucket_page :: %{items: [resource()], next_page_token: String.t() | nil}

  @typedoc "A page of `list_objects/2`: atom keys around string-keyed Object resources."
  @type object_page :: %{
          items: [resource()],
          prefixes: [String.t()],
          next_page_token: String.t() | nil
        }

  @typedoc "A function's documented options plus the transport options."
  @type opts :: keyword()

  # Buckets --------------------------------------------------------------------

  @doc "Creates a bucket. See `GcpGcs.Bucket.create/3`."
  @spec create_bucket(String.t(), String.t(), opts()) :: {:ok, resource()} | {:error, Error.t()}
  defdelegate create_bucket(project_id, bucket, opts \\ []), to: Bucket, as: :create

  @doc "Gets a bucket's metadata. See `GcpGcs.Bucket.get/2`."
  @spec get_bucket(String.t(), opts()) :: {:ok, resource()} | {:error, Error.t()}
  defdelegate get_bucket(bucket, opts \\ []), to: Bucket, as: :get

  @doc "Lists buckets in a project. See `GcpGcs.Bucket.list/2`."
  @spec list_buckets(String.t(), opts()) :: {:ok, bucket_page()} | {:error, Error.t()}
  defdelegate list_buckets(project_id, opts \\ []), to: Bucket, as: :list

  @doc "Lazily streams every bucket in a project; raises on error. See `GcpGcs.Bucket.stream!/2`."
  @spec stream_buckets!(String.t(), opts()) :: Enumerable.t()
  defdelegate stream_buckets!(project_id, opts \\ []), to: Bucket, as: :stream!

  @doc "Deletes a bucket. See `GcpGcs.Bucket.delete/2`."
  @spec delete_bucket(String.t(), opts()) :: :ok | {:error, Error.t()}
  defdelegate delete_bucket(bucket, opts \\ []), to: Bucket, as: :delete

  @doc "Patches a bucket's metadata. See `GcpGcs.Bucket.update/3`."
  @spec update_bucket(String.t(), map(), opts()) :: {:ok, resource()} | {:error, Error.t()}
  defdelegate update_bucket(bucket, attrs, opts \\ []), to: Bucket, as: :update

  # Object metadata ------------------------------------------------------------

  @doc "Gets an object's metadata. See `GcpGcs.Object.get/3`."
  @spec get_object(String.t(), String.t(), opts()) :: {:ok, resource()} | {:error, Error.t()}
  defdelegate get_object(bucket, object, opts \\ []), to: Object, as: :get

  @doc "Lists objects in a bucket. See `GcpGcs.Object.list/2`."
  @spec list_objects(String.t(), opts()) :: {:ok, object_page()} | {:error, Error.t()}
  defdelegate list_objects(bucket, opts \\ []), to: Object, as: :list

  @doc "Lazily streams every object in a bucket; raises on error. See `GcpGcs.Object.stream!/2`."
  @spec stream_objects!(String.t(), opts()) :: Enumerable.t()
  defdelegate stream_objects!(bucket, opts \\ []), to: Object, as: :stream!

  @doc "Deletes an object. See `GcpGcs.Object.delete/3`."
  @spec delete_object(String.t(), String.t(), opts()) :: :ok | {:error, Error.t()}
  defdelegate delete_object(bucket, object, opts \\ []), to: Object, as: :delete

  @doc "Patches an object's metadata. See `GcpGcs.Object.update/4`."
  @spec update_object(String.t(), String.t(), map(), opts()) ::
          {:ok, resource()} | {:error, Error.t()}
  defdelegate update_object(bucket, object, attrs, opts \\ []), to: Object, as: :update

  @doc "Copies an object. See `GcpGcs.Object.copy/5`."
  @spec copy_object(String.t(), String.t(), String.t(), String.t(), opts()) ::
          {:ok, resource()} | {:error, Error.t()}
  defdelegate copy_object(src_bucket, src_object, dst_bucket, dst_object, opts \\ []),
    to: Object,
    as: :copy

  @doc "Concatenates source objects into a new object. See `GcpGcs.Object.compose/4`."
  @spec compose_object(String.t(), String.t(), [String.t() | map()], opts()) ::
          {:ok, resource()} | {:error, Error.t()}
  defdelegate compose_object(bucket, dest_object, sources, opts \\ []), to: Object, as: :compose

  @doc "Rewrites/copies an object, following rewrite tokens. See `GcpGcs.Object.rewrite/5`."
  @spec rewrite_object(String.t(), String.t(), String.t(), String.t(), opts()) ::
          {:ok, resource()} | {:error, Error.t()}
  defdelegate rewrite_object(src_bucket, src_object, dst_bucket, dst_object, opts \\ []),
    to: Object,
    as: :rewrite

  @doc "Moves/renames an object (HNS buckets). See `GcpGcs.Object.move/4`."
  @spec move_object(String.t(), String.t(), String.t(), opts()) ::
          {:ok, resource()} | {:error, Error.t()}
  defdelegate move_object(bucket, src_object, dst_object, opts \\ []), to: Object, as: :move

  # Uploads --------------------------------------------------------------------

  @doc "Uploads in-memory data. See `GcpGcs.Upload.put_object/4`."
  @spec put_object(String.t(), String.t(), binary(), opts()) ::
          {:ok, resource()} | {:error, Error.t()}
  defdelegate put_object(bucket, object, data, opts \\ []), to: Upload

  @doc "Uploads from a binary, `{:file, path}`, or stream. See `GcpGcs.Upload.upload/4`."
  @spec upload(String.t(), String.t(), binary() | {:file, Path.t()} | Enumerable.t(), opts()) ::
          {:ok, resource()} | {:error, Error.t()}
  defdelegate upload(bucket, object, source, opts \\ []), to: Upload

  @doc "Resumable chunked upload of a local file. See `GcpGcs.Upload.upload_file/4`."
  @spec upload_file(String.t(), String.t(), Path.t(), opts()) ::
          {:ok, resource()} | {:error, Error.t()}
  defdelegate upload_file(bucket, object, path, opts \\ []), to: Upload

  @doc "Resumable upload from an enumerable of binaries. See `GcpGcs.Upload.upload_stream/4`."
  @spec upload_stream(String.t(), String.t(), Enumerable.t(), opts()) ::
          {:ok, resource()} | {:error, Error.t()}
  defdelegate upload_stream(bucket, object, enum, opts \\ []), to: Upload

  @doc "Starts a resumable upload session. See `GcpGcs.Upload.start_resumable_upload/3`."
  @spec start_resumable_upload(String.t(), String.t(), opts()) ::
          {:ok, String.t()} | {:error, Error.t()}
  defdelegate start_resumable_upload(bucket, object, opts \\ []), to: Upload

  @doc "Uploads one chunk to a resumable session. See `GcpGcs.Upload.upload_chunk/3`."
  @spec upload_chunk(String.t(), binary(), opts()) ::
          {:ok, resource()} | {:resume, non_neg_integer()} | {:error, Error.t()}
  defdelegate upload_chunk(session_uri, data, opts), to: Upload

  # Downloads ------------------------------------------------------------------

  @doc "Downloads an object into memory. See `GcpGcs.Download.download/3`."
  @spec download(String.t(), String.t(), opts()) :: {:ok, binary()} | {:error, Error.t()}
  defdelegate download(bucket, object, opts \\ []), to: Download

  @doc "Streams an object to a local file. See `GcpGcs.Download.download_to_file/4`."
  @spec download_to_file(String.t(), String.t(), Path.t(), opts()) :: :ok | {:error, Error.t()}
  defdelegate download_to_file(bucket, object, path, opts \\ []), to: Download

  @doc """
  Folds an object's body through `reducer`. See `GcpGcs.Download.stream/5`.

  The pre-0.3.0 order `download_stream(bucket, object, opts, acc, reducer)` is
  still accepted for this release, with a deprecation warning.
  """
  @spec download_stream(String.t(), String.t(), acc, (term(), acc -> term()), opts()) ::
          {:ok, acc} | {:error, Error.t()}
        when acc: term()
  defdelegate download_stream(bucket, object, acc, reducer, opts \\ []), to: Download, as: :stream

  # Auth -----------------------------------------------------------------------

  @doc "Clears the cached access token, forcing a refresh. See `GcpGcs.Auth.clear_cache/0`."
  @spec clear_auth_cache() :: :ok
  defdelegate clear_auth_cache(), to: Auth, as: :clear_cache
end

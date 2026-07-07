# GcpGcs

A Google Cloud Storage client for Elixir, built on the JSON API over
[Finch](https://hex.pm/packages/finch). Bucket and object management, simple
and **resumable** uploads, and **streamed** downloads — with structured errors,
token caching, and telemetry.

[![CI](https://github.com/nyo16/gcp_gcs/actions/workflows/ci.yml/badge.svg)](https://github.com/nyo16/gcp_gcs/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/gcp_gcs.svg)](https://hex.pm/packages/gcp_gcs)

## Features

- 📦 **Buckets & objects** — full CRUD, listing with prefixes/delimiters, copy,
  compose, rewrite, and move
- ⬆️ **Resumable uploads** — stream files or arbitrary producers with constant
  memory; simple one-shot uploads for small payloads
- ⬇️ **Streamed downloads** — to a binary, straight to a file, or folded through
  your own reducer
- 🔐 **Easy auth** — Goth or the `gcloud` CLI, with ETS-cached tokens
- 🧱 **Structured errors** — every failure is a `%GcpGcs.Error{}` with a stable
  `code` atom
- 📈 **Telemetry** — `[:gcp_gcs, :request, _]` and `[:gcp_gcs, :auth, _]` spans
- 🐳 **Dev-friendly** — `docker-compose` emulator (fake-gcs-server) included

## Installation

```elixir
def deps do
  [
    {:gcp_gcs, "~> 0.1.0"}
  ]
end
```

## Quick start

### Authenticate

```bash
# Development: use your own credentials
gcloud auth application-default login

# Production: a service account file (consumed via Goth)
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account.json"
```

### Use it

```elixir
project = "my-project"

# Create a bucket
{:ok, _bucket} = GcpGcs.create_bucket(project, "my-bucket", location: "US")

# Upload + download a small object
{:ok, _object} = GcpGcs.put_object("my-bucket", "hello.txt", "Hello!", content_type: "text/plain")
{:ok, "Hello!"} = GcpGcs.download("my-bucket", "hello.txt")

# Object metadata
{:ok, object} = GcpGcs.get_object("my-bucket", "hello.txt")
object["size"]         #=> "6"
object["contentType"]  #=> "text/plain"

# List objects (with pagination info)
{:ok, %{items: items, next_page_token: token}} = GcpGcs.list_objects("my-bucket")
```

Every call returns `{:ok, result}` / `:ok`, or `{:error, %GcpGcs.Error{}}`.
Responses are decoded JSON resources — plain maps with string keys.

## Uploads

```elixir
# Simple (in-memory) upload
{:ok, _} = GcpGcs.put_object("my-bucket", "notes.txt", "some text")

# Resumable streamed upload of a local file (constant memory)
{:ok, _} = GcpGcs.upload_file("my-bucket", "video.mp4", "/path/to/video.mp4")

# Resumable upload from any enumerable of binaries
chunks = Stream.repeatedly(fn -> :crypto.strong_rand_bytes(1_000_000) end) |> Stream.take(10)
{:ok, _} = GcpGcs.upload_stream("my-bucket", "random.bin", chunks)

# Let the library pick the strategy
{:ok, _} = GcpGcs.upload("my-bucket", "a.txt", "inline data")
{:ok, _} = GcpGcs.upload("my-bucket", "b.bin", {:file, "/path/to/b.bin"})
```

Content type is guessed from the object's extension for `upload_file/4`; pass
`content_type:` to override. Resumable chunk size defaults to 8 MiB and can be
tuned with `chunk_size:` (rounded to a 256 KiB multiple).

### Low-level resumable control

```elixir
{:ok, session} = GcpGcs.start_resumable_upload("my-bucket", "big.bin", content_type: "application/octet-stream")
{:resume, 262144} = GcpGcs.upload_chunk(session, chunk1, offset: 0, total: nil)
{:ok, _object}    = GcpGcs.upload_chunk(session, last_chunk, offset: 262144, total: 300000)
```

## Downloads

```elixir
# Whole object into memory
{:ok, bytes} = GcpGcs.download("my-bucket", "report.pdf")

# Stream straight to disk (constant memory)
:ok = GcpGcs.download_to_file("my-bucket", "report.pdf", "/tmp/report.pdf")

# Fold the body through your own reducer
{:ok, byte_count} =
  GcpGcs.download_stream("my-bucket", "big.bin", [], 0, fn
    {:data, chunk}, n -> n + byte_size(chunk)
    _other, n -> n
  end)
```

## Listing a "directory"

```elixir
{:ok, %{items: files, prefixes: subdirs}} =
  GcpGcs.list_objects("my-bucket", prefix: "logs/2026/", delimiter: "/")
```

## Copy, compose, rewrite, move

```elixir
# Copy (same-location)
{:ok, _} = GcpGcs.copy_object("src-bucket", "a.txt", "dst-bucket", "a-copy.txt")

# Compose (concatenate up to 32 objects in one bucket)
{:ok, _} = GcpGcs.compose_object("my-bucket", "combined.log", ["part-1", "part-2", "part-3"])

# Rewrite (large / cross-location / storage-class change — follows rewrite tokens)
{:ok, _} = GcpGcs.rewrite_object("src", "big.bin", "dst", "big.bin")

# Move/rename (buckets with hierarchical namespace)
{:ok, _} = GcpGcs.move_object("my-bucket", "old/name.txt", "new/name.txt")
```

## Error handling

```elixir
case GcpGcs.get_object("my-bucket", "missing.txt") do
  {:ok, object} ->
    object

  {:error, %GcpGcs.Error{code: :not_found}} ->
    :missing

  {:error, %GcpGcs.Error{code: :unauthenticated}} ->
    {:error, :auth}

  {:error, %GcpGcs.Error{} = err} ->
    raise "GCS error: #{err}"
end
```

`code` is a stable atom mapped from the HTTP status: `:not_found`,
`:already_exists`, `:permission_denied`, `:unauthenticated`,
`:invalid_argument`, `:failed_precondition`, `:resource_exhausted`,
`:unavailable`, `:validation_error`, `:connection_error`, … The original
decoded body / exception is preserved in `details`.

## Configuration

### Production

No configuration required — requests go to `storage.googleapis.com`.

```elixir
# Optional: authenticate through a Goth instance instead of the gcloud CLI
config :gcp_gcs, :goth, MyApp.Goth
```

```elixir
# Optional: tune the Finch pool
config :gcp_gcs, :finch, pool_size: 50, pool_count: 1

# Optional: default request timeout (ms)
config :gcp_gcs, :default_timeout, 30_000
```

### Development / test (emulator)

```elixir
config :gcp_gcs, :emulator,
  scheme: "http",
  host: "localhost",
  port: 4443
```

`STORAGE_EMULATOR_HOST` (used by Google's own client libraries) is also
honored. When an emulator is configured, authentication is skipped.

## Authentication

`GcpGcs.Auth` obtains OAuth2 access tokens, caching them in ETS:

1. **Goth** — when `config :gcp_gcs, :goth, MyApp.Goth` is set
2. **gcloud CLI** — `gcloud auth application-default print-access-token`

Using Goth:

```elixir
credentials = "GOOGLE_APPLICATION_CREDENTIALS_JSON" |> System.fetch_env!() |> JSON.decode!()

children = [
  {Goth,
   name: MyApp.Goth,
   source:
     {:service_account, credentials,
      scopes: ["https://www.googleapis.com/auth/devstorage.read_write"]}}
]
```

Call `GcpGcs.clear_auth_cache/0` to force a token refresh after rotating
credentials.

## Telemetry

```elixir
:telemetry.attach(
  "gcs-logger",
  [:gcp_gcs, :request, :stop],
  fn _event, %{duration: duration}, %{operation: op, result: result}, _config ->
    ms = System.convert_time_unit(duration, :native, :millisecond)
    require Logger
    Logger.info("gcs #{op} -> #{inspect(result)} in #{ms}ms")
  end,
  nil
)
```

## Testing

Unit tests run with no external services:

```bash
mix test
```

Integration tests run against a local emulator:

```bash
docker-compose up -d
mix test --include integration
docker-compose down
```

## Why the JSON API (and not gRPC)?

Cloud Storage is a blob store: the dominant work is transferring object bytes,
which maps naturally onto HTTP. Downloads stream as a response body and
uploads use the documented resumable protocol — both with constant memory.
The JSON API is the canonical, fully-featured Storage surface, and building on
Finch keeps the dependency footprint small.

## License

MIT — see [LICENSE](https://github.com/nyo16/gcp_gcs/blob/main/LICENSE).

## Links

- [Hex package](https://hex.pm/packages/gcp_gcs)
- [Documentation](https://hexdocs.pm/gcp_gcs)
- [Google Cloud Storage JSON API](https://cloud.google.com/storage/docs/json_api)
- [fake-gcs-server](https://github.com/fsouza/fake-gcs-server)

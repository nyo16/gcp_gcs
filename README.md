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
    {:gcp_gcs, "~> 0.3.0"},
    {:goth, "~> 1.4"}  # optional, service-account auth
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

# ...or every object, fetched lazily page by page (raises GcpGcs.Error on failure)
"my-bucket" |> GcpGcs.stream_objects!(page_size: 1000) |> Stream.map(& &1["name"]) |> Enum.take(5)
```

Every call returns `{:ok, result}` / `:ok`, or `{:error, %GcpGcs.Error{}}`; only
the lazy `stream_objects!/2` and `stream_buckets!/2` raise. Resources are
decoded JSON — plain maps with string keys; list results are atom-keyed
wrappers (`%{items: ..., next_page_token: ...}`) around them. Unknown options
are rejected with `:validation_error`.

## Uploads

```elixir
# Simple (in-memory) upload
{:ok, _} = GcpGcs.put_object("my-bucket", "notes.txt", "some text")

# Resumable upload of a local file, in 8 MiB chunks read from disk
{:ok, _} = GcpGcs.upload_file("my-bucket", "video.mp4", "/path/to/video.mp4")

# Resumable upload from any enumerable of binaries
chunks = Stream.repeatedly(fn -> :crypto.strong_rand_bytes(1_000_000) end) |> Stream.take(10)
{:ok, _} = GcpGcs.upload_stream("my-bucket", "random.bin", chunks)

# In-memory data with object metadata (goes through a resumable session)
{:ok, _} = GcpGcs.put_object("my-bucket", "a.json", "{}", attrs: %{"cacheControl" => "no-cache"})

# Let the library pick the strategy
{:ok, _} = GcpGcs.upload("my-bucket", "a.txt", "inline data")
{:ok, _} = GcpGcs.upload("my-bucket", "b.bin", {:file, "/path/to/b.bin"})
```

Content type is guessed from the object's extension for `upload_file/4`; pass
`content_type:` to override. Resumable chunk size defaults to 8 MiB and can be
tuned with `chunk_size:` (rounded to a 256 KiB multiple).

Resumable uploads survive transient failures (5xx, 429, dropped connections):
they ask the session how much it persisted and resume from there.
`upload_file/4` can resume from any offset; `upload_stream/4` holds at most
one chunk and returns `:data_loss` if the server lost more. The final request
carries an MD5 `X-Goog-Hash` of the whole object, so GCS rejects corrupted
uploads (`checksum: false` to disable). After a session exists, errors carry
`details: %{session_uri: uri, cause: ...}` for manual resumption.

### Low-level resumable control

```elixir
{:ok, session} = GcpGcs.start_resumable_upload("my-bucket", "big.bin", content_type: "application/octet-stream")
{:resume, 262144} = GcpGcs.upload_chunk(session, chunk1, offset: 0, total: nil)
{:ok, _object}    = GcpGcs.upload_chunk(session, last_chunk, offset: 262144, total: 300000)
```

`{:resume, persisted}` reports how many bytes the session holds; if it is less
than what you sent, resend from `persisted`.

**Session URIs are bearer capabilities.** Anyone holding one can write the
object until the session expires (one week), with no further credentials, so:

- never log session URIs or put them in error reports;
- hand a session URI only to the user it was created for (e.g. the browser
  session that will upload), never share it across users;
- `upload_chunk/3` only accepts session URIs on the configured endpoint's
  upload API and sends no `authorization` header with them.

For browser uploads, take `:origin` only from an allow-list of your own
origins, never from the request's `Origin` header as-is: GCS CORS-enables the
session for exactly that origin.

## Downloads

```elixir
# Whole object into memory
{:ok, bytes} = GcpGcs.download("my-bucket", "report.pdf")

# Stream straight to disk (constant memory)
:ok = GcpGcs.download_to_file("my-bucket", "report.pdf", "/tmp/report.pdf")

# Fold the body through your own reducer; return {:halt, acc} to stop early
{:ok, byte_count} =
  GcpGcs.download_stream("my-bucket", "big.bin", 0, fn
    {:data, chunk}, n -> n + byte_size(chunk)
    _other, n -> n
  end)

# Byte ranges (inclusive): a 206 Partial Content is a success
{:ok, first_kib} = GcpGcs.download("my-bucket", "big.bin", range: 0..1023)
```

`download_to_file/4` writes to `path <> ".part"` and renames it into place
when complete, so a partial file never appears at `path`.

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

`code` is a stable atom (`t:GcpGcs.Error.code/0` lists them all). HTTP
statuses map to `:not_found`, `:already_exists`, `:permission_denied`,
`:unauthenticated`, `:invalid_argument`, `:failed_precondition`,
`:resource_exhausted`, `:unavailable`, …; client-side failures are
`:validation_error` (nothing was sent), `:connection_error`,
`:protocol_error` (the server broke the resumable/rewrite protocol),
`:data_loss` and `:io_error`. The original decoded body / exception is
preserved in `details`.

## Configuration

### Production

No configuration required — requests go to `storage.googleapis.com`.

```elixir
# Optional: authenticate through a Goth instance instead of the gcloud CLI
config :gcp_gcs, :goth, MyApp.Goth
```

```elixir
# Optional: tune the Finch pool (defaults: 10 connections per shard,
# one shard per scheduler)
config :gcp_gcs, :finch, pool_size: 10, pool_count: System.schedulers_online()

# Optional: HTTP/2 (opt-in; default HTTP/1)
config :gcp_gcs, :finch, protocols: [:http2]

# Optional: bring your own Finch instance
config :gcp_gcs, :start_finch, false
config :gcp_gcs, :finch_name, MyApp.Finch

# Optional: default request timeout (ms)
config :gcp_gcs, :default_timeout, 30_000

# Optional: max wait for a pooled connection (ms); exceeding it returns
# {:error, %GcpGcs.Error{code: :resource_exhausted}}
config :gcp_gcs, :pool_timeout, 5_000

# Optional: retries for idempotent requests (and resumable-upload recovery)
config :gcp_gcs, :retry, max_attempts: 4, base_delay: 200, max_delay: 10_000
```

**Pool sizing:** every in-flight upload or download holds one connection for
its whole duration, so `pool_size * pool_count` must cover your peak number of
concurrent transfers plus metadata calls; otherwise callers wait up to
`:pool_timeout` and then get `:resource_exhausted`. HTTP/2 multiplexes
requests over fewer connections; it relies on the mint ≥ 1.11 / hpax ≥ 1.1
fixes pulled in by finch ≥ 0.24.

Per call, every function accepts `:timeout`, `:pool_timeout`, `:retry`
(`false` or overrides), `:finch`, `:goth` and `:base_url` (a per-call
endpoint, which keeps authentication on). Metadata calls also accept
`:request_timeout`, an overall deadline.

### Development / test (emulator)

```elixir
config :gcp_gcs, :emulator,
  scheme: "http",
  host: "localhost",
  port: 4443
```

`STORAGE_EMULATOR_HOST` (used by Google's own client libraries) is also
honored; set `config :gcp_gcs, :emulator_env, false` to ignore it (e.g. in
production releases). When an emulator is configured, authentication is
skipped, and an emulator on a non-loopback host is logged as an error at boot.
The endpoint is resolved once at application start.

## Authentication

`GcpGcs.Auth` obtains OAuth2 access tokens:

1. **Goth** — a per-call `goth:` option, or `config :gcp_gcs, :goth, MyApp.Goth`
   (Goth caches and refreshes its own tokens)
2. **gcloud CLI** — `gcloud auth application-default print-access-token`, for
   development. Tokens are cached until shortly before their real expiry and
   fetched once under concurrent demand. Disable with
   `config :gcp_gcs, :gcloud_fallback, false`; pin the binary with
   `config :gcp_gcs, :gcloud_path, "/path/to/gcloud"`.

A `401` response clears the cached token and retries the request once.

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

Each public function emits one `[:gcp_gcs, :request, _]` span covering all of
its HTTP calls (retries, chunks, rewrite steps); `:operation` names the
function (`:put_object`, `:upload_file`, `:upload_stream`, `:download`,
`:download_to_file`, `:download_stream`, `:list_objects`, …). Metadata always
has `:bucket` and `:object` (the destination for copy/rewrite/move);
`upload_file/4` and `download_to_file/4` also carry local file paths
(`:source`/`:destination`). Treat telemetry metadata as potentially sensitive
before exporting it.

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

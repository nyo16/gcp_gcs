# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.1] - 2026-10-21

### Documentation
- Corrected the 0.3.0 release notes: the release date, and four behaviour
  changes that were missing: gcloud runs are killed after `:gcloud_timeout`,
  a 401 without credentials (emulator mode) is not retried,
  `clear_auth_cache/0` semantics, and the `upload_stream/4` mailbox
  constraint with `checksum: true`. No code changes.

## [0.3.0] - 2026-10-21

### Breaking
- **Unknown options are rejected.** Every public function validates its
  options (`Keyword.validate/2`) against its documented keys plus the
  transport options; anything else returns `{:error, %GcpGcs.Error{code:
  :validation_error, details: {:unknown_options, keys}}}` instead of being
  silently ignored (e.g. `list_objects(b, max_results: 10)`).
- **`download_stream` argument order** is now
  `download_stream(bucket, object, acc, reducer, opts \\ [])` (also
  `GcpGcs.Download.stream/5`). The old `(bucket, object, opts, acc, reducer)`
  order still works for this release and emits a deprecation warning.
- **Telemetry operation names**: uploads and downloads report
  `:put_object`, `:upload_file`, `:upload_stream`, `:download`,
  `:download_to_file` and `:download_stream` instead of `:upload` /
  `:download`. Metadata always includes `:bucket` and `:object`; for
  copy/rewrite/move they are the destination (source in `:src_bucket` /
  `:src_object`, replacing `:dst_bucket` / `:dst_object`). New spans for
  `start_resumable_upload/3` and `upload_chunk/3`. The event name
  `[:gcp_gcs, :request]` is unchanged and documented as operation-scoped.
- **Auth telemetry**: `[:gcp_gcs, :auth, _]` is emitted only when the gcloud
  fallback runs `gcloud` (cache miss or refresh). Goth token reads no longer
  emit it on every request; use Goth's own telemetry for its refreshes.
- **Error vocabulary**: client-side protocol violations (missing `Location`,
  malformed `Range`, no progress, unexpected rewrite response) use the new
  code `:protocol_error` instead of `:internal`, which now only means HTTP
  500. `t:GcpGcs.Error.code/0` enumerates every code.
- **Public surface**: GcpGcs.Client and GcpGcs.Application are internal
  (`@moduledoc false`); `GcpGcs.Config` documents config keys only;
  `GcpGcs.Auth`'s public function is `clear_cache/0` (use
  `GcpGcs.clear_auth_cache/0`); GcpGcs.Telemetry's `span/3` and `auth_span/2`
  are internal.
- **List results**: `list_buckets/2` pages no longer contain `prefixes`
  (only object listings have them).
- **Stricter validation**: bucket names with `..`, `.-` or `-.` (or a
  trailing newline, which the old pattern let through), object names
  with C0 control characters or invalid UTF-8, and `:origin` /
  `:content_type` values that are not printable ASCII are rejected with
  `:validation_error` before any request (previously a GCS 400 or a Mint
  `:connection_error`).
- **Retries are on by default** for idempotent requests (see Added). Pass
  `retry: false` or `config :gcp_gcs, :retry, max_attempts: 1` for the old
  behaviour.
- **Default pool**: one shard of 50 connections (`pool_size: 50,
  pool_count: 1`; was one shard of 25). A single pool queues later than
  several randomly chosen shards of the same total size.
- **Goth tokens are no longer cached in ETS** — Goth caches them itself.
- After a resumable session exists, an error's `details` is
  `%{session_uri: uri, cause: original_details}`.
- **gcloud runs are killed after `:gcloud_timeout`** (default 30 s), with
  their child processes, and the request fails with `:unauthenticated`
  (`details: :gcloud_timeout`). Previously a caller waited up to 60 s and the
  gcloud process kept running.
- **A 401 without credentials is not retried**: when no `authorization`
  header was sent (emulator mode), a 401 is returned as is instead of being
  retried once.

### Added
- Per-call `:goth`, `:finch` and `:base_url` options (a per-call base URL
  keeps authentication on); `config :gcp_gcs, :finch_name` and
  `config :gcp_gcs, :start_finch, false` to use your own Finch instance.
- Bounded retries with exponential backoff and full jitter for idempotent
  requests on 408/429/5xx and dropped connections, honouring `Retry-After`
  (`config :gcp_gcs, :retry`, per-call `:retry`). A 401 to an authenticated
  request is retried once with a fresh token; only the rejected gcloud token
  is replaced, so concurrent 401s cause a single refetch.
- Resumable uploads recover from transient failures by querying the session
  and resuming from the persisted offset; `upload_file/4` now uploads in
  chunks read with `pread` (8 MiB by default) and can resume from any offset.
- `X-Goog-Hash` MD5 of the whole object on the final resumable request
  (`checksum: false` disables it).
- `GcpGcs.stream_objects!/2` and `GcpGcs.stream_buckets!/2`: lazy pagination
  (the only raising functions); `GcpGcs.Error` is now an exception.
- `:fields` on `list_objects/2` and `list_buckets/2`.
- `:range` on `download/3`, `download_to_file/4` and `download_stream`;
  download reducers may return `{:halt, acc}` to stop early.
- `put_object/4` with `:attrs`, and empty `upload_file/4` with `:attrs` or
  `:origin`, go through a resumable session so the metadata is applied
  (previously dropped). `:predefined_acl` documented on
  `upload_file/4`/`upload_stream/4`.
- `config :gcp_gcs, :emulator_env, false` ignores `STORAGE_EMULATOR_HOST`; a
  non-loopback emulator host is logged as an error at boot.
- gcloud auth: tokens are cached until shortly before their real expiry
  (refreshed at 80% of the TTL), fetched once under concurrent demand, and
  failures are cached for 5 s; `config :gcp_gcs, :gcloud_path` and
  `config :gcp_gcs, :gcloud_fallback, false`. The fetch runs outside the
  cache process, so waiting callers don't queue in its mailbox, and
  `clear_auth_cache/0` returns at once (callers after it fetch anew, even
  while an older fetch is still running); `config :gcp_gcs, :gcloud_timeout`
  (default 30 s) kills a gcloud run that hangs, with its child processes,
  also when the application stops. A bare `:gcloud_path` is looked up on
  `PATH` only.
- `:request_timeout` (overall deadline for metadata calls), opt-in HTTP/2
  via `config :gcp_gcs, :finch, protocols: [:http2]`, `@spec`s on every
  `GcpGcs` function.

### Changed
- The endpoint (emulator or production) is resolved once at application
  start. Finch's `:default` pool uses the same strict TLS settings.
- HTTPS pools no longer embed the decoded OS CA store in their TLS options;
  Mint loads it at connect time. Finch copied those options with the
  connection on every pool checkout (~0.5 ms per request). The store is still
  loaded once at start, so a host without one (and without `castore`) fails
  at boot.
- Faster transfers: the resumable-upload MD5 is computed in a per-upload
  process while chunks are sent (~1.5× client-side throughput with
  `checksum: true`); `upload_stream/4` no longer copies chunk-aligned
  elements; `download_to_file/4` writes through a raw, buffered file (~40%
  less CPU).
- Non-2xx download bodies are buffered up to 64 KiB for the error.
- The token cache table is `:protected`; only its owner process writes it.
- `clear_auth_cache/0` returns at once, even while a gcloud run is in
  progress; requests after it fetch a new token, and the run that was in
  progress answers its own callers but is not cached.
- With `checksum: true`, `upload_stream/4` gets MD5 replies from a helper
  process in the caller's mailbox: the enumerable (consumed in the caller)
  must not consume messages it doesn't own, e.g. with a catch-all `receive`.

### Changed (development)
- The test suite's local HTTP server is now `GcpGcs.FakeServer` (Bandit plus a
  dispatching Plug) instead of the unmaintained Bypass, which removes
  plug_cowboy/cowboy/cowlib/ranch from the test dependencies (and with them
  cowlib CVE-2026-43966).
- Dialyzer runs cleanly under `MIX_ENV=test` (CI): `:ex_unit` is in the PLT.

### Upgrading from 0.2.x

1. Run your test suite and look for `:validation_error` with
   `details: {:unknown_options, keys}` — fix or drop those options.
2. Reorder `GcpGcs.download_stream(b, o, opts, acc, reducer)` calls to
   `GcpGcs.download_stream(b, o, acc, reducer, opts)` (the old order warns).
3. Telemetry handlers matching `operation: :upload` / `:download` should
   match the new names; handlers reading `:dst_bucket`/`:dst_object` should
   read `:bucket`/`:object`.
4. Code matching `%GcpGcs.Error{code: :internal}` for resumable/rewrite
   failures should match `:protocol_error`.
5. Replace direct calls to GcpGcs.Client, GcpGcs.Auth's `get_token` /
   `request_headers`, or GcpGcs.Config functions; they are internal now.
6. The pool now has 50 connections in one shard (was 25). To keep the old
   size, set `config :gcp_gcs, :finch, pool_size: 25`.
7. If writes must never be retried at all, set
   `config :gcp_gcs, :retry, max_attempts: 1` (non-idempotent requests are
   never retried by default anyway).
8. If gcloud can take longer than 30 s (e.g. a slow re-authentication), set
   `config :gcp_gcs, :gcloud_timeout, ms`.

## [0.2.2] - 2026-10-20

### Security
- **Resumable session URIs are validated and no longer receive the bearer
  token** (S-H1). `upload_chunk/3`, `upload_stream/4` and `upload_file/4` only
  send to session URIs whose scheme, host and port match the configured
  endpoint and whose path is under `/upload/storage/v1/`; anything else
  returns `:validation_error` without a request. Session PUTs are sent without
  an `authorization` header — the session URI is itself the credential —
  so a caller-supplied or server-returned URI can no longer exfiltrate the
  OAuth token.
- **gcloud token hygiene** (S-H2). The gcloud CLI token is taken from the
  last line of output that consists only of visible ASCII (stderr warnings
  merged into the output are no longer glued into the `authorization` header);
  output without such a line is an `:unauthenticated` error and is not
  cached. A transport error for an invalid header value now reports only the
  header name, never its value.
- Raised the Finch floor to `~> 0.24` and updated the lock: mint 1.11.0 and
  hpax 1.1.0 fix the advisories open against mint 1.9.0 (9) and hpax 1.0.3
  (1). Test-only cowlib 2.21.0 (via bypass) still carries
  CVE-2026-43966 / GHSA-w4f7-4cxr-rv3c, which has no fixed release.

### Fixed
- **Resumable uploads no longer lose data on partial persistence** (P-1). A
  `308` whose `Range` shows fewer bytes than were sent now resends from the
  persisted offset (also on the final request); a `308` without `Range`
  means nothing was persisted. If the server reports fewer bytes than the
  stream can still replay, the upload fails with `:data_loss` instead of
  silently skipping bytes; repeated no-progress responses stop with an error
  instead of looping. `upload_chunk/3` returns `{:resume, persisted}` as
  reported by the server.
- Functions return `{:error, %GcpGcs.Error{code: :validation_error}}` instead
  of raising for non-binary `upload_chunk/3` data, a missing/negative
  `:offset`, non-map `attrs` to `update_bucket/3`/`update_object/4`, a reducer
  that is not arity 2, and `upload/4` sources that are not a binary,
  `{:file, path}` or an `Enumerable` (checked before a session is opened).
- An exhausted connection pool returns `{:error, %GcpGcs.Error{code:
  :resource_exhausted}}` instead of raising; the wait is set by the new
  `config :gcp_gcs, :pool_timeout` (default 5 000 ms).
- `download_to_file/4` writes to `path <> ".part"` and renames it into place
  on success, so **a partial file never appears at `path`** (visible
  behaviour change). Write errors return `:io_error` instead of crashing, and
  the `.part` file is removed on every failure.
- `rewrite_object/5` returns an error for an unexpected response shape
  instead of `{:ok, response}`.
- `goth` is documented as an optional dependency and compiling without it
  emits no warnings.

### Changed (development)
- CI runs Elixir 1.18/OTP 27, 1.19/OTP 28 and 1.20/OTP 29, checks coverage
  (`mix coveralls`), audits dependencies (`mix deps.audit`, `mix hex.audit`),
  compiles without optional deps, pins every action to a commit SHA and the
  emulator image to a digest, and publishes from a protected `hex`
  environment. Dependabot is enabled.

## [0.2.1] - 2026-07-15

### Added
- **Resumable uploads** — `start_resumable_upload/3` accepts an `:origin`
  option, forwarded as the `Origin` header on the session-initiation POST.
  Required for browser-based resumable uploads (server initiates the session,
  browser PUTs the bytes): GCS only returns CORS headers on requests to the
  session URI when the session was initiated with an `Origin` — the bucket's
  CORS configuration alone does not apply to session URIs. Opt-in and
  backwards-compatible; mirrors `origin` in Google's official clients
  (google-cloud-node's `createResumableUpload`, google-cloud-python's
  `Blob.create_resumable_upload_session`). The `fake-gcs-server` emulator does
  not enforce CORS, so this is covered by `Bypass`-based tests asserting the
  exact headers sent.

## [0.2.0] - 2026-07-07

### Changed
- Use Elixir's built-in `JSON` module (Elixir 1.18+) for encoding/decoding
  instead of `Jason`, and drop the `jason` dependency.

### Fixed
- **Resumable uploads** — send an explicit `Content-Length` on both resumable
  requests so real GCS no longer rejects them with `411 Length Required`: `0`
  on the bodyless session-initiation POST, and the known file size on the
  session PUT (which also stops Mint from falling back to
  `transfer-encoding: chunked` for the stream body). The `fake-gcs-server`
  emulator does not enforce this, so the failure only appeared against the
  live API. Regression covered by a `Bypass`-based test that asserts the exact
  headers sent.

## [0.1.0] - 2026-06-25

Initial release.

### Added
- **Buckets** — `create_bucket/3`, `get_bucket/2`, `list_buckets/2`,
  `delete_bucket/2`, `update_bucket/3`
- **Object metadata** — `get_object/3`, `list_objects/2` (with `prefix`/`delimiter`
  paging), `delete_object/3`, `update_object/4`, `copy_object/5`,
  `compose_object/4`, `rewrite_object/5` (token-following), `move_object/4`
- **Uploads** — `put_object/4` (simple), `upload_file/4` and `upload_stream/4`
  (resumable, constant memory), `upload/4` (auto-selects strategy), plus the
  low-level `start_resumable_upload/3` and `upload_chunk/3` primitives
- **Downloads** — `download/3` (buffered), `download_to_file/4` and
  `download_stream/5` (streamed, constant memory)
- **`GcpGcs.Error`** — structured error type with `code`, `message`, `details`,
  and HTTP `status`; HTTP statuses mapped to canonical atoms
- **`GcpGcs.Auth`** — OAuth2 access tokens via Goth or the gcloud CLI, with
  ETS-backed caching; auth is skipped automatically in emulator mode
- **`GcpGcs.Telemetry`** — `[:gcp_gcs, :request, _]` and `[:gcp_gcs, :auth, _]`
  span events
- **`GcpGcs.Config`** — production/emulator endpoint resolution, including the
  `STORAGE_EMULATOR_HOST` environment variable, and Finch pool configuration
- Input validation for bucket names, object names, project IDs, and source
  object lists, returning `{:error, %GcpGcs.Error{code: :validation_error}}`
- `docker-compose.yml` for a local `fake-gcs-server` emulator and an
  integration test suite (run with `mix test --include integration`)

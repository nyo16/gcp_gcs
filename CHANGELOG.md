# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

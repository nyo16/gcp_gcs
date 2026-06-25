# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

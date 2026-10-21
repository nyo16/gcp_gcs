import Config

config :logger, level: :warning

# No emulator here: tests that talk HTTP point the library at a Bypass server
# or the fake-gcs-server emulator in their own `setup` (see
# `GcpGcs.EnvHelper`), so nothing leaks an emulator default into other tests.

# Retries stay on (they are part of the behaviour under test) but without
# backoff delays, so error-path tests don't sleep.
config :gcp_gcs, :retry, base_delay: 0, max_delay: 0

import Config

config :logger, level: :warning

# No emulator here: tests that talk HTTP point the library at a Bypass server
# or the fake-gcs-server emulator in their own `setup` (see
# `GcpGcs.EnvHelper`), so nothing leaks an emulator default into other tests.

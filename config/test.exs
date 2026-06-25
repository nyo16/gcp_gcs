import Config

config :logger, level: :warning

# Integration tests run against a local fake-gcs-server emulator.
# Start it with `docker-compose up -d` (see docker-compose.yml).
config :gcp_gcs, :emulator,
  scheme: "http",
  host: "localhost",
  port: 4443

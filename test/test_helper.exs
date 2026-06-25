# Integration tests talk to a real emulator and are excluded by default.
# Run them with `mix test --include integration` after `docker-compose up -d`.
ExUnit.start(exclude: [:integration])

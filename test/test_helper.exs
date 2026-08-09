# `:postgres`/`:timescaledb`-tagged tests (Scry.Test.Core.Conn.postgres/1
# and .timescaledb/1, and their own tagged test files) need a real,
# externally-running Postgres/TimescaleDB -- excluded by default so
# `mix test`/`mix precommit` stay zero-external-setup for anyone who
# merely depends on this package for the other three backends. Run
# `docker compose up -d` then `mix test.postgres`/`mix test.timescaledb`
# to include them.
ExUnit.start(exclude: [:postgres, :timescaledb])

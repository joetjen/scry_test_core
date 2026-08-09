# `:postgres`-tagged tests (Scry.Test.Core.Conn.postgres/1 and its own
# postgres_parity_test.exs/postgres_conn_test.exs) need a real,
# externally-running Postgres -- excluded by default so `mix test`/
# `mix precommit` stay zero-external-setup for anyone who merely
# depends on this package for the other three backends. Run `docker
# compose up -d` then `mix test.postgres` to include them.
ExUnit.start(exclude: [:postgres])

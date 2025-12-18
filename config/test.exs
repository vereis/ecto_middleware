import Config

alias EctoMiddleware.Test.Repo

config :ecto_middleware, Repo,
  database: Path.expand("../test/test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  show_sensitive_data_on_connection_error: true

config :ecto_middleware, ecto_repos: [Repo]

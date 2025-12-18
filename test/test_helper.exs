alias Ecto.Adapters.SQL.Sandbox
alias EctoMiddleware.Test.Repo

{:ok, _} = Repo.start_link()

Sandbox.mode(Repo, {:shared, self()})

path = Application.app_dir(:ecto_middleware, "priv/test_repo/migrations")

if File.exists?(path) do
  Ecto.Migrator.run(Repo, path, :up, all: true)
end

Sandbox.mode(Repo, :manual)

ExUnit.start()

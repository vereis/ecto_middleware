defmodule EctoMiddleware.Test.Repo.Migrations.CreateTestTables do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:users) do
      add(:name, :string, null: false)
      add(:email, :string, null: false)
      add(:age, :integer)

      timestamps()
    end

    create table(:posts) do
      add(:title, :string, null: false)
      add(:body, :text)
      add(:published, :boolean, default: false)
      add(:user_id, references(:users, on_delete: :delete_all))

      timestamps()
    end

    create(unique_index(:users, [:email]))
  end
end

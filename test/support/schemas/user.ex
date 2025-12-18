if Mix.env() == :test do
  defmodule EctoMiddleware.Test.Schemas.User do
    @moduledoc false
    use Ecto.Schema

    import Ecto.Changeset

    schema "users" do
      field(:name, :string)
      field(:email, :string)
      field(:age, :integer)

      timestamps()
    end

    def changeset(user, attrs) do
      user
      |> cast(attrs, [:name, :email, :age])
      |> validate_required([:name, :email])
      |> validate_format(:email, ~r/@/)
    end
  end
end

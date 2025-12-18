if Mix.env() == :test do
  defmodule EctoMiddleware.Test.Schemas.Post do
    @moduledoc false
    use Ecto.Schema

    schema "posts" do
      field(:title, :string)
      field(:body, :string)
      field(:published, :boolean, default: false)

      timestamps()
    end
  end
end

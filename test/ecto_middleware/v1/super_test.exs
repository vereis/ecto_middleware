defmodule EctoMiddleware.V1.SuperTest do
  @moduledoc """
  Tests for EctoMiddleware.Super marker module.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias EctoMiddleware.Super
  alias EctoMiddleware.Test.Repo

  describe "middleware/2" do
    test "returns resource unchanged" do
      resource = %{id: 1, name: "test"}
      resolution = %EctoMiddleware.Resolution{}

      result = Super.middleware(resource, resolution)

      assert result == resource
    end

    test "works with changesets" do
      changeset = %Ecto.Changeset{data: %{}, changes: %{name: "test"}}
      resolution = %EctoMiddleware.Resolution{}

      result = Super.middleware(changeset, resolution)

      assert result == changeset
    end

    test "works with nil" do
      resolution = %EctoMiddleware.Resolution{}

      result = Super.middleware(nil, resolution)

      assert result == nil
    end
  end

  describe "integration: Super marker" do
    alias EctoMiddleware.Test.Schemas.User

    setup do
      :ok = Sandbox.checkout(Repo)
      on_exit(fn -> Repo.reset_middleware() end)
      :ok
    end

    test "splits middleware list into before/after" do
      defmodule BeforeMiddleware do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          Ecto.Changeset.put_change(changeset, :name, "Before")
        end
      end

      defmodule AfterMiddleware do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) do
          Map.put(user, :after_ran, true)
        end
      end

      Repo.set_middleware([BeforeMiddleware, Super, AfterMiddleware])

      changeset = User.changeset(%User{}, %{name: "Original", email: "super@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.name == "Before"
      assert user.after_ran == true
    end

    test "multiple before middlewares execute in order" do
      defmodule Before1 do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          Ecto.Changeset.put_change(changeset, :name, "Step1")
        end
      end

      defmodule Before2 do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          name = Ecto.Changeset.get_field(changeset, :name)
          Ecto.Changeset.put_change(changeset, :name, "#{name}-Step2")
        end
      end

      Repo.set_middleware([Before1, Before2, Super])

      changeset = User.changeset(%User{}, %{name: "Original", email: "multi@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.name == "Step1-Step2"
    end

    test "multiple after middlewares execute in order" do
      defmodule After1 do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) do
          Map.put(user, :step1, true)
        end
      end

      defmodule After2 do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) do
          Map.put(user, :step2, true)
        end
      end

      Repo.set_middleware([Super, After1, After2])

      changeset = User.changeset(%User{}, %{name: "Test", email: "multi_after@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.step1 == true
      assert user.step2 == true
    end
  end
end

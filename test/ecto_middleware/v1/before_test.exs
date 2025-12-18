defmodule EctoMiddleware.V1.BeforeTest do
  @moduledoc """
  Tests for EctoMiddleware.V1.Before wrapper.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias EctoMiddleware.Engine
  alias EctoMiddleware.Resolution
  alias EctoMiddleware.Test.Repo
  alias EctoMiddleware.V1.Before

  defmodule TestV1Middleware do
    @moduledoc false
    @behaviour EctoMiddleware

    def middleware(resource, _resolution) do
      Map.put(resource, :v1_transformed, true)
    end
  end

  defp build_resolution(v1_middleware) do
    %Resolution{
      repo: __MODULE__,
      action: :test,
      args: [%{}],
      middleware: [],
      entity: %{},
      private: %{
        __super__: fn res, _resolution -> res end,
        __v1_middleware__: v1_middleware,
        __pipeline_id__: make_ref()
      }
    }
  end

  describe "process/2" do
    test "calls v1 middleware's middleware/2 before yield" do
      resolution = build_resolution(TestV1Middleware)

      {:cont, result, _} = Before.process(%{input: true}, resolution)

      assert result == %{input: true, v1_transformed: true}
    end

    test "passes transformed resource to yield" do
      defmodule TransformChecker do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(resource, _resolution) do
          Map.put(resource, :step1, true)
        end
      end

      super_fn = fn resource, _resolution ->
        send(self(), {:super_received, resource})
        resource
      end

      resolution = %Resolution{
        repo: __MODULE__,
        action: :test,
        args: [%{}],
        middleware: [],
        entity: %{},
        private: %{
          __super__: super_fn,
          __v1_middleware__: TransformChecker,
          __pipeline_id__: make_ref()
        }
      }

      Before.process(%{input: true}, resolution)

      assert_received {:super_received, %{input: true, step1: true}}
    end

    test "returns {:cont, result, resolution}" do
      resolution = build_resolution(TestV1Middleware)

      result = Before.process(%{}, resolution)

      assert {:cont, _, %Resolution{}} = result
    end
  end

  describe "integration: v1 before middleware" do
    alias EctoMiddleware.Test.Schemas.User

    setup do
      :ok = Sandbox.checkout(Repo)
      on_exit(fn -> Repo.reset_middleware() end)
      :ok
    end

    test "transforms changeset before insert" do
      defmodule V1InsertTransformer do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          Ecto.Changeset.put_change(changeset, :name, "V1 Modified")
        end
      end

      Repo.set_middleware([V1InsertTransformer, EctoMiddleware.Super])

      changeset = User.changeset(%User{}, %{name: "Original", email: "v1before@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.name == "V1 Modified"
    end

    test "transforms changeset before update" do
      {:ok, user} = Repo.insert(%User{name: "Original", email: "v1beforeupdate@example.com"})

      defmodule V1UpdateTransformer do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          Ecto.Changeset.put_change(changeset, :name, "V1 Updated")
        end
      end

      Repo.set_middleware([V1UpdateTransformer, EctoMiddleware.Super])

      changeset = User.changeset(user, %{name: "Should Be Overwritten"})
      {:ok, updated} = Repo.update(changeset)

      assert updated.name == "V1 Updated"
    end

    test "can access resolution in v1 middleware" do
      defmodule V1ResolutionAccess do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, resolution) do
          # V1 middleware can access resolution
          assert resolution.action == :insert
          assert resolution.repo == Repo
          changeset
        end
      end

      Repo.set_middleware([V1ResolutionAccess, EctoMiddleware.Super])

      changeset = User.changeset(%User{}, %{name: "Test", email: "v1res@example.com"})
      {:ok, _user} = Repo.insert(changeset)
    end

    test "multiple v1 before middlewares chain correctly" do
      defmodule V1Step1 do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          Ecto.Changeset.put_change(changeset, :name, "Step1")
        end
      end

      defmodule V1Step2 do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          name = Ecto.Changeset.get_field(changeset, :name)
          Ecto.Changeset.put_change(changeset, :name, "#{name}+Step2")
        end
      end

      Repo.set_middleware([V1Step1, V1Step2, EctoMiddleware.Super])

      changeset = User.changeset(%User{}, %{name: "Original", email: "v1chain@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.name == "Step1+Step2"
    end
  end
end

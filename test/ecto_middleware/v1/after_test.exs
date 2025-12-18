defmodule EctoMiddleware.V1.AfterTest do
  @moduledoc """
  Tests for EctoMiddleware.V1.After wrapper.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Schema.Metadata
  alias EctoMiddleware.Resolution
  alias EctoMiddleware.Test.Repo
  alias EctoMiddleware.V1.After

  defmodule TestV1Middleware do
    @moduledoc false
    @behaviour EctoMiddleware

    def middleware(resource, _resolution) do
      Map.put(resource, :v1_enriched, true)
    end
  end

  defmodule MockSchema do
    @moduledoc false
    defstruct [:id, :name, :__meta__]
  end

  defp build_resolution(v1_middleware, super_fn) do
    %Resolution{
      repo: __MODULE__,
      action: :test,
      args: [%{}],
      middleware: [],
      entity: %{},
      private: %{
        __super__: super_fn,
        __v1_middleware__: v1_middleware,
        __pipeline_id__: make_ref()
      }
    }
  end

  describe "process/2" do
    test "calls yield first, then v1 middleware's middleware/2" do
      super_fn = fn resource, _resolution ->
        send(self(), {:super_called, resource})
        {:ok, %MockSchema{id: 1, name: "test", __meta__: %{__struct__: Metadata}}}
      end

      resolution = build_resolution(TestV1Middleware, super_fn)
      After.process(%{input: true}, resolution)

      assert_received {:super_called, %{input: true}}
    end

    test "transforms {:ok, value} inner value" do
      super_fn = fn _resource, _resolution ->
        {:ok, %MockSchema{id: 1, name: "test", __meta__: %{__struct__: Metadata}}}
      end

      resolution = build_resolution(TestV1Middleware, super_fn)
      {:cont, result, _} = After.process(%{}, resolution)

      assert {:ok, %{v1_enriched: true}} = result
    end

    test "passes through {:error, reason}" do
      super_fn = fn _resource, _resolution ->
        {:error, :failed}
      end

      resolution = build_resolution(TestV1Middleware, super_fn)
      {:cont, result, _} = After.process(%{}, resolution)

      assert {:error, :failed} = result
    end

    test "maps over list results" do
      super_fn = fn _resource, _resolution ->
        [
          %MockSchema{id: 1, name: "one", __meta__: %{__struct__: Metadata}},
          %MockSchema{id: 2, name: "two", __meta__: %{__struct__: Metadata}}
        ]
      end

      resolution = build_resolution(TestV1Middleware, super_fn)
      {:cont, result, _} = After.process(%{}, resolution)

      assert [%{v1_enriched: true}, %{v1_enriched: true}] = result
    end

    test "transforms bare struct" do
      super_fn = fn _resource, _resolution ->
        %MockSchema{id: 1, name: "test", __meta__: %{__struct__: Metadata}}
      end

      resolution = build_resolution(TestV1Middleware, super_fn)
      {:cont, result, _} = After.process(%{}, resolution)

      assert %{v1_enriched: true} = result
    end

    test "skips non-Ecto-schema values" do
      super_fn = fn _resource, _resolution ->
        {:ok, :not_a_schema}
      end

      resolution = build_resolution(TestV1Middleware, super_fn)
      {:cont, result, _} = After.process(%{}, resolution)

      # Non-schema values pass through unchanged
      assert {:ok, :not_a_schema} = result
    end

    test "skips when after_input is nil" do
      super_fn = fn _resource, _resolution ->
        nil
      end

      resolution = build_resolution(TestV1Middleware, super_fn)
      {:cont, result, _} = After.process(%{}, resolution)

      assert result == nil
    end
  end

  describe "integration: v1 after middleware" do
    alias EctoMiddleware.Test.Schemas.User

    setup do
      :ok = Sandbox.checkout(Repo)
      on_exit(fn -> Repo.reset_middleware() end)
      :ok
    end

    test "transforms struct after insert" do
      defmodule V1InsertEnricher do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) do
          Map.put(user, :v1_enriched, true)
        end
      end

      Repo.set_middleware([EctoMiddleware.Super, V1InsertEnricher])

      changeset = User.changeset(%User{}, %{name: "Test", email: "v1after@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.v1_enriched == true
    end

    test "transforms struct after get" do
      {:ok, inserted} = Repo.insert(%User{name: "Test", email: "v1afterget@example.com"})

      defmodule V1GetEnricher do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) when is_struct(user) do
          Map.put(user, :v1_enriched, true)
        end

        def middleware(other, _resolution), do: other
      end

      Repo.set_middleware([EctoMiddleware.Super, V1GetEnricher])

      user = Repo.get(User, inserted.id)

      assert user.v1_enriched == true
    end

    test "transforms each struct after all" do
      Repo.insert!(%User{name: "Test1", email: "v1afterall1@example.com"})
      Repo.insert!(%User{name: "Test2", email: "v1afterall2@example.com"})

      defmodule V1AllEnricher do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) when is_struct(user) do
          Map.put(user, :v1_enriched, true)
        end

        def middleware(other, _resolution), do: other
      end

      Repo.set_middleware([EctoMiddleware.Super, V1AllEnricher])

      users = Repo.all(User)

      assert Enum.all?(users, & &1.v1_enriched)
    end

    test "accesses resolution.before_output" do
      {:ok, user} = Repo.insert(%User{name: "Original", email: "v1beforeoutput@example.com"})

      defmodule BeforeOutputChecker do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(updated_user, resolution) do
          send(self(), {:before_output, resolution.before_output})
          updated_user
        end
      end

      Repo.set_middleware([EctoMiddleware.Super, BeforeOutputChecker])

      changeset = User.changeset(user, %{name: "Updated"})
      Repo.update(changeset)

      assert_received {:before_output, %Ecto.Changeset{}}
    end

    test "accesses resolution.after_input" do
      defmodule AfterInputChecker do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, resolution) do
          send(self(), {:after_input, resolution.after_input})
          user
        end
      end

      Repo.set_middleware([EctoMiddleware.Super, AfterInputChecker])

      changeset = User.changeset(%User{}, %{name: "Test", email: "v1afterinput@example.com"})
      Repo.insert(changeset)

      assert_received {:after_input, %User{}}
    end

    test "handles errors without transformation" do
      defmodule V1ErrorHandler do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware({:error, _} = error, _resolution) do
          # Don't transform errors
          error
        end

        def middleware(user, _resolution) do
          Map.put(user, :enriched, true)
        end
      end

      Repo.set_middleware([EctoMiddleware.Super, V1ErrorHandler])

      # Invalid changeset (missing email)
      changeset = User.changeset(%User{}, %{name: "Test"})
      {:error, changeset} = Repo.insert(changeset)

      # Error should pass through
      assert changeset.errors[:email]
    end
  end
end

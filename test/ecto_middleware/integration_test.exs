defmodule EctoMiddleware.IntegrationTest do
  @moduledoc """
  Integration tests for EctoMiddleware with actual Ecto operations.

  These tests verify that middleware works correctly with real database operations
  including insert, update, delete, and query operations.
  """
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias EctoMiddleware.Test.Repo
  alias EctoMiddleware.Test.Schemas.Post
  alias EctoMiddleware.Test.Schemas.User

  setup do
    :ok = Sandbox.checkout(Repo)
    on_exit(fn -> Repo.reset_middleware() end)
    :ok
  end

  describe "insert operations with middleware" do
    test "insert/2 executes middleware in correct order" do
      defmodule InsertTracker do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(resource, _resolution) do
          send(self(), :insert_tracker_ran)
          resource
        end
      end

      Repo.set_middleware([InsertTracker, EctoMiddleware.Super])

      changeset = User.changeset(%User{}, %{name: "Alice", email: "alice@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.name == "Alice"
      assert user.email == "alice@example.com"
      assert user.id
      assert_received :insert_tracker_ran
    end

    test "insert/2 with before middleware can transform input" do
      defmodule EmailNormalizer do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          Ecto.Changeset.update_change(changeset, :email, &String.downcase/1)
        end
      end

      Repo.set_middleware([EmailNormalizer, EctoMiddleware.Super])

      changeset = User.changeset(%User{}, %{name: "Bob", email: "BOB@EXAMPLE.COM"})
      {:ok, user} = Repo.insert(changeset)

      assert user.email == "bob@example.com"
    end

    test "insert/2 with after middleware can transform result" do
      defmodule ResultLogger do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) do
          send(self(), {:inserted, user.id})
          user
        end
      end

      Repo.set_middleware([EctoMiddleware.Super, ResultLogger])

      changeset = User.changeset(%User{}, %{name: "Charlie", email: "charlie@example.com"})
      {:ok, _user} = Repo.insert(changeset)

      assert_received {:inserted, user_id} when is_integer(user_id)
    end

    test "insert!/2 executes middleware and raises on error" do
      defmodule ValidationEnforcer do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          if Ecto.Changeset.get_field(changeset, :email) == "invalid" do
            Ecto.Changeset.add_error(changeset, :email, "cannot be 'invalid'")
          else
            changeset
          end
        end
      end

      Repo.set_middleware([ValidationEnforcer, EctoMiddleware.Super])

      assert_raise Ecto.InvalidChangesetError, fn ->
        changeset = User.changeset(%User{}, %{name: "Dave", email: "invalid"})
        Repo.insert!(changeset)
      end
    end
  end

  describe "update operations with middleware" do
    test "update/2 executes middleware correctly" do
      user = Repo.insert!(%User{name: "Eve", email: "eve@example.com"})

      defmodule UpdateTracker do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          send(self(), :update_middleware_ran)
          changeset
        end
      end

      Repo.set_middleware([UpdateTracker, EctoMiddleware.Super])

      changeset = User.changeset(user, %{name: "Eve Updated"})
      {:ok, updated_user} = Repo.update(changeset)

      assert updated_user.name == "Eve Updated"
      assert_received :update_middleware_ran
    end

    test "update/2 with before middleware can prevent updates" do
      user = Repo.insert!(%User{name: "Frank", email: "frank@example.com"})

      defmodule UpdateBlocker do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          Ecto.Changeset.add_error(changeset, :base, "updates not allowed")
        end
      end

      Repo.set_middleware([UpdateBlocker, EctoMiddleware.Super])

      changeset = User.changeset(user, %{name: "Frank Updated"})
      {:error, changeset} = Repo.update(changeset)

      assert {:base, {"updates not allowed", []}} in changeset.errors
    end
  end

  describe "delete operations with middleware" do
    test "delete/2 executes middleware" do
      user = Repo.insert!(%User{name: "Grace", email: "grace@example.com"})

      defmodule DeleteLogger do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) do
          send(self(), {:deleting, user.id})
          user
        end
      end

      Repo.set_middleware([DeleteLogger, EctoMiddleware.Super])

      {:ok, deleted_user} = Repo.delete(user)

      assert deleted_user.id == user.id
      assert_received {:deleting, _}
    end

    test "delete!/2 executes middleware and returns struct" do
      user = Repo.insert!(%User{name: "Heidi", email: "heidi@example.com"})

      defmodule DeleteNotifier do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(struct, _resolution) do
          send(self(), :delete_confirmed)
          struct
        end
      end

      Repo.set_middleware([EctoMiddleware.Super, DeleteNotifier])

      deleted_user = Repo.delete!(user)

      assert deleted_user.id == user.id
      assert_received :delete_confirmed
    end
  end

  describe "query operations with middleware" do
    test "get/3 executes after middleware on result" do
      user = Repo.insert!(%User{name: "Ivan", email: "ivan@example.com"})

      defmodule GetEnricher do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) when is_struct(user) do
          Map.put(user, :enriched, true)
        end

        def middleware(other, _resolution), do: other
      end

      Repo.set_middleware([EctoMiddleware.Super, GetEnricher])

      result = Repo.get(User, user.id)

      assert result.enriched == true
      assert result.name == "Ivan"
    end

    test "get_by/3 executes middleware on result" do
      Repo.insert!(%User{name: "Judy", email: "judy@example.com"})

      defmodule GetByLogger do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) when is_struct(user) do
          send(self(), {:found, user.email})
          user
        end

        def middleware(other, _resolution), do: other
      end

      Repo.set_middleware([EctoMiddleware.Super, GetByLogger])

      result = Repo.get_by(User, email: "judy@example.com")

      assert result.email == "judy@example.com"
      assert_received {:found, "judy@example.com"}
    end

    test "all/2 executes middleware on each result" do
      Repo.insert!(%User{name: "Kate", email: "kate@example.com"})
      Repo.insert!(%User{name: "Leo", email: "leo@example.com"})

      defmodule AllCounter do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) when is_struct(user) do
          Map.put(user, :counted, true)
        end

        def middleware(other, _resolution), do: other
      end

      Repo.set_middleware([EctoMiddleware.Super, AllCounter])

      results = Repo.all(User)

      assert length(results) >= 2
      assert Enum.all?(results, & &1.counted)
    end

    test "one/2 executes middleware on single result" do
      import Ecto.Query

      Repo.insert!(%User{name: "Mike", email: "mike@example.com"})

      defmodule OneMarker do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) when is_struct(user) do
          Map.put(user, :is_one, true)
        end

        def middleware(other, _resolution), do: other
      end

      Repo.set_middleware([EctoMiddleware.Super, OneMarker])

      result = Repo.one(from(u in User, where: u.email == "mike@example.com"))

      assert result.is_one == true
    end
  end

  describe "middleware with multiple transformations" do
    test "chains multiple before and after middleware" do
      defmodule Step1 do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          Ecto.Changeset.put_change(changeset, :name, "Step1-" <> Ecto.Changeset.get_field(changeset, :name))
        end
      end

      defmodule Step2 do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(changeset, _resolution) do
          Ecto.Changeset.put_change(changeset, :name, Ecto.Changeset.get_field(changeset, :name) <> "-Step2")
        end
      end

      defmodule Step3 do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(user, _resolution) do
          Map.put(user, :final_step, true)
        end
      end

      Repo.set_middleware([Step1, Step2, EctoMiddleware.Super, Step3])

      changeset = User.changeset(%User{}, %{name: "Nancy", email: "nancy@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.name == "Step1-Nancy-Step2"
      assert user.final_step == true
    end
  end

  describe "error handling in middleware" do
    test "middleware exceptions are propagated" do
      defmodule FailingMiddleware do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(_resource, _resolution) do
          raise "intentional middleware failure"
        end
      end

      Repo.set_middleware([FailingMiddleware, EctoMiddleware.Super])

      assert_raise RuntimeError, "intentional middleware failure", fn ->
        changeset = User.changeset(%User{}, %{name: "Oscar", email: "oscar@example.com"})
        Repo.insert(changeset)
      end
    end

    test "database errors are not caught by middleware" do
      Repo.insert!(%User{name: "Pete", email: "pete@example.com"})

      defmodule NoOpMiddleware do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(resource, _resolution), do: resource
      end

      Repo.set_middleware([NoOpMiddleware, EctoMiddleware.Super])

      changeset = User.changeset(%User{}, %{name: "Pete2", email: "pete@example.com"})

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert(changeset)
      end
    end
  end

  describe "middleware with Post schema" do
    test "insert and query posts with middleware" do
      defmodule PostEnricher do
        @moduledoc false
        @behaviour EctoMiddleware

        def middleware(post, _resolution) when is_struct(post, Post) do
          Map.put(post, :enriched, true)
        end

        def middleware(other, _resolution), do: other
      end

      Repo.set_middleware([EctoMiddleware.Super, PostEnricher])

      {:ok, post} = Repo.insert(%Post{title: "Test Post", body: "Content"})

      assert post.enriched == true
      assert post.title == "Test Post"

      fetched_post = Repo.get(Post, post.id)
      assert fetched_post.enriched == true
    end
  end
end

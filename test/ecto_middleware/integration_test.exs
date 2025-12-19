defmodule EctoMiddleware.IntegrationTest do
  @moduledoc """
  Integration tests for EctoMiddleware v2 API with actual Ecto operations.

  These tests verify that v2 middleware works correctly with real database operations
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

  describe "insert operations with process_before/2" do
    test "can transform changeset before insert" do
      defmodule EmailNormalizer do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(changeset, _resolution) do
          Ecto.Changeset.update_change(changeset, :email, &String.downcase/1)
        end
      end

      Repo.set_middleware([EmailNormalizer])

      changeset = User.changeset(%User{}, %{name: "Alice", email: "ALICE@EXAMPLE.COM"})
      {:ok, user} = Repo.insert(changeset)

      assert user.email == "alice@example.com"
      assert user.name == "Alice"
    end

    test "can add validations before insert" do
      defmodule StrictValidator do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(changeset, _resolution) do
          Ecto.Changeset.validate_length(changeset, :name, min: 5)
        end
      end

      Repo.set_middleware([StrictValidator])

      changeset = User.changeset(%User{}, %{name: "Bob", email: "bob@example.com"})
      {:error, changeset} = Repo.insert(changeset)

      assert "should be at least 5 character(s)" in errors_on(changeset).name
    end

    test "multiple process_before middleware chain transformations" do
      defmodule TrimName do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(changeset, _resolution) do
          Ecto.Changeset.update_change(changeset, :name, &String.trim/1)
        end
      end

      defmodule UppercaseName do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(changeset, _resolution) do
          Ecto.Changeset.update_change(changeset, :name, &String.upcase/1)
        end
      end

      Repo.set_middleware([TrimName, UppercaseName])

      changeset = User.changeset(%User{}, %{name: "  charlie  ", email: "charlie@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.name == "CHARLIE"
    end
  end

  describe "insert operations with process_after/2" do
    test "can enrich result after insert" do
      defmodule InsertLogger do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after({:ok, user}, _resolution) do
          send(self(), {:inserted, user.id})
          {:ok, Map.put(user, :logged, true)}
        end

        def process_after(other, _resolution), do: other
      end

      Repo.set_middleware([InsertLogger])

      changeset = User.changeset(%User{}, %{name: "Dave", email: "dave@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.logged == true
      assert_received {:inserted, id} when is_integer(id)
    end

    test "does not transform errors" do
      defmodule ErrorPreserver do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after({:ok, user}, _resolution) do
          {:ok, Map.put(user, :enriched, true)}
        end

        def process_after({:error, changeset}, _resolution) do
          {:error, changeset}
        end
      end

      Repo.set_middleware([ErrorPreserver])

      changeset = User.changeset(%User{}, %{name: "Eve", email: nil})
      {:error, changeset} = Repo.insert(changeset)

      refute Map.has_key?(changeset, :enriched)
      assert "can't be blank" in errors_on(changeset).email
    end
  end

  describe "insert operations with process/2 and halting" do
    test "can halt before database operation (cache hit simulation)" do
      defmodule CacheChecker do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process(%Ecto.Changeset{} = changeset, _resolution) do
          # Simulate cache hit - don't call yield, just return cached result
          data = Ecto.Changeset.apply_changes(changeset)

          cached_user = %User{
            id: 999,
            name: data.name,
            email: data.email,
            inserted_at: ~N[2025-01-01 00:00:00],
            updated_at: ~N[2025-01-01 00:00:00]
          }

          send(self(), :cache_hit)
          {:halt, {:ok, cached_user}}
        end

        # Pass through other resource types (like query modules)
        def process(resource, resolution) do
          elem(EctoMiddleware.Engine.yield(resource, resolution), 0)
        end
      end

      Repo.set_middleware([CacheChecker])

      changeset = User.changeset(%User{}, %{name: "Frank", email: "frank@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.id == 999
      assert user.name == "Frank"
      assert_received :cache_hit

      # Verify it didn't actually insert (resets middleware to avoid cache hit on get)
      Repo.reset_middleware()
      assert Repo.get(User, 999) == nil
    end

    test "can short-circuit on authorization failure" do
      defmodule AuthChecker do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process(%Ecto.Changeset{} = changeset, resolution) do
          # Simulate unauthorized
          data = Ecto.Changeset.apply_changes(changeset)

          case data.email do
            "admin@example.com" ->
              # Authorized, continue
              elem(EctoMiddleware.Engine.yield(changeset, resolution), 0)

            _ ->
              # Unauthorized, halt
              {:halt, {:error, :unauthorized}}
          end
        end

        # Pass through non-changeset resources
        def process(resource, resolution) do
          elem(EctoMiddleware.Engine.yield(resource, resolution), 0)
        end
      end

      Repo.set_middleware([AuthChecker])

      # Authorized
      changeset = User.changeset(%User{}, %{name: "Admin", email: "admin@example.com"})
      assert {:ok, %User{}} = Repo.insert(changeset)

      # Unauthorized
      changeset = User.changeset(%User{}, %{name: "Hacker", email: "hacker@example.com"})
      assert {:error, :unauthorized} = Repo.insert(changeset)
    end

    test "full control with yield - logging before and after" do
      defmodule AuditLogger do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process(%Ecto.Changeset{} = changeset, resolution) do
          data = Ecto.Changeset.apply_changes(changeset)
          send(self(), {:before_insert, data.name})

          result = elem(EctoMiddleware.Engine.yield(changeset, resolution), 0)

          case result do
            {:ok, user} ->
              send(self(), {:after_insert, user.id})
              {:ok, Map.put(user, :audited, true)}

            error ->
              send(self(), {:insert_failed, data.name})
              error
          end
        end

        # Pass through non-changeset resources
        def process(resource, resolution) do
          elem(EctoMiddleware.Engine.yield(resource, resolution), 0)
        end
      end

      Repo.set_middleware([AuditLogger])

      changeset = User.changeset(%User{}, %{name: "Ivan", email: "ivan@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.audited == true
      assert_received {:before_insert, "Ivan"}
      assert_received {:after_insert, id} when is_integer(id)
    end
  end

  describe "update operations with v2 middleware" do
    test "process_before can modify changeset before update" do
      defmodule TimestampUpdater do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(changeset, _resolution) do
          Ecto.Changeset.put_change(changeset, :updated_at, ~N[2025-12-25 00:00:00])
        end
      end

      user = Repo.insert!(%User{name: "Julia", email: "julia@example.com"})

      Repo.set_middleware([TimestampUpdater])

      changeset = User.changeset(user, %{name: "Julia Updated"})
      {:ok, updated_user} = Repo.update(changeset)

      assert updated_user.name == "Julia Updated"
      assert updated_user.updated_at == ~N[2025-12-25 00:00:00]
    end

    test "can prevent updates with process/2" do
      defmodule ReadOnlyEnforcer do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process(%Ecto.Changeset{} = changeset, resolution) do
          # Check if trying to update a read-only user
          data = Ecto.Changeset.apply_changes(changeset)

          case data.email do
            "readonly@example.com" ->
              {:halt, {:error, :read_only}}

            _ ->
              elem(EctoMiddleware.Engine.yield(changeset, resolution), 0)
          end
        end

        # Pass through non-changeset resources
        def process(resource, resolution) do
          elem(EctoMiddleware.Engine.yield(resource, resolution), 0)
        end
      end

      user = Repo.insert!(%User{name: "ReadOnly", email: "readonly@example.com"})

      Repo.set_middleware([ReadOnlyEnforcer])

      changeset = User.changeset(user, %{name: "Modified"})
      assert {:error, :read_only} = Repo.update(changeset)

      # Verify it wasn't actually updated
      fresh_user = Repo.get(User, user.id)
      assert fresh_user.name == "ReadOnly"
    end
  end

  describe "delete operations with v2 middleware" do
    test "can implement soft delete with process/2" do
      defmodule SoftDeleter do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process(%User{} = user, _resolution) do
          send(self(), {:soft_deleted, user.id})
          {:halt, {:ok, user}}
        end

        def process(resource, resolution) do
          elem(EctoMiddleware.Engine.yield(resource, resolution), 0)
        end
      end

      user = Repo.insert!(%User{name: "Kate", email: "kate@example.com"})

      Repo.set_middleware([SoftDeleter])

      {:ok, deleted_user} = Repo.delete(user)

      assert deleted_user.id == user.id
      assert_received {:soft_deleted, _}

      # Verify it wasn't actually deleted
      Repo.reset_middleware()
      assert Repo.get(User, user.id)
    end

    test "process_after can log successful deletions" do
      defmodule DeleteLogger do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after({:ok, user}, _resolution) do
          send(self(), {:deleted, user.id, user.name})
          {:ok, user}
        end

        def process_after(other, _resolution), do: other
      end

      user = Repo.insert!(%User{name: "Leo", email: "leo@example.com"})

      Repo.set_middleware([DeleteLogger])

      {:ok, deleted_user} = Repo.delete(user)

      assert deleted_user.id == user.id
      assert_received {:deleted, id, "Leo"} when is_integer(id)
    end
  end

  describe "query operations with v2 middleware" do
    test "process_after enriches get results" do
      defmodule GetEnricher do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after(user, _resolution) when is_struct(user, User) do
          Map.put(user, :enriched, true)
        end

        def process_after(other, _resolution), do: other
      end

      user = Repo.insert!(%User{name: "Mike", email: "mike@example.com"})

      Repo.set_middleware([GetEnricher])

      result = Repo.get(User, user.id)

      assert result.enriched == true
      assert result.name == "Mike"
    end

    test "process_after enriches all results" do
      defmodule AllEnricher do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after(users, _resolution) when is_list(users) do
          Enum.map(users, &Map.put(&1, :enriched, true))
        end

        def process_after(other, _resolution), do: other
      end

      Repo.insert!(%User{name: "Nancy", email: "nancy@example.com"})
      Repo.insert!(%User{name: "Oscar", email: "oscar@example.com"})

      Repo.set_middleware([AllEnricher])

      results = Repo.all(User)

      assert length(results) >= 2
      assert Enum.all?(results, &Map.get(&1, :enriched))
    end

    test "can implement query caching with process/2" do
      defmodule QueryCacher do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process(queryable, resolution) do
          # Simulate cache check
          cache_key = inspect(queryable)

          case Process.get(cache_key) do
            nil ->
              # Cache miss - execute query
              result = elem(EctoMiddleware.Engine.yield(queryable, resolution), 0)
              Process.put(cache_key, result)
              send(self(), :cache_miss)
              result

            cached ->
              # Cache hit - return cached result
              send(self(), :cache_hit)
              cached
          end
        end
      end

      user = Repo.insert!(%User{name: "Pete", email: "pete@example.com"})

      Repo.set_middleware([QueryCacher])

      # First call - cache miss
      result1 = Repo.get(User, user.id)
      assert_received :cache_miss

      # Second call - cache hit
      result2 = Repo.get(User, user.id)
      assert_received :cache_hit

      assert result1.id == result2.id
    end
  end

  describe "error handling with real database errors" do
    test "database constraint violations propagate through middleware" do
      defmodule ConstraintLogger do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after({:error, changeset}, _resolution) do
          send(self(), :constraint_error)
          {:error, changeset}
        end

        def process_after(other, _resolution), do: other
      end

      Repo.insert!(%User{name: "Quinn", email: "quinn@example.com"})

      Repo.set_middleware([ConstraintLogger])

      # Try to insert duplicate email
      changeset = User.changeset(%User{}, %{name: "Quinn2", email: "quinn@example.com"})

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert(changeset)
      end
    end

    test "middleware exceptions propagate correctly" do
      defmodule FailingMiddleware do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(_changeset, _resolution) do
          raise "middleware error"
        end
      end

      Repo.set_middleware([FailingMiddleware])

      changeset = User.changeset(%User{}, %{name: "Rachel", email: "rachel@example.com"})

      assert_raise RuntimeError, "middleware error", fn ->
        Repo.insert(changeset)
      end
    end
  end

  describe "complex scenarios" do
    test "chaining multiple middleware with different purposes" do
      defmodule Validator do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(changeset, _resolution) do
          Ecto.Changeset.validate_format(changeset, :email, ~r/@/)
        end
      end

      defmodule Normalizer do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(changeset, _resolution) do
          changeset
          |> Ecto.Changeset.update_change(:name, &String.trim/1)
          |> Ecto.Changeset.update_change(:email, &String.downcase/1)
        end
      end

      defmodule Auditor do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after({:ok, user}, _resolution) do
          send(self(), {:audit, :insert, user.id})
          {:ok, user}
        end

        def process_after(other, _resolution), do: other
      end

      Repo.set_middleware([Validator, Normalizer, Auditor])

      changeset =
        User.changeset(%User{}, %{name: "  Sam  ", email: "SAM@EXAMPLE.COM"})

      {:ok, user} = Repo.insert(changeset)

      assert user.name == "Sam"
      assert user.email == "sam@example.com"
      assert_received {:audit, :insert, _}
    end

    test "using Resolution.private to pass data between middleware" do
      defmodule ContextSetter do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process(changeset, resolution) do
          alias EctoMiddleware.Resolution

          resolution = Resolution.put_private(resolution, :user_agent, "TestClient/1.0")
          resolution = Resolution.put_private(resolution, :ip_address, "127.0.0.1")

          elem(EctoMiddleware.Engine.yield(changeset, resolution), 0)
        end
      end

      defmodule ContextLogger do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after({:ok, user}, resolution) do
          alias EctoMiddleware.Resolution

          user_agent = Resolution.get_private(resolution, :user_agent)
          ip = Resolution.get_private(resolution, :ip_address)

          send(self(), {:logged_context, user_agent, ip})
          {:ok, user}
        end

        def process_after(other, _resolution), do: other
      end

      Repo.set_middleware([ContextSetter, ContextLogger])

      changeset = User.changeset(%User{}, %{name: "Tina", email: "tina@example.com"})
      {:ok, _user} = Repo.insert(changeset)

      assert_received {:logged_context, "TestClient/1.0", "127.0.0.1"}
    end

    test "works with Post schema (different schema)" do
      defmodule PostEnricher do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after({:ok, post}, _resolution) when is_struct(post, Post) do
          {:ok, Map.put(post, :enriched, true)}
        end

        def process_after(post, _resolution) when is_struct(post, Post) do
          Map.put(post, :enriched, true)
        end

        def process_after(other, _resolution), do: other
      end

      Repo.set_middleware([PostEnricher])

      {:ok, post} = Repo.insert(%Post{title: "Test Post", body: "Content"})

      assert post.enriched == true
      assert post.title == "Test Post"

      fetched_post = Repo.get(Post, post.id)
      assert fetched_post.enriched == true
    end
  end

  # Helper function to extract errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end

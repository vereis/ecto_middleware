defmodule EctoMiddleware.RepoTest do
  @moduledoc """
  Tests for EctoMiddleware.Repo - end-to-end integration tests with database.
  """
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias EctoMiddleware.Test.Repo
  alias EctoMiddleware.Test.Schemas.Post
  alias EctoMiddleware.Test.Schemas.User

  setup do
    :ok = Sandbox.checkout(Repo)
    on_exit(fn -> Repo.reset_middleware() end)
    :ok
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end

  describe "use EctoMiddleware.Repo" do
    test "implements EctoMiddleware.Repo behaviour" do
      # Verify the middleware/2 callback is defined
      assert function_exported?(Repo, :middleware, 2)
    end

    test "provides default middleware/2 that returns list with Super" do
      # Default includes EctoMiddleware.Super for v1 compat
      assert Repo.middleware(:insert, %User{}) == [EctoMiddleware.Super]
    end
  end

  describe "pipeline telemetry" do
    setup do
      test_pid = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      :telemetry.attach_many(
        "repo-test-#{inspect(ref)}",
        [
          [:ecto_middleware, :pipeline, :start],
          [:ecto_middleware, :pipeline, :stop],
          [:ecto_middleware, :pipeline, :exception]
        ],
        handler,
        nil
      )

      on_exit(fn -> :telemetry.detach("repo-test-#{inspect(ref)}") end)
      :ok
    end

    test "emits [:ecto_middleware, :pipeline, :start] with pipeline_id" do
      defmodule PipelineStartMiddleware do
        @moduledoc false
        use EctoMiddleware

        def process(resource, resolution) do
          {result, _} = EctoMiddleware.Engine.yield(resource, resolution)
          result
        end
      end

      Repo.set_middleware([PipelineStartMiddleware])

      changeset = User.changeset(%User{}, %{name: "Test", email: "pipeline@example.com"})
      Repo.insert(changeset)

      assert_received {:telemetry, [:ecto_middleware, :pipeline, :start], %{system_time: _},
                       %{repo: Repo, action: :insert, pipeline_id: _}}
    end

    test "emits [:ecto_middleware, :pipeline, :stop] with duration" do
      Repo.set_middleware([])

      changeset = User.changeset(%User{}, %{name: "Test", email: "stop@example.com"})
      Repo.insert(changeset)

      assert_received {:telemetry, [:ecto_middleware, :pipeline, :stop], %{duration: duration},
                       %{repo: Repo, action: :insert}}
                      when duration > 0
    end

    test "emits [:ecto_middleware, :pipeline, :exception] on error" do
      defmodule ExplodingPipelineMiddleware do
        @moduledoc false
        use EctoMiddleware

        def process(_resource, _resolution), do: raise("pipeline boom")
      end

      Repo.set_middleware([ExplodingPipelineMiddleware])

      changeset = User.changeset(%User{}, %{name: "Test", email: "explode@example.com"})

      assert_raise RuntimeError, "pipeline boom", fn ->
        Repo.insert(changeset)
      end

      assert_received {:telemetry, [:ecto_middleware, :pipeline, :exception], %{duration: _},
                       %{repo: Repo, action: :insert, kind: :error}}
    end

    test "pipeline_id propagates to all middleware events" do
      defmodule PropagateMiddleware do
        @moduledoc false
        use EctoMiddleware

        def process(resource, resolution) do
          {result, _} = EctoMiddleware.Engine.yield(resource, resolution)
          result
        end
      end

      # Also attach middleware events
      test_pid = self()
      ref2 = make_ref()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      :telemetry.attach_many(
        "middleware-test-#{inspect(ref2)}",
        [
          [:ecto_middleware, :middleware, :start],
          [:ecto_middleware, :middleware, :stop]
        ],
        handler,
        nil
      )

      on_exit(fn -> :telemetry.detach("middleware-test-#{inspect(ref2)}") end)

      Repo.set_middleware([PropagateMiddleware])

      changeset = User.changeset(%User{}, %{name: "Test", email: "propagate@example.com"})
      Repo.insert(changeset)

      assert_received {:telemetry, [:ecto_middleware, :pipeline, :start], _, %{pipeline_id: pipeline_id}}

      assert_received {:telemetry, [:ecto_middleware, :middleware, :start], _, %{pipeline_id: ^pipeline_id}}

      assert_received {:telemetry, [:ecto_middleware, :middleware, :stop], _, %{pipeline_id: ^pipeline_id}}
      assert_received {:telemetry, [:ecto_middleware, :pipeline, :stop], _, %{pipeline_id: ^pipeline_id}}
    end
  end

  describe "insert/2 operations" do
    setup do
      defmodule InsertRecorder do
        @moduledoc false
        use EctoMiddleware

        def process(resource, resolution) do
          send(self(), {:before, resolution.action, resource})
          {result, _} = EctoMiddleware.Engine.yield(resource, resolution)
          send(self(), {:after, resolution.action, result})
          result
        end
      end

      Repo.set_middleware([InsertRecorder])
      :ok
    end

    test "insert/2 executes middleware and returns {:ok, struct}" do
      changeset = User.changeset(%User{}, %{name: "Test", email: "insert_ok@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert_received {:before, :insert, %Ecto.Changeset{}}
      assert_received {:after, :insert, {:ok, %User{}}}
      assert user.name == "Test"
    end

    test "insert/2 executes middleware and returns {:error, changeset}" do
      changeset = User.changeset(%User{}, %{name: "Test", email: nil})
      {:error, changeset} = Repo.insert(changeset)

      assert_received {:before, :insert, %Ecto.Changeset{}}
      assert_received {:after, :insert, {:error, %Ecto.Changeset{}}}
      assert changeset.errors[:email]
    end

    test "insert!/2 executes middleware and returns struct" do
      changeset = User.changeset(%User{}, %{name: "Test", email: "insert_bang@example.com"})
      user = Repo.insert!(changeset)

      assert_received {:before, :insert!, %Ecto.Changeset{}}
      assert_received {:after, :insert!, %User{}}
      assert user.name == "Test"
    end

    test "insert!/2 raises on error" do
      changeset = User.changeset(%User{}, %{name: "Test", email: nil})

      assert_raise Ecto.InvalidChangesetError, fn ->
        Repo.insert!(changeset)
      end

      assert_received {:before, :insert!, %Ecto.Changeset{}}
    end
  end

  describe "update/2 operations" do
    setup do
      defmodule UpdateRecorder do
        @moduledoc false
        use EctoMiddleware

        def process(resource, resolution) do
          send(self(), {:before, resolution.action, resource})
          {result, _} = EctoMiddleware.Engine.yield(resource, resolution)
          send(self(), {:after, resolution.action, result})
          result
        end
      end

      Repo.set_middleware([UpdateRecorder])
      :ok
    end

    test "update/2 executes middleware and returns {:ok, struct}" do
      {:ok, user} = Repo.insert(%User{name: "Original", email: "update_ok@example.com"})
      flush_messages()

      changeset = User.changeset(user, %{name: "Updated"})
      {:ok, updated} = Repo.update(changeset)

      assert_received {:before, :update, %Ecto.Changeset{}}
      assert_received {:after, :update, {:ok, %User{}}}
      assert updated.name == "Updated"
    end

    test "update/2 executes middleware and returns {:error, changeset}" do
      {:ok, user} = Repo.insert(%User{name: "Original", email: "update_error@example.com"})
      flush_messages()

      changeset = User.changeset(user, %{email: nil})
      {:error, changeset} = Repo.update(changeset)

      assert_received {:before, :update, %Ecto.Changeset{}}
      assert_received {:after, :update, {:error, %Ecto.Changeset{}}}
    end

    test "update!/2 executes middleware and returns struct" do
      {:ok, user} = Repo.insert(%User{name: "Original", email: "update_bang@example.com"})
      flush_messages()

      changeset = User.changeset(user, %{name: "Updated"})
      updated = Repo.update!(changeset)

      assert_received {:before, :update!, %Ecto.Changeset{}}
      assert_received {:after, :update!, %User{}}
      assert updated.name == "Updated"
    end
  end

  describe "delete/2 operations" do
    setup do
      defmodule DeleteRecorder do
        @moduledoc false
        use EctoMiddleware

        def process(resource, resolution) do
          send(self(), {:before, resolution.action, resource})
          {result, _} = EctoMiddleware.Engine.yield(resource, resolution)
          send(self(), {:after, resolution.action, result})
          result
        end
      end

      Repo.set_middleware([DeleteRecorder])
      :ok
    end

    test "delete/2 executes middleware and returns {:ok, struct}" do
      {:ok, user} = Repo.insert(%User{name: "ToDelete", email: "delete_ok@example.com"})
      flush_messages()

      {:ok, deleted} = Repo.delete(user)

      assert_received {:before, :delete, %User{}}
      assert_received {:after, :delete, {:ok, %User{}}}
      assert deleted.id == user.id
    end

    test "delete!/2 executes middleware and returns struct" do
      {:ok, user} = Repo.insert(%User{name: "ToDelete", email: "delete_bang@example.com"})
      flush_messages()

      deleted = Repo.delete!(user)

      assert_received {:before, :delete!, %User{}}
      assert_received {:after, :delete!, %User{}}
      assert deleted.id == user.id
    end
  end

  describe "query operations - get" do
    setup do
      defmodule GetRecorder do
        @moduledoc false
        use EctoMiddleware

        def process(resource, resolution) do
          send(self(), {:before, resolution.action, resource})
          {result, _} = EctoMiddleware.Engine.yield(resource, resolution)
          send(self(), {:after, resolution.action, result})
          result
        end
      end

      Repo.set_middleware([GetRecorder])
      :ok
    end

    test "get/3 executes middleware and returns struct" do
      {:ok, user} = Repo.insert(%User{name: "Test", email: "get_ok@example.com"})
      flush_messages()

      result = Repo.get(User, user.id)

      assert_received {:before, :get, User}
      assert_received {:after, :get, %User{}}
      assert result.id == user.id
    end

    test "get/3 executes middleware and returns nil" do
      flush_messages()

      result = Repo.get(User, -1)

      assert_received {:before, :get, User}
      assert_received {:after, :get, nil}
      assert result == nil
    end

    test "get!/3 executes middleware and returns struct" do
      {:ok, user} = Repo.insert(%User{name: "Test", email: "get_bang@example.com"})
      flush_messages()

      result = Repo.get!(User, user.id)

      assert_received {:before, :get!, User}
      assert_received {:after, :get!, %User{}}
      assert result.id == user.id
    end

    test "get_by/3 executes middleware and returns struct" do
      {:ok, _} = Repo.insert(%User{name: "Test", email: "get_by_ok@example.com"})
      flush_messages()

      result = Repo.get_by(User, email: "get_by_ok@example.com")

      assert_received {:before, :get_by, User}
      assert_received {:after, :get_by, %User{}}
      assert result.email == "get_by_ok@example.com"
    end
  end

  describe "query operations - all/one" do
    setup do
      defmodule QueryRecorder do
        @moduledoc false
        use EctoMiddleware

        def process(resource, resolution) do
          send(self(), {:before, resolution.action, resource})
          {result, _} = EctoMiddleware.Engine.yield(resource, resolution)
          send(self(), {:after, resolution.action, result})
          result
        end
      end

      Repo.set_middleware([QueryRecorder])
      :ok
    end

    test "one/2 executes middleware and returns struct" do
      {:ok, _} = Repo.insert(%User{name: "Test", email: "one_ok@example.com"})
      flush_messages()

      query = from(u in User, where: u.email == "one_ok@example.com")
      result = Repo.one(query)

      assert_received {:before, :one, %Ecto.Query{}}
      assert_received {:after, :one, %User{}}
      assert result.email == "one_ok@example.com"
    end

    test "all/2 executes middleware and returns list" do
      {:ok, _} = Repo.insert(%User{name: "Test1", email: "all1@example.com"})
      {:ok, _} = Repo.insert(%User{name: "Test2", email: "all2@example.com"})
      flush_messages()

      results = Repo.all(User)

      assert_received {:before, :all, User}
      assert_received {:after, :all, list} when is_list(list)
      assert length(results) >= 2
    end
  end

  describe "middleware transformation" do
    test "process_before can modify changeset" do
      defmodule EmailNormalizer do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(changeset, _resolution) do
          {:cont, Ecto.Changeset.update_change(changeset, :email, &String.downcase/1)}
        end
      end

      Repo.set_middleware([EmailNormalizer])

      changeset = User.changeset(%User{}, %{name: "Test", email: "TEST@EXAMPLE.COM"})
      {:ok, user} = Repo.insert(changeset)

      assert user.email == "test@example.com"
    end

    test "process_after can enrich results" do
      defmodule Enricher do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after({:ok, user}, _resolution) do
          {:cont, {:ok, Map.put(user, :enriched, true)}}
        end

        def process_after(other, _resolution), do: {:cont, other}
      end

      Repo.set_middleware([Enricher])

      changeset = User.changeset(%User{}, %{name: "Test", email: "enrich@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.enriched == true
    end

    test "multiple middleware chain correctly" do
      defmodule Step1 do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(changeset, _resolution) do
          {:cont, Ecto.Changeset.update_change(changeset, :name, &String.trim/1)}
        end
      end

      defmodule Step2 do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(changeset, _resolution) do
          {:cont, Ecto.Changeset.update_change(changeset, :name, &String.upcase/1)}
        end
      end

      Repo.set_middleware([Step1, Step2])

      changeset = User.changeset(%User{}, %{name: "  test  ", email: "chain@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.name == "TEST"
    end
  end

  describe "middleware halting" do
    test "halt before database prevents insert" do
      defmodule CacheHit do
        @moduledoc false
        use EctoMiddleware

        def process(_resource, _resolution) do
          {:halt, {:ok, %User{id: 999, name: "Cached", email: "cached@example.com"}}}
        end
      end

      Repo.set_middleware([CacheHit])

      changeset = User.changeset(%User{}, %{name: "Test", email: "halt@example.com"})
      {:ok, user} = Repo.insert(changeset)

      assert user.id == 999

      # Verify nothing was actually inserted
      Repo.reset_middleware()
      assert Repo.get(User, 999) == nil
    end

    test "halted value returned to caller" do
      defmodule CustomHalt do
        @moduledoc false
        use EctoMiddleware

        def process(_resource, _resolution), do: {:halt, {:error, :custom_error}}
      end

      Repo.set_middleware([CustomHalt])

      changeset = User.changeset(%User{}, %{name: "Test", email: "custom@example.com"})
      result = Repo.insert(changeset)

      assert result == {:error, :custom_error}
    end
  end

  describe "middleware communication via private" do
    test "put_private stores value for later middleware" do
      defmodule PrivateWriter do
        @moduledoc false
        use EctoMiddleware

        def process(resource, resolution) do
          resolution = EctoMiddleware.Resolution.put_private(resolution, :trace_id, "abc123")
          {result, _} = EctoMiddleware.Engine.yield(resource, resolution)
          result
        end
      end

      defmodule PrivateReader do
        @moduledoc false
        use EctoMiddleware

        def process(resource, resolution) do
          trace_id = EctoMiddleware.Resolution.get_private(resolution, :trace_id)
          send(self(), {:trace_id, trace_id})
          {result, _} = EctoMiddleware.Engine.yield(resource, resolution)
          result
        end
      end

      Repo.set_middleware([PrivateWriter, PrivateReader])

      changeset = User.changeset(%User{}, %{name: "Test", email: "private@example.com"})
      Repo.insert(changeset)

      assert_received {:trace_id, "abc123"}
    end
  end
end

defmodule EctoMiddleware.MiddlewareTest do
  @moduledoc """
  Core middleware tests for EctoMiddleware v2 API.

  Tests the primary v2 API including:
  - process_before/2 - Transform resources before DB operations
  - process_after/2 - Transform results after DB operations
  - process/2 - Full control with yield/2 calls
  - Resolution.private helpers
  - Mixing v1 and v2 middleware
  """
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias EctoMiddleware.Resolution
  alias EctoMiddleware.Test.Repo
  alias EctoMiddleware.Test.Schemas.User

  # Define all middleware modules at module level to avoid cyclic dependencies

  # V2 Before Middleware
  defmodule BeforeUppercase do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process_before(resource, _resolution) do
      %{resource | name: String.upcase(resource.name)}
    end
  end

  defmodule BeforeTrim do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process_before(resource, _resolution) do
      %{resource | name: String.trim(resource.name)}
    end
  end

  # V2 After Middleware
  defmodule AfterEnrich do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process_after(result, _resolution) do
      case result do
        {:ok, user} -> {:ok, Map.put(user, :enriched, true)}
        other -> other
      end
    end
  end

  defmodule AfterAddFlag do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process_after(result, _resolution) do
      case result do
        {:ok, user} -> {:ok, Map.put(user, :flag, "added")}
        other -> other
      end
    end
  end

  # V2 Call Middleware
  defmodule CallLogger do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process(resource, resolution) do
      send(self(), {:before, resource.name})
      {result, _resolution} = EctoMiddleware.Engine.yield(resource, resolution)
      send(self(), {:after, result})
      result
    end
  end

  defmodule CallTransformer do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process(resource, resolution) do
      transformed = %{resource | name: String.upcase(resource.name)}
      {result, _resolution} = EctoMiddleware.Engine.yield(transformed, resolution)

      case result do
        {:ok, user} -> {:ok, Map.put(user, :transformed, true)}
        other -> other
      end
    end
  end

  defmodule CallShortCircuit do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process(resource, _resolution) do
      if resource.name == "blocked" do
        {:error, :blocked}
      else
        {:ok, resource}
      end
    end
  end

  # V1 Middleware for mixing tests
  defmodule V1Before do
    @moduledoc false
    def middleware(resource, _resolution) do
      %{resource | name: "v1-" <> resource.name}
    end
  end

  defmodule V1After do
    @moduledoc false
    def middleware(user, _resolution) do
      Map.put(user, :v1_after, true)
    end
  end

  defmodule V2Before do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process_before(resource, _resolution) do
      %{resource | name: resource.name <> "-v2"}
    end
  end

  defmodule V2After do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process_after(result, _resolution) do
      case result do
        {:ok, user} -> {:ok, Map.put(user, :v2_after, true)}
        other -> other
      end
    end
  end

  # Resolution.private test middleware
  defmodule PrivateWriter do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process(resource, resolution) do
      resolution = Resolution.put_private(resolution, :custom_data, "stored")
      elem(EctoMiddleware.Engine.yield(resource, resolution), 0)
    end
  end

  defmodule PrivateReader do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process(resource, resolution) do
      data = Resolution.get_private(resolution, :custom_data)
      send(self(), {:private_data, data})
      elem(EctoMiddleware.Engine.yield(resource, resolution), 0)
    end
  end

  # Minimal middleware for default implementation tests
  defmodule MinimalMiddleware do
    @moduledoc false
    use EctoMiddleware
  end

  # Error testing middleware
  defmodule ErrorBefore do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process_before(_resource, _resolution) do
      raise "Error in process_before"
    end
  end

  defmodule ErrorAfter do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process_after(_result, _resolution) do
      raise "Error in process_after"
    end
  end

  # Context checking middleware
  defmodule ContextChecker do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process(resource, resolution) do
      send(self(), {:context, resolution.repo, resolution.action, resolution.entity})
      elem(EctoMiddleware.Engine.yield(resource, resolution), 0)
    end
  end

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  describe "v2 process_before/2 callback" do
    test "transforms resource before database operation" do
      user = %User{name: "alice", email: "alice@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([BeforeUppercase]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert {:ok, result} = elem(EctoMiddleware.Engine.yield(user, resolution), 0)
      assert result.name == "ALICE"
    end

    test "multiple before callbacks chain transformations" do
      user = %User{name: "  bob  ", email: "bob@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([BeforeTrim, BeforeUppercase]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert {:ok, result} = elem(EctoMiddleware.Engine.yield(user, resolution), 0)
      assert result.name == "BOB"
    end
  end

  describe "v2 process_after/2 callback" do
    test "transforms result after database operation" do
      user = %User{name: "carol", email: "carol@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([AfterEnrich]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert {:ok, result} = elem(EctoMiddleware.Engine.yield(user, resolution), 0)
      assert result.enriched == true
    end

    test "multiple after callbacks chain in reverse order" do
      user = %User{name: "dave", email: "dave@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([AfterEnrich, AfterAddFlag]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert {:ok, result} = elem(EctoMiddleware.Engine.yield(user, resolution), 0)
      assert result.enriched == true
      assert result.flag == "added"
    end
  end

  describe "v2 process/2 callback with yield/2" do
    test "allows full control over execution flow" do
      user = %User{name: "eve", email: "eve@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([CallLogger]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert {:ok, result} = elem(EctoMiddleware.Engine.yield(user, resolution), 0)
      assert result.name == "eve"

      assert_received {:before, "eve"}
      assert_received {:after, {:ok, %User{name: "eve"}}}
    end

    test "can transform both before and after" do
      user = %User{name: "frank", email: "frank@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([CallTransformer]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert {:ok, result} = elem(EctoMiddleware.Engine.yield(user, resolution), 0)
      assert result.name == "FRANK"
      assert result.transformed == true
    end

    test "can skip yield to short-circuit execution" do
      user = %User{name: "blocked", email: "blocked@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([CallShortCircuit]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert {:error, :blocked} = elem(EctoMiddleware.Engine.yield(user, resolution), 0)
    end
  end

  describe "mixing v1 and v2 middleware" do
    test "v1 before middleware works with v2 before middleware" do
      user = %User{name: "test", email: "test@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([V1Before, V2Before]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert {:ok, result} = elem(EctoMiddleware.Engine.yield(user, resolution), 0)
      assert result.name == "v1-test-v2"
    end

    test "v1 after middleware works with v2 after middleware" do
      user = %User{name: "test", email: "test@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware:
          EctoMiddleware.Engine.validate_middleware!([
            EctoMiddleware.Super,
            V1After,
            V2After
          ]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert {:ok, result} = elem(EctoMiddleware.Engine.yield(user, resolution), 0)
      assert result.v1_after == true
      assert result.v2_after == true
    end
  end

  describe "resolution.private helpers" do
    test "put_private/3 stores values" do
      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [],
        middleware: [],
        entity: nil,
        private: %{}
      }

      resolution = Resolution.put_private(resolution, :my_key, "my_value")
      assert resolution.private[:my_key] == "my_value"
    end

    test "get_private/2 retrieves values" do
      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [],
        middleware: [],
        entity: nil,
        private: %{my_key: "my_value"}
      }

      assert Resolution.get_private(resolution, :my_key) == "my_value"
    end

    test "get_private/3 returns default when key not found" do
      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [],
        middleware: [],
        entity: nil,
        private: %{}
      }

      assert Resolution.get_private(resolution, :missing_key, :default) == :default
    end

    test "middleware can use private to pass data" do
      user = %User{name: "test", email: "test@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([PrivateWriter, PrivateReader]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      EctoMiddleware.Engine.yield(user, resolution)
      assert_received {:private_data, "stored"}
    end
  end

  describe "default implementations" do
    test "process_before/2 default passes resource through unchanged" do
      user = %User{name: "test", email: "test@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([MinimalMiddleware]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert {:ok, result} = elem(EctoMiddleware.Engine.yield(user, resolution), 0)
      assert result.name == "test"
    end

    test "process_after/2 default passes result through unchanged" do
      user = %User{name: "test", email: "test@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware:
          EctoMiddleware.Engine.validate_middleware!([
            EctoMiddleware.Super,
            MinimalMiddleware
          ]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert {:ok, result} = elem(EctoMiddleware.Engine.yield(user, resolution), 0)
      assert result.name == "test"
    end
  end

  describe "error handling" do
    test "errors in before middleware propagate" do
      user = %User{name: "test", email: "test@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([ErrorBefore]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert_raise RuntimeError, "Error in process_before", fn ->
        EctoMiddleware.Engine.yield(user, resolution)
      end
    end

    test "errors in process_after middleware propagate" do
      user = %User{name: "test", email: "test@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([EctoMiddleware.Super, ErrorAfter]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      assert_raise RuntimeError, "Error in process_after", fn ->
        EctoMiddleware.Engine.yield(user, resolution)
      end
    end
  end

  describe "resolution context" do
    test "middleware receives correct resolution context" do
      user = %User{name: "test", email: "test@example.com"}

      resolution = %Resolution{
        repo: Repo,
        action: :insert,
        args: [user],
        middleware: EctoMiddleware.Engine.validate_middleware!([ContextChecker]),
        entity: user,
        private: %{
          __super__: fn res, _resolution -> {:ok, res} end
        }
      }

      EctoMiddleware.Engine.yield(user, resolution)
      assert_received {:context, Repo, :insert, ^user}
    end
  end
end

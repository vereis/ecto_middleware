defmodule EctoMiddleware.V1.ResolutionTest do
  @moduledoc """
  V1 API tests for EctoMiddleware core functionality.

  These tests focus on the deprecated v1 API:
  - partition_middleware/3: Splitting middleware by Super marker
  - Resolution.execute_before!/1: Executing before-middleware chain
  - Resolution.execute_after!/2: Executing after-middleware chain
  - Super.middleware/2: No-op middleware behavior

  These tests ensure v1 backwards compatibility.
  """
  use ExUnit.Case, async: true

  alias EctoMiddleware.Resolution

  # Helper to build resolution structs with sensible defaults
  defp build_resolution(overrides) do
    defaults = %{
      repo: __MODULE__.TestRepo,
      action: :insert,
      args: [%{value: 1}],
      entity: %{value: 1},
      before_middleware: [],
      after_middleware: []
    }

    struct!(Resolution, Enum.into(overrides, defaults))
  end

  # Simple middleware that adds a key to the resource
  defmodule TestMiddleware1 do
    @moduledoc "Test middleware that adds :test1 key"
    @behaviour EctoMiddleware

    def middleware(resource, _resolution) do
      Map.put(resource, :test1, true)
    end
  end

  defmodule TestMiddleware2 do
    @moduledoc "Test middleware that adds :test2 key"
    @behaviour EctoMiddleware

    def middleware(resource, _resolution) do
      Map.put(resource, :test2, true)
    end
  end

  defmodule TestMiddleware3 do
    @moduledoc "Test middleware that adds :test3 key"
    @behaviour EctoMiddleware

    def middleware(resource, _resolution) do
      Map.put(resource, :test3, true)
    end
  end

  # Middleware that doubles numeric values
  defmodule DoubleMiddleware do
    @moduledoc "Test middleware that doubles numeric values"
    @behaviour EctoMiddleware

    def middleware(value, _resolution) when is_number(value) do
      value * 2
    end
  end

  # Middleware that adds 10 to numeric values
  defmodule AddTenMiddleware do
    @moduledoc "Test middleware that adds 10 to numeric values"
    @behaviour EctoMiddleware

    def middleware(value, _resolution) when is_number(value) do
      value + 10
    end
  end

  # Middleware that multiplies numeric values by 3
  defmodule TripleMiddleware do
    @moduledoc "Test middleware that triples numeric values"
    @behaviour EctoMiddleware

    def middleware(value, _resolution) when is_number(value) do
      value * 3
    end
  end

  # Middleware that tracks execution order
  defmodule OrderTracker do
    @moduledoc "Test middleware that appends its name to an order list"
    @behaviour EctoMiddleware

    def middleware(resource, _resolution) do
      order = Map.get(resource, :order, [])
      Map.put(resource, :order, order ++ [__MODULE__])
    end
  end

  # Middleware that records the action from resolution
  defmodule ActionRecorder do
    @moduledoc "Test middleware that records the action from resolution"
    @behaviour EctoMiddleware

    def middleware(result, resolution) do
      Map.put(result, :action_was, resolution.action)
    end
  end

  # Middleware that inspects resolution fields
  defmodule ResolutionInspector do
    @moduledoc "Test middleware that extracts resolution metadata"
    @behaviour EctoMiddleware

    def middleware(resource, resolution) do
      Map.merge(resource, %{
        repo: resolution.repo,
        action: resolution.action,
        entity: resolution.entity
      })
    end
  end

  # Middleware that checks for before_output
  defmodule BeforeOutputChecker do
    @moduledoc "Test middleware that checks if before_output exists"
    @behaviour EctoMiddleware

    def middleware(resource, resolution) do
      Map.put(resource, :had_before_output, resolution.before_output != nil)
    end
  end

  # Middleware that raises an exception
  defmodule RaisingMiddleware do
    @moduledoc "Test middleware that raises an exception"
    @behaviour EctoMiddleware

    def middleware(_resource, _resolution) do
      raise "intentional test error"
    end
  end

  # Middleware that returns a non-map value
  defmodule StringMiddleware do
    @moduledoc "Test middleware that returns a string"
    @behaviour EctoMiddleware

    def middleware(_resource, _resolution) do
      "transformed_string"
    end
  end

  # Test repo that implements middleware/2
  defmodule TestRepo do
    @moduledoc "Test repository with various middleware configurations"

    alias EctoMiddleware.V1.ResolutionTest.TestMiddleware1
    alias EctoMiddleware.V1.ResolutionTest.TestMiddleware2
    alias EctoMiddleware.V1.ResolutionTest.TestMiddleware3

    def middleware(:all, _resource) do
      [
        TestMiddleware1,
        EctoMiddleware.Super,
        TestMiddleware2
      ]
    end

    def middleware(:insert, _resource) do
      [
        TestMiddleware1,
        TestMiddleware2,
        EctoMiddleware.Super,
        TestMiddleware3
      ]
    end

    def middleware(:delete, _resource) do
      [EctoMiddleware.Super]
    end

    def middleware(:update, _resource) do
      [TestMiddleware1]
    end

    def middleware(:get, _resource) do
      []
    end

    def middleware(:multi_super, _resource) do
      [
        TestMiddleware1,
        EctoMiddleware.Super,
        TestMiddleware2,
        EctoMiddleware.Super,
        TestMiddleware3
      ]
    end
  end

  describe "EctoMiddleware.Repo.partition_middleware/3" do
    test "splits middleware at Super marker with before and after" do
      assert {[TestMiddleware1], [TestMiddleware2]} =
               EctoMiddleware.Repo.partition_middleware(TestRepo, :all, %{})
    end

    test "splits middleware with multiple before and one after" do
      assert {[TestMiddleware1, TestMiddleware2], [TestMiddleware3]} =
               EctoMiddleware.Repo.partition_middleware(TestRepo, :insert, %{})
    end

    test "returns empty lists when only Super is present" do
      assert {[], []} = EctoMiddleware.Repo.partition_middleware(TestRepo, :delete, %{})
    end

    test "treats all middleware as after when Super is absent" do
      assert {[], [TestMiddleware1]} =
               EctoMiddleware.Repo.partition_middleware(TestRepo, :update, %{})
    end

    test "returns empty lists when no middleware configured" do
      assert {[], []} = EctoMiddleware.Repo.partition_middleware(TestRepo, :get, %{})
    end

    test "handles multiple Super markers (last one determines split)" do
      assert {[TestMiddleware1, EctoMiddleware.Super, TestMiddleware2], [TestMiddleware3]} =
               EctoMiddleware.Repo.partition_middleware(TestRepo, :multi_super, %{})
    end
  end

  describe "EctoMiddleware.Resolution.execute_before!/1" do
    test "executes middleware in order with proper chaining" do
      resolution = build_resolution(before_middleware: [TestMiddleware1, TestMiddleware2])
      result = Resolution.execute_before!(resolution)

      assert result.before_input == %{value: 1}
      assert result.before_output == %{value: 1, test1: true, test2: true}
    end

    test "returns input unchanged when middleware list is empty" do
      resolution = build_resolution(before_middleware: [])
      result = Resolution.execute_before!(resolution)

      assert result.before_input == %{value: 1}
      assert result.before_output == %{value: 1}
    end

    test "allows middleware to transform resource values" do
      resolution = build_resolution(args: [5], entity: 5, before_middleware: [DoubleMiddleware])
      result = Resolution.execute_before!(resolution)

      assert result.before_output == 10
    end

    test "chains transformations through multiple middleware" do
      resolution =
        build_resolution(
          args: [5],
          entity: 5,
          before_middleware: [DoubleMiddleware, AddTenMiddleware]
        )

      result = Resolution.execute_before!(resolution)

      assert result.before_output == 20
    end

    test "maintains execution order across middleware chain" do
      resolution =
        build_resolution(
          args: [%{order: []}],
          entity: %{order: []},
          before_middleware: [OrderTracker, OrderTracker]
        )

      result = Resolution.execute_before!(resolution)

      assert result.before_output.order == [OrderTracker, OrderTracker]
    end

    test "handles nil as before_input when args is empty" do
      resolution = build_resolution(args: [], entity: nil)
      result = Resolution.execute_before!(resolution)

      assert result.before_input == nil
      assert result.before_output == nil
    end

    test "propagates exceptions raised by middleware" do
      resolution = build_resolution(before_middleware: [RaisingMiddleware])

      assert_raise RuntimeError, "intentional test error", fn ->
        Resolution.execute_before!(resolution)
      end
    end

    test "allows middleware to return non-map values" do
      resolution = build_resolution(before_middleware: [StringMiddleware])
      result = Resolution.execute_before!(resolution)

      assert result.before_output == "transformed_string"
    end

    test "provides middleware access to resolution metadata" do
      resolution = build_resolution(before_middleware: [ResolutionInspector])
      result = Resolution.execute_before!(resolution)

      assert result.before_output.repo == EctoMiddleware.V1.ResolutionTest.TestRepo
      assert result.before_output.action == :insert
      assert result.before_output.entity == %{value: 1}
    end
  end

  describe "EctoMiddleware.Resolution.execute_after!/2" do
    test "executes middleware in order with proper chaining" do
      resolution = build_resolution(after_middleware: [TestMiddleware1, TestMiddleware2])
      result = Resolution.execute_after!(resolution, %{value: 1})

      assert result.after_input == %{value: 1}
      assert result.after_output == %{value: 1, test1: true, test2: true}
    end

    test "returns input unchanged when middleware list is empty" do
      resolution = build_resolution(after_middleware: [])
      result = Resolution.execute_after!(resolution, %{value: 1})

      assert result.after_input == %{value: 1}
      assert result.after_output == %{value: 1}
    end

    test "allows middleware to transform result values" do
      resolution = build_resolution(after_middleware: [TripleMiddleware])
      result = Resolution.execute_after!(resolution, 5)

      assert result.after_output == 15
    end

    test "provides middleware access to resolution metadata" do
      resolution = build_resolution(after_middleware: [ActionRecorder])
      result = Resolution.execute_after!(resolution, %{value: 1})

      assert result.after_output.action_was == :insert
    end

    test "maintains execution order across middleware chain" do
      resolution =
        build_resolution(after_middleware: [OrderTracker, OrderTracker])

      result = Resolution.execute_after!(resolution, %{order: []})

      assert result.after_output.order == [OrderTracker, OrderTracker]
    end

    test "receives resolution with populated before_output" do
      resolution =
        build_resolution(
          after_middleware: [BeforeOutputChecker],
          before_output: %{modified: true}
        )

      result = Resolution.execute_after!(resolution, %{id: 1})

      assert result.after_output.had_before_output == true
    end

    test "propagates exceptions raised by middleware" do
      resolution = build_resolution(after_middleware: [RaisingMiddleware])

      assert_raise RuntimeError, "intentional test error", fn ->
        Resolution.execute_after!(resolution, %{value: 1})
      end
    end
  end

  describe "EctoMiddleware.Super" do
    test "passes resource through without modification" do
      resource = %{id: 1, name: "test"}
      resolution = %Resolution{}

      assert EctoMiddleware.Super.middleware(resource, resolution) == resource
    end

    test "works with map resources" do
      assert EctoMiddleware.Super.middleware(%{id: 1}, %Resolution{}) == %{id: 1}
    end

    test "works with list resources" do
      assert EctoMiddleware.Super.middleware([1, 2, 3], %Resolution{}) == [1, 2, 3]
    end

    test "works with string resources" do
      assert EctoMiddleware.Super.middleware("string", %Resolution{}) == "string"
    end

    test "works with numeric resources" do
      assert EctoMiddleware.Super.middleware(123, %Resolution{}) == 123
    end

    test "works with nil resources" do
      assert EctoMiddleware.Super.middleware(nil, %Resolution{}) == nil
    end
  end

  describe "EctoMiddleware.middleware/3" do
    test "returns configured middleware list for action and resource" do
      assert EctoMiddleware.Repo.middleware(TestRepo, :all, %{}) == [
               TestMiddleware1,
               EctoMiddleware.Super,
               TestMiddleware2
             ]
    end

    test "returns different middleware based on action" do
      all_middleware = EctoMiddleware.Repo.middleware(TestRepo, :all, %{})
      insert_middleware = EctoMiddleware.Repo.middleware(TestRepo, :insert, %{})

      refute all_middleware == insert_middleware
    end

    test "returns empty list when no middleware configured" do
      assert EctoMiddleware.Repo.middleware(TestRepo, :get, %{}) == []
    end
  end

  describe "Resolution struct" do
    test "can be created with all fields populated" do
      resolution = %Resolution{
        repo: TestRepo,
        action: :insert,
        args: [%{id: 1}],
        middleware: [TestMiddleware1, TestMiddleware2],
        entity: %{id: 1},
        before_input: %{id: 1},
        before_output: %{id: 1, test1: true},
        after_input: %{id: 1, test1: true},
        after_output: %{id: 1, test1: true, test2: true},
        private: %{some_key: "some_value"}
      }

      assert resolution.repo == TestRepo
      assert resolution.action == :insert
      assert length(resolution.args) == 1
      assert length(resolution.middleware) == 2
    end

    test "can be created with minimal fields" do
      resolution = %Resolution{
        repo: TestRepo,
        action: :insert
      }

      assert resolution.repo == TestRepo
      assert resolution.action == :insert
      assert resolution.args == nil
      assert resolution.middleware == nil
    end

    test "defaults all fields to nil when not specified" do
      resolution = %Resolution{}

      assert resolution.repo == nil
      assert resolution.action == nil
      assert resolution.args == nil
      assert resolution.middleware == nil
      assert resolution.entity == nil
      assert resolution.before_middleware == nil
      assert resolution.after_middleware == nil
      assert resolution.before_input == nil
      assert resolution.before_output == nil
      assert resolution.after_input == nil
      assert resolution.after_output == nil
    end
  end
end

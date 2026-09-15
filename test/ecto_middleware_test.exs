defmodule EctoMiddlewareTest do
  @moduledoc """
  Tests for EctoMiddleware module - the main `use` macro and default implementations.
  """
  use ExUnit.Case, async: true

  describe "use EctoMiddleware" do
    test "defines @behaviour EctoMiddleware" do
      defmodule BehaviourTest do
        use EctoMiddleware
      end

      assert EctoMiddleware in BehaviourTest.__info__(:attributes)[:behaviour]
    end

    test "provides default process_before/2 that returns {:cont, resource}" do
      defmodule DefaultBeforeTest do
        use EctoMiddleware
      end

      assert {:cont, :resource} = DefaultBeforeTest.process_before(:resource, %EctoMiddleware.Resolution{})
    end

    test "does not opt into bulk operations by default" do
      defmodule BulkDefaultTest do
        use EctoMiddleware
      end

      refute BulkDefaultTest.__ecto_middleware_handles_bulk__()
    end

    test "opts into bulk operations with bulk_operations: true" do
      defmodule BulkOptInTest do
        use EctoMiddleware, bulk_operations: true
      end

      assert BulkOptInTest.__ecto_middleware_handles_bulk__()
    end

    test "provides default process_after/2 that returns {:cont, result}" do
      defmodule DefaultAfterTest do
        use EctoMiddleware
      end

      assert {:cont, :result} = DefaultAfterTest.process_after(:result, %EctoMiddleware.Resolution{})
    end

    test "provides default process/2 that calls before, yield, after" do
      defmodule DefaultProcessTest do
        use EctoMiddleware
      end

      resolution = %EctoMiddleware.Resolution{
        repo: __MODULE__,
        action: :test,
        args: [],
        middleware: [],
        entity: nil,
        private: %{__super__: fn res, _resolution -> res end, __pipeline_id__: make_ref()}
      }

      result = DefaultProcessTest.process(:input, resolution)
      assert {:cont, :input, %EctoMiddleware.Resolution{}} = result
    end

    test "allows overriding process_before/2" do
      defmodule OverrideBeforeTest do
        use EctoMiddleware

        @impl true
        def process_before(resource, _resolution) do
          {:cont, {:transformed, resource}}
        end
      end

      assert {:cont, {:transformed, :input}} =
               OverrideBeforeTest.process_before(:input, %EctoMiddleware.Resolution{})
    end

    test "allows overriding process_after/2" do
      defmodule OverrideAfterTest do
        use EctoMiddleware

        @impl true
        def process_after(result, _resolution) do
          {:cont, {:enriched, result}}
        end
      end

      assert {:cont, {:enriched, :result}} =
               OverrideAfterTest.process_after(:result, %EctoMiddleware.Resolution{})
    end

    test "allows overriding process/2" do
      defmodule OverrideProcessTest do
        use EctoMiddleware

        @impl true
        def process(_resource, _resolution) do
          :custom_result
        end
      end

      assert :custom_result = OverrideProcessTest.process(:input, %EctoMiddleware.Resolution{})
    end
  end

  describe "default process/2 integration" do
    test "calls process_before, yield, process_after in sequence" do
      defmodule SequenceTest do
        use EctoMiddleware

        @impl true
        def process_before(resource, _resolution) do
          {:cont, {:before, resource}}
        end

        @impl true
        def process_after(result, _resolution) do
          {:cont, {:after, result}}
        end
      end

      resolution = %EctoMiddleware.Resolution{
        repo: __MODULE__,
        action: :test,
        args: [],
        middleware: [],
        entity: nil,
        private: %{
          __super__: fn {:before, res}, _resolution -> {:super, res} end,
          __pipeline_id__: make_ref()
        }
      }

      result = SequenceTest.process(:input, resolution)
      assert {:cont, {:after, {:super, :input}}, %EctoMiddleware.Resolution{}} = result
    end

    test "halts on process_before {:halt, value}" do
      defmodule HaltBeforeTest do
        use EctoMiddleware

        @impl true
        def process_before(_resource, _resolution) do
          {:halt, :halted_before}
        end

        @impl true
        def process_after(_result, _resolution) do
          send(self(), :should_not_run)
          {:cont, :after}
        end
      end

      resolution = %EctoMiddleware.Resolution{
        repo: __MODULE__,
        action: :test,
        args: [],
        middleware: [],
        entity: nil,
        private: %{
          __super__: fn _res, _resolution ->
            send(self(), :super_should_not_run)
            :super
          end,
          __pipeline_id__: make_ref()
        }
      }

      # `process_before/2` halted, so `yield/2` never ran and there is no resolution to return
      result = HaltBeforeTest.process(:input, resolution)
      assert result == {:halt, :halted_before}
      refute_received :should_not_run
      refute_received :super_should_not_run
    end

    test "halts on process_after {:halt, value}" do
      defmodule HaltAfterTest do
        use EctoMiddleware

        @impl true
        def process_after(_result, _resolution) do
          {:halt, :halted_after}
        end
      end

      resolution = %EctoMiddleware.Resolution{
        repo: __MODULE__,
        action: :test,
        args: [],
        middleware: [],
        entity: nil,
        private: %{
          __super__: fn res, _resolution -> {:super, res} end,
          __pipeline_id__: make_ref()
        }
      }

      result = HaltAfterTest.process(:input, resolution)
      assert {:halt, :halted_after, %EctoMiddleware.Resolution{}} = result
    end
  end
end

defmodule EctoMiddleware.EngineTest do
  @moduledoc """
  Tests for EctoMiddleware.Engine module - the core middleware execution engine.
  """
  use ExUnit.Case, async: true

  alias EctoMiddleware.Engine
  alias EctoMiddleware.Resolution
  alias EctoMiddleware.Test.Middleware.Halter
  alias EctoMiddleware.Test.Middleware.Passthrough
  alias EctoMiddleware.Test.Middleware.Recorder
  alias EctoMiddleware.V1.After
  alias EctoMiddleware.V1.Before

  # Helper middleware for testing
  defmodule ProcessMiddleware do
    @moduledoc false
    use EctoMiddleware

    def process(resource, resolution) do
      {result, _} = Engine.yield(resource, resolution)
      result
    end
  end

  defmodule BeforeOnlyMiddleware do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process_before(resource, _resolution), do: {:cont, {:before, resource}}
  end

  defmodule AfterOnlyMiddleware do
    @moduledoc false
    use EctoMiddleware

    @impl true
    def process_after(result, _resolution), do: {:cont, {:after, result}}
  end

  defmodule V1Middleware do
    @moduledoc false
    @behaviour EctoMiddleware

    def middleware(resource, _resolution), do: {:v1, resource}
  end

  defmodule NoCallbackMiddleware do
    # No callbacks defined
    @moduledoc false
  end

  defmodule HaltingMiddleware do
    @moduledoc false
    use EctoMiddleware

    def process(_resource, _resolution), do: {:halt, :halted}
  end

  defmodule NeverRunMiddleware do
    @moduledoc false
    use EctoMiddleware

    def process(_resource, _resolution) do
      send(self(), :should_not_run)
      {:cont, :ran}
    end
  end

  defmodule OrderRecorder do
    @moduledoc false
    use EctoMiddleware

    def process(resource, resolution) do
      order = Process.get(:order, [])
      Process.put(:order, order ++ [:before])
      {result, _} = Engine.yield(resource, resolution)
      order = Process.get(:order, [])
      Process.put(:order, order ++ [:after])
      result
    end
  end

  defmodule CountingMiddleware do
    @moduledoc false
    use EctoMiddleware

    def process(resource, resolution) do
      count = Process.get(:count, 0)
      Process.put(:count, count + 1)
      {result, _} = Engine.yield(resource, resolution)
      result
    end
  end

  defmodule ResolutionUpdater do
    @moduledoc false
    use EctoMiddleware

    def process(resource, resolution) do
      resolution = Resolution.put_private(resolution, :updated, true)
      {result, updated} = Engine.yield(resource, resolution)
      {:cont, result, updated}
    end
  end

  defp build_resolution(middleware, super_fn \\ &passthrough_super/2) do
    %Resolution{
      repo: __MODULE__,
      action: :test,
      args: [%{input: true}],
      middleware: Engine.validate_middleware!(middleware),
      entity: %{input: true},
      private: %{__super__: super_fn, __pipeline_id__: make_ref()}
    }
  end

  defp passthrough_super(resource, _resolution), do: resource
  defp ok_super(resource, _resolution), do: {:ok, resource}
  defp error_super(_resource, _resolution), do: {:error, :failed}

  setup do
    Process.delete(:order)
    Process.delete(:count)
    :ok
  end

  describe "validate_middleware!/1" do
    test "accepts module with process/2" do
      assert [ProcessMiddleware] = Engine.validate_middleware!([ProcessMiddleware])
    end

    test "accepts module with process_before/2" do
      assert [BeforeOnlyMiddleware] = Engine.validate_middleware!([BeforeOnlyMiddleware])
    end

    test "accepts module with process_after/2" do
      assert [AfterOnlyMiddleware] = Engine.validate_middleware!([AfterOnlyMiddleware])
    end

    test "accepts module with middleware/2 (v1 compat)" do
      result = Engine.validate_middleware!([V1Middleware])
      assert [{Before, V1Middleware}] = result
    end

    test "raises ArgumentError for module without any callback" do
      assert_raise ArgumentError, ~r/must implement/, fn ->
        Engine.validate_middleware!([NoCallbackMiddleware])
      end
    end

    test "raises for non-module value" do
      # Passing a string raises FunctionClauseError from Code.ensure_loaded!/1
      assert_raise FunctionClauseError, fn ->
        Engine.validate_middleware!(["not_a_module"])
      end
    end

    test "wraps v1 middleware in Before wrapper when before Super" do
      result = Engine.validate_middleware!([V1Middleware, EctoMiddleware.Super])
      assert [{Before, V1Middleware}] = result
    end

    test "wraps v1 middleware in After wrapper when after Super" do
      result = Engine.validate_middleware!([EctoMiddleware.Super, V1Middleware])
      assert [{After, V1Middleware}] = result
    end

    test "ignores duplicate Super markers" do
      result =
        Engine.validate_middleware!([
          V1Middleware,
          EctoMiddleware.Super,
          EctoMiddleware.Super,
          V1Middleware
        ])

      assert [
               {Before, V1Middleware},
               {After, V1Middleware}
             ] = result
    end

    test "returns empty list for empty input" do
      assert [] = Engine.validate_middleware!([])
    end

    test "accepts list of multiple valid middleware" do
      result = Engine.validate_middleware!([ProcessMiddleware, BeforeOnlyMiddleware, AfterOnlyMiddleware])
      assert length(result) == 3
    end
  end

  describe "yield/2 - no middleware" do
    test "calls super function with resource" do
      super_fn = fn resource, _resolution ->
        send(self(), {:super_called, resource})
        resource
      end

      resolution = build_resolution([], super_fn)
      Engine.yield(%{test: true}, resolution)

      assert_received {:super_called, %{test: true}}
    end

    test "sets before_output on resolution" do
      resolution = build_resolution([])
      {_result, updated} = Engine.yield(%{test: true}, resolution)

      assert updated.before_output == %{test: true}
    end

    test "unwraps {:ok, value} for after_input" do
      resolution = build_resolution([], &ok_super/2)
      {_result, updated} = Engine.yield(%{test: true}, resolution)

      assert updated.after_input == %{test: true}
    end

    test "passes {:error, reason} through to after_input" do
      resolution = build_resolution([], &error_super/2)
      {_result, updated} = Engine.yield(%{test: true}, resolution)

      assert updated.after_input == {:error, :failed}
    end

    test "passes bare value through to after_input" do
      resolution = build_resolution([], &passthrough_super/2)
      {_result, updated} = Engine.yield(%{test: true}, resolution)

      assert updated.after_input == %{test: true}
    end

    test "returns {result, updated_resolution} tuple" do
      resolution = build_resolution([])
      result = Engine.yield(%{test: true}, resolution)

      assert {%{test: true}, %Resolution{}} = result
    end
  end

  describe "yield/2 - with middleware" do
    test "calls middleware process/2 function" do
      resolution = build_resolution([ProcessMiddleware])
      {result, _} = Engine.yield(%{test: true}, resolution)

      assert result == %{test: true}
    end

    test "continues chain on {:cont, value}" do
      resolution = build_resolution([BeforeOnlyMiddleware])
      {result, _} = Engine.yield(:input, resolution)

      assert result == {:before, :input}
    end

    test "stops chain on {:halt, value}" do
      resolution = build_resolution([HaltingMiddleware, NeverRunMiddleware])
      {result, _} = Engine.yield(:input, resolution)

      assert result == :halted
      refute_received :should_not_run
    end

    test "updates resolution on {:cont, value, resolution}" do
      resolution = build_resolution([ResolutionUpdater])
      {_result, updated} = Engine.yield(:input, resolution)

      assert Resolution.get_private(updated, :updated) == true
    end

    test "updates resolution on {:halt, value, resolution}" do
      defmodule HaltWithResolution do
        @moduledoc false
        use EctoMiddleware

        def process(_resource, resolution) do
          resolution = Resolution.put_private(resolution, :halted, true)
          {:halt, :halted, resolution}
        end
      end

      resolution = build_resolution([HaltWithResolution])
      {result, updated} = Engine.yield(:input, resolution)

      assert result == :halted
      assert Resolution.get_private(updated, :halted) == true
    end

    test "treats bare return as {:cont, value}" do
      defmodule BareReturnMiddleware do
        @moduledoc false
        use EctoMiddleware

        def process(resource, resolution) do
          {result, _} = Engine.yield(resource, resolution)
          result
        end
      end

      resolution = build_resolution([BareReturnMiddleware])
      {result, _} = Engine.yield(%{test: true}, resolution)

      assert result == %{test: true}
    end
  end

  describe "yield/2 - execution order" do
    test "middleware execute in list order" do
      Process.put(:order, [])

      super_fn = fn resource, _resolution ->
        order = Process.get(:order, [])
        Process.put(:order, order ++ [:super])
        resource
      end

      resolution = build_resolution([OrderRecorder], super_fn)
      Engine.yield(:input, resolution)

      assert Process.get(:order) == [:before, :super, :after]
    end

    test "each middleware executes exactly once" do
      Process.put(:count, 0)

      resolution =
        build_resolution([
          CountingMiddleware,
          CountingMiddleware,
          CountingMiddleware
        ])

      Engine.yield(:input, resolution)

      assert Process.get(:count) == 3
    end

    test "process_before runs before super" do
      Process.put(:order, [])

      defmodule BeforeOrderTest do
        use EctoMiddleware

        @impl true
        def process_before(resource, _resolution) do
          order = Process.get(:order, [])
          Process.put(:order, order ++ [:before])
          {:cont, resource}
        end
      end

      super_fn = fn resource, _resolution ->
        order = Process.get(:order, [])
        Process.put(:order, order ++ [:super])
        resource
      end

      resolution = build_resolution([BeforeOrderTest], super_fn)
      Engine.yield(:input, resolution)

      assert Process.get(:order) == [:before, :super]
    end

    test "process_after runs after super" do
      Process.put(:order, [])

      defmodule AfterOrderTest do
        use EctoMiddleware

        @impl true
        def process_after(result, _resolution) do
          order = Process.get(:order, [])
          Process.put(:order, order ++ [:after])
          {:cont, result}
        end
      end

      super_fn = fn resource, _resolution ->
        order = Process.get(:order, [])
        Process.put(:order, order ++ [:super])
        resource
      end

      resolution = build_resolution([AfterOrderTest], super_fn)
      Engine.yield(:input, resolution)

      assert Process.get(:order) == [:super, :after]
    end

    test "halting prevents subsequent middleware execution" do
      resolution = build_resolution([HaltingMiddleware, NeverRunMiddleware])
      Engine.yield(:input, resolution)

      refute_received :should_not_run
    end

    test "halting prevents super execution" do
      super_fn = fn _resource, _resolution ->
        send(self(), :super_called)
        :super_result
      end

      resolution = build_resolution([HaltingMiddleware], super_fn)
      Engine.yield(:input, resolution)

      refute_received :super_called
    end

    test "outer middleware process/2 still completes after inner halt" do
      defmodule OuterMiddleware do
        @moduledoc false
        use EctoMiddleware

        def process(resource, resolution) do
          send(self(), :outer_before)
          {result, _} = Engine.yield(resource, resolution)
          send(self(), {:outer_after, result})
          result
        end
      end

      resolution = build_resolution([OuterMiddleware, HaltingMiddleware])
      {result, _} = Engine.yield(:input, resolution)

      assert result == :halted
      assert_received :outer_before
      assert_received {:outer_after, :halted}
    end
  end

  describe "yield/2 - telemetry" do
    setup do
      test_pid = self()
      ref = make_ref()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      :telemetry.attach_many(
        "test-#{inspect(ref)}",
        [
          [:ecto_middleware, :middleware, :start],
          [:ecto_middleware, :middleware, :stop],
          [:ecto_middleware, :middleware, :exception]
        ],
        handler,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-#{inspect(ref)}") end)
      :ok
    end

    test "emits [:ecto_middleware, :middleware, :start] with pipeline_id" do
      resolution = build_resolution([ProcessMiddleware])
      Engine.yield(:input, resolution)

      assert_received {:telemetry, [:ecto_middleware, :middleware, :start], %{system_time: _},
                       %{middleware: ProcessMiddleware, pipeline_id: _}}
    end

    test "emits [:ecto_middleware, :middleware, :stop] with result: :cont" do
      resolution = build_resolution([ProcessMiddleware])
      Engine.yield(:input, resolution)

      assert_received {:telemetry, [:ecto_middleware, :middleware, :stop], %{duration: _},
                       %{middleware: ProcessMiddleware, result: :cont}}
    end

    test "emits [:ecto_middleware, :middleware, :stop] with result: :halt" do
      resolution = build_resolution([HaltingMiddleware])
      Engine.yield(:input, resolution)

      assert_received {:telemetry, [:ecto_middleware, :middleware, :stop], %{duration: _},
                       %{middleware: HaltingMiddleware, result: :halt}}
    end

    test "emits [:ecto_middleware, :middleware, :exception] on raise" do
      defmodule ExplodingMiddleware do
        @moduledoc false
        use EctoMiddleware

        def process(_resource, _resolution), do: raise("boom")
      end

      resolution = build_resolution([ExplodingMiddleware])

      assert_raise RuntimeError, "boom", fn ->
        Engine.yield(:input, resolution)
      end

      assert_received {:telemetry, [:ecto_middleware, :middleware, :exception], %{duration: _},
                       %{middleware: ExplodingMiddleware, kind: :error, reason: %RuntimeError{}}}
    end

    test "all events for same pipeline share pipeline_id" do
      resolution = build_resolution([ProcessMiddleware, ProcessMiddleware])
      Engine.yield(:input, resolution)

      assert_received {:telemetry, [:ecto_middleware, :middleware, :start], _, %{pipeline_id: id1}}
      assert_received {:telemetry, [:ecto_middleware, :middleware, :stop], _, %{pipeline_id: id2}}
      assert_received {:telemetry, [:ecto_middleware, :middleware, :start], _, %{pipeline_id: id3}}
      assert_received {:telemetry, [:ecto_middleware, :middleware, :stop], _, %{pipeline_id: id4}}

      assert id1 == id2
      assert id2 == id3
      assert id3 == id4
    end
  end

  describe "warnings_silenced?/0" do
    test "returns false by default" do
      refute Engine.warnings_silenced?()
    end
  end

  describe "run_phases/5 - resolution propagation" do
    test "resolution updates from an inner middleware reach an outer middleware" do
      defmodule InnerMiddleware do
        @moduledoc false
        use EctoMiddleware
      end

      defmodule OuterMiddleware do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after(result, resolution) do
          send(self(), {:outer_saw_before_output, resolution.before_output})
          {:cont, result}
        end
      end

      resolution = build_resolution([OuterMiddleware, InnerMiddleware])
      {_result, _updated} = Engine.yield(:input, resolution)

      # `before_output` is set by the innermost `yield/2`. It only reaches the outer
      # middleware if the inner one's generated `process/2` hands its updated resolution
      # back out. Returning a bare value there strands the update, which silently breaks
      # any outer middleware reading it (`ecto_hooks` dispatches `after_*` off this field).
      assert_received {:outer_saw_before_output, :input}
    end

    test "process_before/2 may return an updated resolution" do
      defmodule BeforeUpdatesResolution do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_before(resource, resolution) do
          {:cont, resource, Resolution.put_private(resolution, :before_ran, true)}
        end
      end

      resolution = build_resolution([BeforeUpdatesResolution])
      {_result, updated} = Engine.yield(:input, resolution)

      assert Resolution.get_private(updated, :before_ran) == true
    end

    test "process_after/2 may return an updated resolution" do
      defmodule AfterUpdatesResolution do
        @moduledoc false
        use EctoMiddleware

        @impl true
        def process_after(result, resolution) do
          {:cont, result, Resolution.put_private(resolution, :after_ran, true)}
        end
      end

      resolution = build_resolution([AfterUpdatesResolution])
      {_result, updated} = Engine.yield(:input, resolution)

      assert Resolution.get_private(updated, :after_ran) == true
    end
  end

  describe "reject_non_bulk_middleware/2" do
    defmodule BulkOptedIn do
      @moduledoc false
      use EctoMiddleware, bulk_operations: true
    end

    defmodule NotBulkOptedIn do
      @moduledoc false
      use EctoMiddleware
    end

    test "is a pass-through for non-bulk actions" do
      chain = [NotBulkOptedIn, EctoMiddleware.Super, BulkOptedIn]

      assert Engine.reject_non_bulk_middleware(chain, :insert) == chain
    end

    test "drops middleware that did not opt into bulk operations" do
      chain = [NotBulkOptedIn, BulkOptedIn]

      assert Engine.reject_non_bulk_middleware(chain, :insert_all) == [BulkOptedIn]
    end

    test "keeps EctoMiddleware.Super for every bulk action" do
      # Super is not a middleware but the marker `validate_middleware!/1` uses to split a
      # v1 chain into its `:before` and `:after` phases. Dropping it here leaves that reduce
      # stuck in `:before`, so an opted-in v1 middleware placed after Super would be handed
      # the resource instead of the operation's result.
      chain = [NotBulkOptedIn, EctoMiddleware.Super, BulkOptedIn]

      for action <- [:insert_all, :update_all, :delete_all] do
        assert Engine.reject_non_bulk_middleware(chain, action) ==
                 [EctoMiddleware.Super, BulkOptedIn]
      end
    end
  end
end

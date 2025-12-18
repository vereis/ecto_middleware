defmodule EctoMiddleware.Engine do
  @moduledoc """
  Internal engine for validating and executing middleware chains.

  See `EctoMiddleware` for information on writing middleware. This module is used
  internally by `EctoMiddleware.Repo` to execute middleware chains.

  ## Silencing Deprecation Warnings

  During migration from v1 to v2, you may want to silence deprecation warnings.
  This can be done via application configuration:

      # In config/config.exs
      config :ecto_middleware, :silence_deprecation_warnings, true

  This will suppress all deprecation warnings from `EctoMiddleware`. Note that this
  should only be used temporarily during migration - the deprecated APIs will be
  removed in v3.0.

  ## Middleware Execution

  Middleware are executed in a chain. You can think of this as a matroshka doll, where each
  middleware wraps the next one in the chain.

  Each middleware is expected to call `yield/2` to continue execution to the next middleware
  in the chain, but may also choose to halt execution by not calling `yield/2` and returning
  a value directly.

  For example, given the following middleware chain:

      [LoggerMiddleware, AuthMiddleware, VirtualFieldMiddleware]

  Execution proceeds as follows:

  1. `c:Ecto.Repo.insert/2` is called.
  2. `c:EctoMiddleware.process/2` is invoked on `LoggerMiddleware`.
     - It logs "Before insert".
     - It calls `yield/2` to continue execution.
  3. `c:EctoMiddleware.process/2` is invoked on `AuthMiddleware`.
     - It checks authorization.
     - It calls `yield/2` to continue execution.
  4. `c:EctoMiddleware.process/2` is invoked on `VirtualFieldMiddleware`.
     - It **immediately** calls `yield/2` to continue execution.
  5. There aren't any more middleware to execute, so the super function (the actual `c:Ecto.Repo.insert/2` call) is invoked.
     - The database insert occurs, returning `{:ok, user}`.
  6. Control returns to `VirtualFieldMiddleware`.
     - It resolves some virtual fields on the `user` struct.
     - It returns the user struct w/ virtual fields up the chain.
  7. Control returns to `AuthMiddleware`.
     - It doesn't do anything further, so it returns the user struct w/ virtual fields up the chain.
  8. Control returns to `LoggerMiddleware.process/2`.
     - It logs "After insert: {:ok, user w/ virtual fields}".
     - It returns the user struct up the chain.
  9. The caller of `c:Ecto.Repo.insert/2` sees the function result as `{:ok, user_with_virtual_fields}`.

  For simplicity, middleware authors can either implement the `c:EctoMiddleware.process_before/2` or
  `c:EctoMiddleware.process_after/2` callbacks to only operate in the "before" or "after" phases.

  Alternatively, you can implement `c:EctoMiddleware.process/2` for full control, but you must
  call `yield/2` at the appropriate time. Not calling `yield/2` will halt execution at that
  middleware.

  **Important**: `yield/2` returns `{result, updated_resolution}`. You must destructure this
  tuple when calling yield.

  See the `EctoMiddleware` docs for more information.

  ## Backwards Compatibility

  Prior versions of `EctoMiddleware` (v1.x) had a different middleware contract and execution engine.

  In those versions of the library, all middleware were expected to implement `middleware/2` in a
  middleware module (note: this was not a behaviour callback). This function was expected to take some
  "resource" and return that "resource" transformed by the middleware.

  Middleware executed exactly once, either before or after the `super` function, depending on their
  position relative to `EctoMiddleware.Super` in the middleware list.

  An example of this follows:

      defmodule Repo do
        use EctoMiddleware

        @impl EctoMiddleware
        def middleware(:insert, _resource) do
          [BeforeMiddleware, EctoMiddleware.Super, AfterMiddleware]
        end
      end

      defmodule BeforeMiddleware do
        def middleware(resource, _resolution) do
          transform_before(resource)
        end
      end

      defmodule AfterMiddleware do
        def middleware(resource, _resolution) do
          transform_after(resource)
        end
      end

  The current version of `EctoMiddleware` (v2.x) supports v1 middleware for backwards compatibility.

  This is implemented by dynamically replacing any v1 middleware with a v2 middleware that wraps
  the v1 middleware and calls its `middleware/2` function either before or after the `super` function
  is executed.

  This functionality is temporary and will be removed in v3.0, at which point all middleware
  must implement the v2 middleware contract.

  Using v1 middleware in this way will emit a deprecation warning. We strongly recommend updating
  any existing v1 middleware to implement the v2 middleware contract to avoid this warning and
  ensure compatibility with future versions of `EctoMiddleware`.
  """

  alias EctoMiddleware.Resolution
  alias EctoMiddleware.V1.After
  alias EctoMiddleware.V1.Before

  @doc """
  Yields execution to the next middleware in the chain.

  Returns a tuple of `{result, updated_resolution}` where the resolution may have been
  updated during middleware execution (e.g., for V1 compatibility fields like `before_output`).

  - If the result of a middleware's `process/2` function is `{:halt, value}`, execution is halted.
  - If there are no more middleware to execute, the `super` function is invoked.
  - Otherwise, execution continues to the next middleware in the chain.

  """
  @spec yield(resource :: term(), resolution :: Resolution.t()) :: {term(), Resolution.t()}
  def yield(resource, %Resolution{middleware: [], private: private} = resolution) do
    resolution = Resolution.set_before_output(resolution, resource)
    result = Map.fetch!(private, :__super__).(resource, resolution)
    unwrapped = unwrap_result(result)
    resolution = Resolution.set_after_input(resolution, unwrapped)

    {result, resolution}
  end

  def yield(resource, %Resolution{middleware: [next_middleware | rest]} = resolution) do
    {middleware_module, updated_resolution} =
      handle_v1_wrapper(next_middleware, %{resolution | middleware: rest})

    # Extract actual module name for telemetry (unwrap v1 wrappers),
    # TODO: This gets removed in v3 when v1 middleware is no longer supported
    telemetry_module =
      case middleware_module do
        {_wrapper, v1_module} -> v1_module
        module -> module
      end

    pipeline_id = Resolution.get_private(resolution, :__pipeline_id__)
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:ecto_middleware, :middleware, :start],
      %{system_time: System.system_time()},
      %{
        repo: resolution.repo,
        action: resolution.action,
        middleware: telemetry_module,
        pipeline_id: pipeline_id
      }
    )

    try do
      # Call process/2 on the actual middleware module (which might be a tuple for v1)
      result =
        case middleware_module do
          {wrapper, _v1_module} -> wrapper.process(resource, updated_resolution)
          module -> module.process(resource, updated_resolution)
        end

      result_type = (is_tuple(result) && elem(result, 0) == :halt && :halt) || :cont

      :telemetry.execute(
        [:ecto_middleware, :middleware, :stop],
        %{duration: System.monotonic_time() - start_time},
        %{
          repo: resolution.repo,
          action: resolution.action,
          middleware: telemetry_module,
          result: result_type,
          pipeline_id: pipeline_id
        }
      )

      case result do
        {:halt, value, %Resolution{} = new_resolution} ->
          {value, new_resolution}

        {:halt, value} ->
          {value, updated_resolution}

        {:cont, value, %Resolution{} = new_resolution} ->
          {value, new_resolution}

        {:cont, value} ->
          {value, updated_resolution}

        # NOTE: support returning bare values because someone
        #       might do that...
        other ->
          {other, updated_resolution}
      end
    rescue
      e ->
        :telemetry.execute(
          [:ecto_middleware, :middleware, :exception],
          %{duration: System.monotonic_time() - start_time},
          %{
            repo: resolution.repo,
            action: resolution.action,
            middleware: telemetry_module,
            kind: :error,
            reason: e,
            stacktrace: __STACKTRACE__,
            pipeline_id: pipeline_id
          }
        )

        reraise e, __STACKTRACE__
    end
  end

  # TODO: This gets removed in v3 when v1 middleware is no longer supported
  defp handle_v1_wrapper({wrapper, v1_middleware}, resolution) do
    {{wrapper, v1_middleware}, Resolution.put_private(resolution, :__v1_middleware__, v1_middleware)}
  end

  defp handle_v1_wrapper(middleware, resolution) when is_atom(middleware) do
    {middleware, resolution}
  end

  # NOTE: We need unwrapped Ecto return values for V1's `after_input` backwards compatibility
  #       In V3, we either need to support `after_input` and co, or remove them entirely.
  defp unwrap_result({:ok, value}), do: value
  defp unwrap_result({:error, _} = error), do: error
  defp unwrap_result(value), do: value

  @doc """
  Validates each middleware implements the required callbacks.

  This function is executed prior to execution of any given middleware chain to ensure
  that the specified middleware pipeline is valid.

  Note: This function also wraps any v1 middleware to be compatible with the v2 middleware
  execution engine. This functionality is temporary and will be removed in v3 when v1 middleware
  is no longer supported.
  """
  @spec validate_middleware!([term()]) :: [term()]
  def validate_middleware!(middlewares) when is_list(middlewares) do
    {normalized, _phase} =
      Enum.reduce(middlewares, {[], :before}, fn
        # TODO: This gets removed in v3 when v1 middleware is no longer supported
        EctoMiddleware.Super, {acc, :before} ->
          warn_super_deprecated()
          {acc, :after}

        # TODO: This gets removed in v3 when v1 middleware is no longer supported
        EctoMiddleware.Super, {acc, :after} ->
          {acc, :after}

        middleware, {acc, phase} ->
          wrapped =
            middleware
            |> validate_single_middleware!()
            |> wrap_v1_middleware(phase)

          {acc ++ [wrapped], phase}
      end)

    normalized
  end

  defp validate_single_middleware!(middleware) do
    # HACK: Ensure the module is loaded before checking if functions are exported
    #       When running in embedded mode (e.g., iex), modules are lazily loaded,
    #       and we get intermittent failures if we don't do this.
    #       Once a module is loaded, the cost of this should be imperceptible.
    Code.ensure_loaded!(middleware)

    valid? =
      function_exported?(middleware, :process, 2) or
        function_exported?(middleware, :process_before, 2) or
        function_exported?(middleware, :process_after, 2) or
        function_exported?(middleware, :middleware, 2)

    if !valid? do
      raise ArgumentError,
            "#{inspect(middleware)} must implement process/2, process_before/2, process_after/2, or middleware/2"
    end

    middleware
  end

  # TODO: This gets removed in v3 when v1 middleware is no longer supported
  # NOTE: v1 middleware required the callback `middleware/2` to be specified,
  #       and before/after phases were determined by relative position to `EctoMiddleware.Super`
  #       being present in the middleware list. In v2, before/after phases are explicit via
  #       `process_before/2` and `process_after/2` callbacks (or middleware executes across both
  #       phases via `process/2`).
  defp wrap_v1_middleware(middleware, phase) do
    cond do
      function_exported?(middleware, :process, 2) ->
        middleware

      function_exported?(middleware, :process_before, 2) or
          function_exported?(middleware, :process_after, 2) ->
        middleware

      function_exported?(middleware, :middleware, 2) ->
        wrapper_module = if phase == :before, do: Before, else: After
        {wrapper_module, middleware}
    end
  end

  @doc false
  def warnings_silenced? do
    Application.get_env(:ecto_middleware, :silence_deprecation_warnings, false)
  end

  defp warn_super_deprecated do
    if !warnings_silenced?() and !Process.get(:ecto_middleware_super_warned) do
      Process.put(:ecto_middleware_super_warned, true)

      IO.warn("""
      EctoMiddleware: EctoMiddleware.Super is deprecated in v2.

      In v2, you no longer need Super. Middleware can control execution flow directly:

        # Old (v1)
        def middleware(:insert, _resource) do
          [BeforeMiddleware, EctoMiddleware.Super, AfterMiddleware]
        end

        # New (v2)
        def middleware(:insert, _resource) do
          [CombinedMiddleware]  # No Super needed
        end

        defmodule CombinedMiddleware do
          use EctoMiddleware

          def process_before(resource, _resolution), do: {:cont, transform_before(resource)}
          def process_after(result, _resolution), do: {:cont, transform_after(result)}
        end

      Super will be removed in v3.0.
      """)
    end
  end
end

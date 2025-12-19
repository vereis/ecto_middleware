defmodule EctoMiddleware do
  @moduledoc """
  This module provides the `EctoMiddleware` behaviour.

  Modules can implement this behaviour to create generic middleware that can
  be used to hook into, and modify, the execution of any `Ecto.Repo` callback
  (that reads/writes to said repo).

  Users of this library can then `use EctoMiddleware.Repo` in their
  `Ecto.Repo` modules to enable middleware support.

  ## Backwards Compatibility

  Prior versions of `EctoMiddleware` (v1.x) had a different middleware contract and
  execution engine.

  For v1.x, users were expected to `use EctoMiddleware` in their `Ecto.Repo` modules
  to enable middleware support, and to define modules that implemented a single
  `middleware/2` function (notably not a behaviour callback).

  For v2.x, users are instead expected to `use EctoMiddleware.Repo` in their `Ecto.Repo`
  modules to enable middleware support, and to define middleware modules that `use
  EctoMiddleware` to implement the v2 middleware contract.

  For backwards compatibility, `EctoMiddleware` v2.x does the following:

    - If `use EctoMiddleware` is called in an `Ecto.Repo` module, it emits a deprecation
      warning and delegates to `use EctoMiddleware.Repo` instead.

    - If a middleware module implements the deprecated `middleware/2` function, it is
      automatically handled by `EctoMiddleware.Engine` by wrapping it in a v2 middleware.

  As a result, existing v1.x middleware and repos will continue to work in v2.x, but
  will emit deprecation warnings. We strongly recommend updating to the v2.x API.

  This backwards compatibility functionality will be removed in v3.0.

  ## Silencing Deprecation Warnings

  During migration from v1 to v2, you may want to silence deprecation warnings.
  This can be done via application configuration:

      # In config/config.exs
      config :ecto_middleware, :silence_deprecation_warnings, true

  This will suppress all deprecation warnings from EctoMiddleware. Note that this
  should only be used temporarily during migration - the deprecated APIs will be
  removed in v3.0.

  ## Middleware API

  `EctoMiddleware` provides two distinct APIs for writing middleware: the simple
  API and the full API.

  ### Simple API

  Middleware authors can implement either `process_before/2` or `process_after/2`
  (or both) to hook into the execution of an `Ecto.Repo` callback.

  Example:

      defmodule MyApp.Middleware.Logger do
        use EctoMiddleware

        @impl EctoMiddleware
        def process_before(changeset, _resolution) do
          Logger.debug("Before DB Operation: \#{inspect(changeset)}")
          {:cont, changeset}
        end

        @impl EctoMiddleware
        def process_after(result, _resolution) do
          Logger.debug("After DB Operation: \#{inspect(result)}")
          {:cont, result}
        end
      end

  Note that both `process_before/2` and `process_after/2` should return either
  `{:cont, value}` to continue middleware chain execution, or `{:halt, value}` to stop
  execution immediately and return `value` as the final result.

  `EctoMiddleware` also supports returning bare values for convenience, but will emit
  deprecation warnings when doing so. The mapping is as follows:

    - Returning `value` is equivalent to returning `{:cont, value}`.
    - Returning `{:ok, value}` is equivalent to returning `{:cont, {:ok, value}}`.
    - Returning `{:error, reason}` is equivalent to returning `{:halt, {:error, reason}}`.

  ### Full API

  If you need full control (e.g., for logging before and after, or conditional yielding),
  override `process/2` directly:

      defmodule MyApp.Middleware.Logger do
        use EctoMiddleware

        @impl true
        def process(resource, resolution) do
          IO.puts("Before: \#{resolution.action}")
          {result, _updated_resolution} = yield(resource, resolution)
          IO.puts("After: \#{inspect(result)}")
          result
        end
      end

  When overriding `process/2`, you must call `yield/2` to continue the chain. If you don't
  call `yield`, execution stops (implicit halt).

  Note: `yield/2` returns `{result, updated_resolution}`. The resolution may have been updated
  during execution (mostly for V1 compatibility). You need to destructure this tuple.
  """

  alias EctoMiddleware.Resolution

  # NOTE: This will be removed in v3.0
  @callback middleware(
              resource :: EctoMiddleware.Repo.resource(),
              resolution :: Resolution.t()
            ) :: EctoMiddleware.Repo.resource()

  @callback process_before(resource :: term(), resolution :: Resolution.t()) :: middleware_result()
  @callback process_after(result :: term(), resolution :: Resolution.t()) :: middleware_result()
  @callback process(resource :: term(), resolution :: Resolution.t()) :: middleware_result()

  @type middleware_result ::
          term()
          | {:cont, term()}
          | {:halt, term()}
          | {:ok, term()}
          | {:error, term()}

  @optional_callbacks middleware: 2, process_before: 2, process_after: 2, process: 2

  @doc """
  Stubs out the necessary behaviours and imports for implementing an `EctoMiddleware`
  middleware.

  For backwards compatibility, if used in an `Ecto.Repo` module, it will emit a deprecation
  warning and delegate to `use EctoMiddleware.Repo` instead. This behaviour will be removed in v3.0.
  """
  defmacro __using__(_opts) do
    quote location: :keep do
      if Module.defines?(__MODULE__, {:__adapter__, 0}) do
        use EctoMiddleware.Repo

        if !Application.compile_env(:ecto_middleware, :silence_deprecation_warnings, false) do
          IO.warn("""
          using `use EctoMiddleware` in a Repo module is deprecated.
          Please use `use EctoMiddleware.Repo` instead.
          This will be removed in v3.0.
          """)
        end
      else
        # This is a middleware module - provide v2 API helpers
        @behaviour EctoMiddleware

        import EctoMiddleware.Engine, only: [yield: 2]

        import EctoMiddleware.Resolution,
          only: [put_private: 3, get_private: 2, get_private: 3]

        @spec process_before(term(), Resolution.t()) :: {:cont, term()} | {:halt, term()}
        def process_before(resource, _resolution), do: {:cont, resource}

        @spec process_after(term(), Resolution.t()) :: {:cont, term()} | {:halt, term()}
        def process_after(result, _resolution), do: {:cont, result}

        # Dialyzer warning: These functions are defoverridable and can return {:halt, _} when
        # overridden by users, but Dialyzer only sees the default implementations which return
        # {:cont, _}. The specs correctly document the full contract.
        @dialyzer {:nowarn_function, process: 2}
        def process(resource, resolution) do
          case normalize(process_before(resource, resolution)) do
            {:cont, r} ->
              {result, updated_resolution} = yield(r, resolution)

              case normalize(process_after(result, updated_resolution)) do
                {:cont, final} -> final
                {:halt, value} -> value
              end

            {:halt, value} ->
              value
          end
        end

        @spec normalize(term() | {:cont, term()} | {:halt, term()} | {:ok, term()} | {:error, term()}) ::
                {:cont, term()} | {:halt, term()}
        # Dialyzer warning: This function handles multiple input patterns for backwards compatibility
        # and convenience (bare values, {:ok, _}, {:error, _}), but Dialyzer's pattern match analysis
        # doesn't account for all runtime possibilities. The spec correctly documents all cases.
        @dialyzer {:nowarn_function, normalize: 1}
        defp normalize({:cont, v}), do: {:cont, v}
        defp normalize({:halt, v}), do: {:halt, v}

        defp normalize({:ok, _} = ok_tuple) do
          warn_ambiguous(:ok)
          {:cont, ok_tuple}
        end

        defp normalize({:error, _} = error_tuple) do
          warn_ambiguous(:error)
          {:cont, error_tuple}
        end

        defp normalize(bare) do
          warn_bare_return()
          {:cont, bare}
        end

        @spec warn_ambiguous(atom()) :: :ok
        # Dialyzer warning: Called from normalize/1 which has nowarn due to pattern complexity
        @dialyzer {:nowarn_function, warn_ambiguous: 1}
        defp warn_ambiguous(type) do
          silenced? = EctoMiddleware.Engine.warnings_silenced?()

          if !silenced? and !Process.get({:ecto_middleware_ambiguous_warned, __MODULE__, type}) do
            Process.put({:ecto_middleware_ambiguous_warned, __MODULE__, type}, true)

            IO.warn("""
            EctoMiddleware: #{inspect(__MODULE__)} returned #{inspect(type)} tuple without explicit :cont or :halt.

            For clarity, wrap your return values:
              {:cont, #{inspect(type)}}  # to continue with this value
              {:halt, #{inspect(type)}}  # to stop the middleware chain

            Returning bare #{inspect(type)} tuples is deprecated and will be removed in v3.0.
            """)
          end

          :ok
        end

        @spec warn_bare_return() :: :ok
        # Dialyzer warning: Called from normalize/1 which has nowarn due to pattern complexity
        @dialyzer {:nowarn_function, warn_bare_return: 0}
        defp warn_bare_return do
          silenced? = EctoMiddleware.Engine.warnings_silenced?()

          if !silenced? and !Process.get({:ecto_middleware_bare_warned, __MODULE__}) do
            Process.put({:ecto_middleware_bare_warned, __MODULE__}, true)

            IO.warn("""
            EctoMiddleware: #{inspect(__MODULE__)} returned a bare value without wrapping.

            Please wrap your return values:
              {:cont, value}  # to continue
              {:halt, value}  # to stop

            Bare returns are deprecated and will be removed in v3.0.
            """)
          end

          :ok
        end

        defoverridable process_before: 2, process_after: 2, process: 2
      end
    end
  end
end

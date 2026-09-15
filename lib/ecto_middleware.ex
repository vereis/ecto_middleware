defmodule EctoMiddleware do
  @moduledoc """
  Behaviour for creating middleware that intercepts and transforms Ecto repository operations.

  EctoMiddleware provides a composable way to add cross-cutting concerns to your Ecto
  operations using a middleware pipeline pattern, similar to Plug or Absinthe middleware.

  ## Quick Example

      defmodule NormalizeEmail do
        use EctoMiddleware

        @impl EctoMiddleware
        def process_before(changeset, _resolution) do
          case Ecto.Changeset.fetch_change(changeset, :email) do
            {:ok, email} ->
              {:cont, Ecto.Changeset.put_change(changeset, :email, String.downcase(email))}
            :error ->
              {:cont, changeset}
          end
        end
      end

      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app
        use EctoMiddleware.Repo

        @impl EctoMiddleware.Repo
        def middleware(action, resource) when is_insert(action, resource) do
          [NormalizeEmail, HashPassword, AuditLog]
        end

        def middleware(_action, _resource), do: [AuditLog]
      end

  ## Core Concepts

  ### The API

  Implement `c:process_before/2` to transform data **before** the database operation:

      defmodule AddTimestamp do
        use EctoMiddleware

        @impl EctoMiddleware
        def process_before(changeset, _resolution) do
          {:cont, Ecto.Changeset.put_change(changeset, :processed_at, DateTime.utc_now())}
        end
      end

  Implement `c:process_after/2` to process data **after** the database operation:

      defmodule NotifyAdmin do
        use EctoMiddleware

        @impl EctoMiddleware
        def process_after({:ok, user} = result, _resolution) do
          Task.start(fn -> send_notification(user) end)
          {:cont, result}
        end

        def process_after(result, _resolution), do: {:cont, result}
      end

  Implement `c:process/2` to wrap around the entire operation:

      defmodule MeasureLatency do
        use EctoMiddleware

        @impl EctoMiddleware
        def process(resource, resolution) do
          start_time = System.monotonic_time()

          # Yields control to the next middleware (or Repo operation) in the chain
          # before resuming here.
          {result, _updated_resolution} = yield(resource, resolution)

          duration = System.monotonic_time() - start_time
          Logger.info("\#{resolution.action} took \#{duration}ns")

          result
        end
      end

  **Important**: When using `c:process/2`, you must call `yield/2` to continue the middleware chain.

  ### Halting Execution

  Return `{:halt, value}` to stop the middleware chain and return a value immediately:

      defmodule RequireAuth do
        use EctoMiddleware

        @impl EctoMiddleware
        def process(resource, resolution) do
          if authorized?(resolution) do
            {result, _} = yield(resource, resolution)
            result
          else
            {:halt, {:error, :unauthorized}}
          end
        end

        defp authorized?(resolution) do
          get_private(resolution, :current_user) != nil
        end
      end

  ### Guards for Operation Detection

  `EctoMiddleware.Utils` provides guards to detect operations, especially useful for `:insert_or_update`:

      defmodule ConditionalMiddleware do
        use EctoMiddleware

        @impl EctoMiddleware
        def process_before(changeset, resolution) when is_insert(changeset, resolution) do
          {:cont, add_created_metadata(changeset)}
        end

        def process_before(changeset, resolution) when is_update(changeset, resolution) do
          {:cont, add_updated_metadata(changeset)}
        end

        def process_before(changeset, _resolution) do
          {:cont, changeset}
        end
      end

  ## Return Value Conventions

  ### For `c:process_before/2` and `c:process_after/2`

  Returning bare values from middleware is supported, but to be explicit, return one of:

  - `{:cont, value}` - Continue to next middleware
  - `{:halt, value}` - Stop execution, return `value`
  - `{:cont, value, updated_resolution}` - Continue with updated `t:EctoMiddleware.Resolution.t/0`
  - `{:halt, value, updated_resolution}` - Stop with updated `t:EctoMiddleware.Resolution.t/0`

  Bare values are always treated as `{:cont, value}`.

  ## Migration from V1

  V1 middleware continue to work but emit deprecation warnings.

  Key differences:
  - Use `EctoMiddleware.Repo` instead of `EctoMiddleware` in Repo modules
  - Implement `c:process_before/2`, `c:process_after/2`, or `c:process/2` instead of the deprecated `c:middleware/2`
  - No need for `EctoMiddleware.Super` marker
  - Return `{:cont, value}` or `{:halt, value}` instead of bare values

  See the [Migration Guide](https://hexdocs.pm/ecto_middleware/migration_v1_to_v2.html) for details.

  ### Silencing Deprecation Warnings

  During migration, you can silence warnings temporarily:

      # In config/config.exs
      config :ecto_middleware, :silence_deprecation_warnings, true

  This should only be used during migration - deprecated APIs will be removed in v3.0.
  """

  alias EctoMiddleware.Resolution

  # NOTE: This will be removed in v3.0
  @callback middleware(
              resource :: EctoMiddleware.Repo.resource(),
              resolution :: Resolution.t()
            ) :: EctoMiddleware.Repo.resource()

  @callback process_before(resource :: term(), resolution :: Resolution.t()) ::
              middleware_result()
  @callback process_after(result :: term(), resolution :: Resolution.t()) :: middleware_result()
  @callback process(resource :: term(), resolution :: Resolution.t()) :: middleware_result()

  @type middleware_result ::
          term()
          | {:cont, term()}
          | {:halt, term()}
          | {:cont, term(), Resolution.t()}
          | {:halt, term(), Resolution.t()}
          | {:ok, term()}
          | {:error, term()}

  @optional_callbacks middleware: 2, process_before: 2, process_after: 2, process: 2

  @doc """
  Stubs out the necessary behaviours and imports for implementing an `EctoMiddleware`
  middleware.

  For backwards compatibility, if used in an `Ecto.Repo` module, it will emit a deprecation
  warning and delegate to `use EctoMiddleware.Repo` instead. This behaviour will be removed in v3.0.
  """
  defmacro __using__(opts) do
    handles_bulk = Keyword.get(opts, :bulk_operations, false)

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
        @behaviour EctoMiddleware

        import EctoMiddleware.Engine, only: [yield: 2]

        import EctoMiddleware.Resolution,
          only: [put_private: 3, get_private: 2, get_private: 3]

        import EctoMiddleware.Utils

        # Whether this middleware opted into running on bulk operations
        # (`insert_all/3`, `update_all/3`, `delete_all/2`). Defaults to `false` so existing
        # middleware are never silently handed a schema/source or queryable they don't expect when a Repo's
        # `middleware/2` (e.g. a catch-all clause) returns them for a bulk action.
        @doc false
        @spec __ecto_middleware_handles_bulk__() :: boolean()
        def __ecto_middleware_handles_bulk__, do: unquote(handles_bulk)

        @spec process_before(term(), Resolution.t()) :: {:cont, term()} | {:halt, term()}
        def process_before(resource, _resolution), do: {:cont, resource}

        @spec process_after(term(), Resolution.t()) :: {:cont, term()} | {:halt, term()}
        def process_after(result, _resolution), do: {:cont, result}

        # Dialyzer warning: These functions are defoverridable, but dialyzer doesn't know that
        @dialyzer {:nowarn_function, process: 2}
        # NOTE: The cont/halt orchestration lives in `EctoMiddleware.Engine.run_phases/5`
        #       (compiled once, with the phase callbacks as opaque function values) rather
        #       than being inlined here. If it were inlined, the compiler's type checker would
        #       narrow the overridden `process_before/2`/`process_after/2` return types to
        #       `{:cont, _}` for middleware that never halt and flag the `{:halt, _}` branches
        #       as dead clauses (or the tag check as a comparison between distinct types).
        def process(resource, resolution) do
          EctoMiddleware.Engine.run_phases(
            resource,
            resolution,
            &process_before/2,
            &process_after/2,
            &normalize/1
          )
        end

        @doc false
        @spec normalize(
                term()
                | {:cont, term()}
                | {:halt, term()}
                | {:cont, term(), Resolution.t()}
                | {:halt, term(), Resolution.t()}
                | {:ok, term()}
                | {:error, term()}
              ) ::
                {:cont, term()}
                | {:halt, term()}
                | {:cont, term(), Resolution.t()}
                | {:halt, term(), Resolution.t()}
        @dialyzer {:nowarn_function, normalize: 1}
        # Pass 3-tuples through untouched so a phase callback can hand back an updated
        # resolution. Without these clauses they fall to the bare-value clause below, which
        # would wrap the whole tuple as the value and warn about a bare return.
        def normalize({:cont, v, %Resolution{} = r}), do: {:cont, v, r}
        def normalize({:halt, v, %Resolution{} = r}), do: {:halt, v, r}
        def normalize({:cont, v}), do: {:cont, v}
        def normalize({:halt, v}), do: {:halt, v}

        def normalize({:ok, _} = ok_tuple) do
          warn_ambiguous(:ok)
          {:cont, ok_tuple}
        end

        def normalize({:error, _} = error_tuple) do
          warn_ambiguous(:error)
          {:cont, error_tuple}
        end

        def normalize(bare) do
          warn_bare_return()
          {:cont, bare}
        end

        @spec warn_ambiguous(atom()) :: :ok
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

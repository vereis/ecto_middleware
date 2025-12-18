defmodule EctoMiddleware.Repo do
  @moduledoc """
  Enables middleware support for `Ecto.Repo` modules.

  Add `use EctoMiddleware.Repo` to your Repo to enable middleware pipelines for
  database operations.

  ## Setup

      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app
        use EctoMiddleware.Repo

        @impl EctoMiddleware.Repo
        def middleware(action, resource) when is_insert(action, resource) do
          [NormalizeEmail, HashPassword, AuditLog]
        end

        def middleware(action, resource) when is_delete(action, resource) do
          [SoftDelete, AuditLog]
        end

        def middleware(_action, _resource) do
          [AuditLog]
        end
      end

  ## Defining Middleware

  Implement the `c:middleware/2` callback to specify which middleware run for each operation.

  ### Pattern Matching on Actions

  The first argument is the action atom (function name without arity):

      @impl EctoMiddleware.Repo
      def middleware(:insert, _), do: [ValidateEmail]

      def middleware(:get, _), do: [EnrichData]

      def middleware(:delete, _), do: [SoftDelete]

  Available actions:
  - Read: `:get`, `:get!`, `:get_by`, `:get_by!`, `:one`, `:one!`, `:all`, `:reload`, `:reload!`, `:preload`
  - Write: `:insert`, `:insert!`, `:update`, `:update!`, `:delete`, `:delete!`, `:insert_or_update`, `:insert_or_update!`

  ### Pattern Matching on Resources

  The second argument is the resource being operated on:

      # Specific schema
      def middleware(:insert, %User{}), do: [NormalizeEmail, HashPassword]

      # Multiple schemas with same middleware
      def middleware(:insert, %{__struct__: schema})
        when schema in [User, Admin], do: [AuditLog]

      # Changesets
      def middleware(:update, %Ecto.Changeset{data: %User{}}), do: [CheckOwnership]

  ### Using Guards

  You can use `EctoMiddleware.Utils` guards in your `c:middleware/2` definitions:

      @impl EctoMiddleware.Repo
      def middleware(action, resource) when is_insert(action, resource) do
        [SetCreatedAt, AuditLog]
      end

      def middleware(action, resource) when is_update(action, resource) do
        [SetUpdatedAt, AuditLog]
      end

      def middleware(_action, _resource), do: []

  See `EctoMiddleware.Utils` for available guards.

  ### Default Middleware

  Always provide a catch-all clause:

      def middleware(_action, _resource), do: []

  ## Middleware Execution

  Middleware execute in the order specified. If any middleware returns `{:halt, value}`,
  execution stops immediately.
  """

  @type action ::
          :all
          | :delete!
          | :delete
          | :get!
          | :get
          | :get_by!
          | :get_by
          | :insert!
          | :insert
          | :insert_or_update!
          | :insert_or_update
          | :one!
          | :one
          | :reload!
          | :reload
          | :preload
          | :update!
          | :update

  @type resource ::
          %{__struct__: Ecto.Queryable}
          | %{__struct__: Ecto.Changeset}
          | %{__meta__: Ecto.Schema.Metadata}
          | {%{__struct__: Ecto.Queryable}, Keyword.t()}

  @type middleware :: module()

  @callback middleware(action :: action(), resource :: resource()) :: [middleware()]

  @doc "Returns the configured middleware for the given repo."
  @spec middleware(repo :: module(), action(), resource()) :: [middleware()]
  def middleware(repo, action, resource) when is_atom(repo) do
    repo.middleware(action, resource)
  end

  @doc "Enables the ability for a given `Ecto.Repo` to define and execute middleware."
  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour EctoMiddleware.Repo

      import EctoMiddleware
      import EctoMiddleware.Utils

      alias __MODULE__, as: Self

      require EctoMiddleware
      require EctoMiddleware.Resolution, as: Resolution

      @impl EctoMiddleware.Repo
      def middleware(_action, _resource), do: []

      defoverridable middleware: 2,
                     all: 2,
                     delete!: 2,
                     delete: 2,
                     get!: 3,
                     get: 3,
                     get_by!: 3,
                     get_by: 3,
                     insert!: 2,
                     insert: 2,
                     insert_or_update!: 2,
                     insert_or_update: 2,
                     one!: 2,
                     one: 2,
                     reload!: 2,
                     reload: 2,
                     preload: 3,
                     update!: 2,
                     update: 2

      EctoMiddleware.Repo.stub_optimistic_functions!()
      EctoMiddleware.Repo.stub_ok_error_functions!()
      EctoMiddleware.Repo.stub_bang_functions!()
    end
  end

  @doc false
  defp stub_function_body(fun, arity, c) do
    import Macro

    args_list = generate_arguments(arity, c)
    super_args_list = [var(:res, c) | tl(generate_arguments(arity, c))]

    quote location: :keep do
      args = [unquote_splicing(args_list)]
      resource = List.first(args)

      pipeline_id = make_ref()
      start_time = System.monotonic_time()

      :telemetry.execute(
        [:ecto_middleware, :pipeline, :start],
        %{system_time: System.system_time()},
        %{repo: __MODULE__, action: unquote(fun), resource: resource, pipeline_id: pipeline_id}
      )

      middlewares = middleware(unquote(fun), resource)
      normalized = EctoMiddleware.Engine.validate_middleware!(middlewares)

      super_fn = fn res, _resolution ->
        super(unquote_splicing(super_args_list))
      end

      resolution =
        EctoMiddleware.Resolution.set_before_input(
          %EctoMiddleware.Resolution{
            repo: __MODULE__,
            action: unquote(fun),
            args: args,
            middleware: normalized,
            entity: resource,
            private: %{__super__: super_fn, __pipeline_id__: pipeline_id}
          },
          resource
        )

      try do
        {result, _updated_resolution} = EctoMiddleware.Engine.yield(resource, resolution)

        :telemetry.execute(
          [:ecto_middleware, :pipeline, :stop],
          %{duration: System.monotonic_time() - start_time},
          %{repo: __MODULE__, action: unquote(fun), result: result, pipeline_id: pipeline_id}
        )

        result
      rescue
        e ->
          :telemetry.execute(
            [:ecto_middleware, :pipeline, :exception],
            %{duration: System.monotonic_time() - start_time},
            %{
              repo: __MODULE__,
              action: unquote(fun),
              kind: :error,
              reason: e,
              stacktrace: __STACKTRACE__,
              pipeline_id: pipeline_id
            }
          )

          reraise e, __STACKTRACE__
      end
    end
  end

  @doc false
  defmacro stub_optimistic_functions! do
    import Macro

    c = __MODULE__

    arity_2 = [:one, :all, :reload, :reload!]
    arity_3 = [:preload, :get_by, :get]

    for {fun, arity} <- Enum.map(arity_2, &{&1, 2}) ++ Enum.map(arity_3, &{&1, 3}) do
      args_for_def = generate_arguments(arity, c)
      body = stub_function_body(fun, arity, c)

      quote location: :keep do
        def unquote(fun)(unquote_splicing(args_for_def)) do
          unquote(body)
        end
      end
    end
  end

  @doc false
  defmacro stub_ok_error_functions! do
    import Macro

    c = __MODULE__

    arity_2 = [:insert_or_update, :delete, :update, :insert]
    arity_3 = []

    for {fun, arity} <- Enum.map(arity_2, &{&1, 2}) ++ Enum.map(arity_3, &{&1, 3}) do
      args_for_def = generate_arguments(arity, c)
      body = stub_function_body(fun, arity, c)

      quote location: :keep do
        def unquote(fun)(unquote_splicing(args_for_def)) do
          unquote(body)
        end
      end
    end
  end

  @doc false
  defmacro stub_bang_functions! do
    import Macro

    c = __MODULE__

    arity_2 = [:insert_or_update!, :delete!, :one!, :update!, :insert!]
    arity_3 = [:get!, :get_by!]

    for {fun, arity} <- Enum.map(arity_2, &{&1, 2}) ++ Enum.map(arity_3, &{&1, 3}) do
      args_for_def = generate_arguments(arity, c)
      body = stub_function_body(fun, arity, c)

      quote location: :keep do
        def unquote(fun)(unquote_splicing(args_for_def)) do
          unquote(body)
        end
      end
    end
  end
end

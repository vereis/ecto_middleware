defmodule EctoMiddleware.Repo do
  @moduledoc """
  Enables middleware support for `Ecto.Repo` modules.

  To enable `EctoMiddleware`, you must `use` this module in any of your `Ecto.Repo`
  modules.

      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app
        use EctoMiddleware.Repo

        @impl EctoMiddleware.Repo
        def middleware(:insert, _resource) do
          [MyApp.Middleware.ValidateEmail, MyApp.Middleware.AuditLog]
        end

        @impl EctoMiddleware.Repo
        def middleware(_action, _resource), do: []
      end

  Once done, you will be able to customize the middleware you wish to run for any
  given `Ecto.Repo` callback.

  ## Setup and initialization

  By default, `EctoMiddleware` will not run any middleware. You must explicitly define
  them yourself.

  This is done by implementing the `middleware/2` callback in your `Ecto.Repo` module
  per the example above.

  Note that you can have different middleware for different `Ecto.Repo` callbacks by
  pattern matching on the "action" argument of the `middleware/2` callback.

  The "action" of a given `Ecto.Repo` callback is the name of the function being executed,
  without the arity. For example, the "action" of `get/3` is `get` and the "action" of
  `get!/3` is `get!`.

  You're also able to have different middleware for different "resources" by
  pattern matching on the "resource" argument of the `middleware/2` callback.

  The "resource" of a given `Ecto.Repo` is typically the first argument of the function
  being executed. For example, the "resource" of `get/3` is a module that uses
  `Ecto.Schema`.
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

    quote do
      args = [unquote_splicing(args_list)]
      resource = List.first(args)

      middlewares = middleware(unquote(fun), resource)
      normalized = EctoMiddleware.Engine.validate_middleware!(middlewares)

      super_fn = fn res, _resolution ->
        super(unquote_splicing(super_args_list))
      end

      resolution = %EctoMiddleware.Resolution{
        repo: __MODULE__,
        action: unquote(fun),
        args: args,
        middleware: normalized,
        entity: resource,
        before_input: resource,
        private: %{__super__: super_fn}
      }

      {result, updated_resolution} = EctoMiddleware.Engine.yield(resource, resolution)

      # Set after_output for V1 compatibility - this is the final result after all middleware
      # We don't use this value, but V1 middleware might inspect the resolution
      _final_resolution = %{updated_resolution | after_output: result}

      result
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

      quote do
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

      quote do
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

      quote do
        def unquote(fun)(unquote_splicing(args_for_def)) do
          unquote(body)
        end
      end
    end
  end
end

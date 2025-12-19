defmodule EctoMiddleware.Resolution do
  @moduledoc """
  Struct for holding middleware resolution data.

  ## Fields

  - `:repo` - The Repo module executing the operation
  - `:action` - The action being performed (e.g., `:insert`, `:update`, `:get`)
  - `:args` - The arguments passed to the Repo function
  - `:middleware` - The list of remaining middleware to execute
  - `:entity` - The primary entity/resource being operated on
  - `:private` - Private storage for passing data between middleware (use `put_private/3` and `get_private/2`)

  ## V1 Compatibility Fields

  The following fields are populated for backwards compatibility with V1 middleware.
  V2 middleware typically don't need to access these directly:

  - `:before_input` - The original resource before any middleware transformations
  - `:before_output` - The resource after all before middleware, right before the database operation
  - `:after_input` - The raw result from the database, before any after middleware transformations
  - `:after_output` - The final result after all after middleware transformations

  These fields are automatically populated by the execution engine and are available to
  middleware that need to inspect the execution state.
  """

  @type t :: %__MODULE__{}
  defstruct [
    :repo,
    :action,
    :args,
    :middleware,
    :entity,
    :private,
    :before_input,
    :before_output,
    :after_input,
    :after_output
  ]

  defmacro new!(args) do
    {caller, _arity} = __CALLER__.function

    quote bind_quoted: [self: __MODULE__, action: caller, args: args] do
      entity = List.first(args)

      middleware = EctoMiddleware.middleware(__MODULE__, action, entity)

      struct!(self,
        repo: __MODULE__,
        entity: entity,
        action: action,
        args: args,
        middleware: middleware
      )
    end
  end

  @doc """
  Stores a key-value pair in the resolution's private storage.

  This is useful for passing data between middleware in the chain.
  """
  @spec put_private(t(), key :: atom(), value :: term()) :: t()
  def put_private(%__MODULE__{private: private} = resolution, key, value) when is_atom(key) do
    %{resolution | private: Map.put(private || %{}, key, value)}
  end

  @doc """
  Retrieves a value from the resolution's private storage.

  Returns the value if found, otherwise returns the provided default (or nil).
  """
  @spec get_private(t(), key :: atom(), default :: term()) :: term()
  def get_private(%__MODULE__{private: private}, key, default \\ nil) when is_atom(key) do
    Map.get(private || %{}, key, default)
  end
end

defmodule EctoMiddleware.Resolution do
  @moduledoc """
  Resolution struct that tracks middleware execution context and state.

  The resolution is passed to every middleware callback and contains information about
  the current operation, remaining middleware, and provides storage for sharing data
  between middleware.

  ## Core Fields

  - `:repo` - The Repo module executing the operation (e.g., `MyApp.Repo`)
  - `:action` - The action being performed (e.g., `:insert`, `:update`, `:get`)
  - `:args` - The full arguments list passed to the Repo function
  - `:middleware` - The list of remaining middleware to execute
  - `:entity` - The primary entity/resource being operated on (changeset, struct, query, etc.)
  - `:private` - Map for passing data between middleware (use `put_private/3` and `get_private/2`)

  ## Using Private Storage

  The `:private` field is a map for storing arbitrary data that middleware need to share:

      defmodule SetContext do
        use EctoMiddleware

        def process_before(changeset, resolution) do
          resolution = put_private(resolution, :user_id, 123)
          resolution = put_private(resolution, :timestamp, DateTime.utc_now())
          {:cont, changeset, resolution}
        end
      end

      defmodule UseContext do
        use EctoMiddleware

        def process_after(result, resolution) do
          user_id = get_private(resolution, :user_id)
          timestamp = get_private(resolution, :timestamp)
          Logger.info("User \#{user_id} at \#{timestamp}")
          {:cont, result}
        end
      end

  ## Updating Resolution

  To update the resolution and pass it forward, return a 3-tuple:

      def process_before(changeset, resolution) do
        resolution = put_private(resolution, :key, :value)
        {:cont, changeset, resolution}
      end

  ## V1 Compatibility Fields (Deprecated)

  The following fields exist for V1 backwards compatibility and will be removed in v3.0:

  - `:before_input` - Original resource before middleware transformations
  - `:before_output` - Resource after before middleware, before database operation
  - `:after_input` - Raw database result before after middleware
  - `:after_output` - Final result after all middleware
  - `:before_middleware` - V1 before middleware list
  - `:after_middleware` - V1 after middleware list

  **Do not use these fields in new code.** Use `:private` storage instead.
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
    :after_output,
    :before_middleware,
    :after_middleware
  ]

  @doc """
  Stores a key-value pair in the resolution's private storage.

  This is useful for passing data between middleware in the chain.

  ## Example

      resolution = put_private(resolution, :user_id, 123)
      resolution = put_private(resolution, :context, %{tenant: "acme"})
  """
  @spec put_private(t(), key :: atom(), value :: term()) :: t()
  def put_private(%__MODULE__{private: private} = resolution, key, value) when is_atom(key) do
    %{resolution | private: Map.put(private || %{}, key, value)}
  end

  @doc false
  def set_before_input(%__MODULE__{} = resolution, value) do
    %{resolution | before_input: value}
  end

  @doc false
  def set_before_output(%__MODULE__{} = resolution, value) do
    %{resolution | before_output: value}
  end

  @doc false
  def set_after_input(%__MODULE__{} = resolution, value) do
    %{resolution | after_input: value}
  end

  @doc false
  def set_after_output(%__MODULE__{} = resolution, value) do
    %{resolution | after_output: value}
  end

  @doc """
  Retrieves a value from the resolution's private storage.

  Returns the value if found, otherwise returns the provided default (or `nil`).

  ## Examples

      user_id = get_private(resolution, :user_id)
      #=> 123

      context = get_private(resolution, :context, %{})
      #=> %{tenant: "acme"}

      missing = get_private(resolution, :missing)
      #=> nil
  """
  @spec get_private(t(), key :: atom(), default :: term()) :: term()
  def get_private(%__MODULE__{private: private}, key, default \\ nil) when is_atom(key) do
    Map.get(private || %{}, key, default)
  end
end

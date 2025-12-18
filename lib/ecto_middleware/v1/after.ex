defmodule EctoMiddleware.V1.After do
  @moduledoc false
  @behaviour EctoMiddleware

  alias EctoMiddleware.Resolution

  @doc """
  Transforms the result using the v1 middleware's middleware/2 callback.

  Only transforms Ecto schemas to match v1 behavior exactly.
  The v1 middleware module is expected to be stored in resolution.private[:__v1_middleware__].
  """
  @impl true
  def process(resource, resolution) do
    v1_middleware = Resolution.get_private(resolution, :__v1_middleware__)
    warn_deprecated(v1_middleware)

    # Call yield first to get the result (emulates yielding until `after` phase)
    {result, updated_resolution} = EctoMiddleware.Engine.yield(resource, resolution)

    transformed =
      case result do
        {:ok, inner_value} ->
          {:ok, do_after(inner_value, v1_middleware, updated_resolution)}

        {:error, _reason} = error ->
          error

        results when is_list(results) ->
          Enum.map(results, &do_after(&1, v1_middleware, updated_resolution))

        other ->
          do_after(other, v1_middleware, updated_resolution)
      end

    {:cont, transformed, updated_resolution}
  end

  # HACK: V1 middleware only supported processing Ecto schema structs (things with __meta__).
  # Non-schema values (atoms, tuples, etc.) are passed through unchanged to maintain V1 behavior.
  # This prevents V1 after middleware from crashing on non-Ecto return values.
  #
  # Additionally, if resolution.after_input is nil (which can happen with association operations),
  # skip calling the middleware to prevent crashes when v1 middleware tries to access
  # resolution.after_input.__meta__ or other fields.
  defp do_after(value, _middleware, %{after_input: nil} = _resolution) do
    value
  end

  defp do_after(value, middleware, resolution) do
    case value do
      %{__meta__: %{__struct__: Ecto.Schema.Metadata}} ->
        middleware.middleware(value, resolution)

      _other ->
        value
    end
  end

  defp warn_deprecated(middleware) do
    silenced? = EctoMiddleware.Engine.warnings_silenced?()

    if !silenced? and !Process.get({:ecto_middleware_v1_warned, middleware}) do
      require Logger

      Process.put({:ecto_middleware_v1_warned, middleware}, true)

      Logger.warning("""
      EctoMiddleware: #{inspect(middleware)} uses deprecated middleware/2 API.

      Please upgrade to the v2 API using process_before/2, process_after/2, or process/2:

        defmodule #{inspect(middleware)} do
          use EctoMiddleware

          @impl true
          def process_after(result, _resolution) do
            # Your transformation logic here
            {:cont, result}
          end
        end

      The middleware/2 API will be removed in v3.0.
      See: https://hexdocs.pm/ecto_middleware/MIGRATION_V2.html
      """)
    end
  end
end

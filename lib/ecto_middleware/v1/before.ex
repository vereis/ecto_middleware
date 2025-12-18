defmodule EctoMiddleware.V1.Before do
  @moduledoc false
  @behaviour EctoMiddleware

  alias EctoMiddleware.Resolution

  @doc """
  Transforms the resource using the v1 middleware's middleware/2 callback.

  The v1 middleware module is expected to be stored in resolution.private[:__v1_middleware__].
  """
  @impl true
  def process(resource, resolution) do
    v1_middleware = Resolution.get_private(resolution, :__v1_middleware__)
    warn_deprecated(v1_middleware)

    # Transform before calling yield
    transformed = v1_middleware.middleware(resource, resolution)

    # Do nothing else (emulates only performing work in `before` phase)
    {result, updated_resolution} = EctoMiddleware.Engine.yield(transformed, resolution)

    {:cont, result, updated_resolution}
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
          def process_before(resource, _resolution) do
            # Your transformation logic here
            {:cont, resource}
          end
        end

      The middleware/2 API will be removed in v3.0.
      See: https://hexdocs.pm/ecto_middleware/MIGRATION_V2.html
      """)
    end
  end
end

if Mix.env() == :test do
  defmodule EctoMiddleware.Test.Repo do
    @moduledoc false
    use Ecto.Repo,
      otp_app: :ecto_middleware,
      adapter: Ecto.Adapters.SQLite3

    use EctoMiddleware

    def middleware(_action, _resource) do
      Process.get(:test_middleware, [EctoMiddleware.Super])
    end

    def set_middleware(middleware_list) do
      Process.put(:test_middleware, middleware_list)
    end

    def reset_middleware do
      Process.delete(:test_middleware)
    end
  end
end

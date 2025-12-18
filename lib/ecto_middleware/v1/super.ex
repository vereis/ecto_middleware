defmodule EctoMiddleware.Super do
  @moduledoc """
  This is the deprecated `super` middleware for `EctoMiddleware` versions 1.x.

  It exists solely for backward compatibility with middleware written for v1.x.
  See documentation for `EctoMiddleware.Engine` for more details.
  """

  @behaviour EctoMiddleware

  @impl EctoMiddleware
  def middleware(resource, _state), do: resource
end

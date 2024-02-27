# EctoMiddleware

## Installation

Add `:ecto_middleware` to the list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ecto_middleware, "~> 1.0.0"}
  ]
end
```

## About

This library, when `use`-ed, allows you to configure a generic `middleware/2` in any module that has `use Ecto.Repo` within it, like so:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres

  use EctoMiddleware

  def middleware(action, _resource) when action in [:delete, :delete!] do
    [MyApp.EctoMiddleware.MaybeSoftDelete, EctoMiddleware.Super, MyApp.EctoMiddleware.Log]
  end

  def middleware(_action, _resource) do
    [EctoMiddleware.Super, MyApp.EctoMiddleware.Log]
  end
end
```

This is very much inspired by other implementations of the middleware pattern, especially [Absinthe's](https://hexdocs.pm/absinthe/Absinthe.Middleware.html).

By default, `EctoMiddleware` provides the `EctoMiddleware.Super` middleware which is responsible for actually executing any behaviour actually given to you by `Ecto.Repo`. Custom functionality can be added before, or after this `EctoMiddleware.Super` middleware to enable you to customize your repo actions accordingly.

Please see the [docs for more information](https://hexdocs.pm/ecto_middleware)!

## Example Usage

My library [EctoHooks](https://hexdocs.pm/ecto_hooks) is a small library which allows you to define `before_*` and `after_*` callbacks directly in your `Ecto.Schema`s much like the old [Ecto.Model](https://hexdocs.pm/ecto/1.0.5/Ecto.Model.html) callbacks before they were removed.

This library was re-implemented entirely to be defined as a pair of `Ecto.Middleware` middleware.

See [the callback implementations](https://github.com/vereis/ecto_hooks/tree/main/lib/ecto_hooks/middleware) for example usage!

## Links

- [hex.pm package link](https://hex.pm/packages/ecto_middleware)
- [online documentation](https://hexdocs.pm/ecto_middleware)

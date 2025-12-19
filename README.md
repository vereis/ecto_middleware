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

This library allows you to intercept and customize Ecto repository operations using a middleware pipeline pattern. Each middleware can transform data before the database operation, after it completes, or completely replace the operation.

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres

  use EctoMiddleware.Repo

  # Define middleware for specific operations
  def middleware(:insert, User), do: [EmailNormalizer, AuditLogger]
  def middleware(:delete, _resource), do: [SoftDelete]
  def middleware(_action, _resource), do: []
end

# Transform data before database operations
defmodule EmailNormalizer do
  use EctoMiddleware

  def process_before(changeset, _resolution) do
    email = Ecto.Changeset.get_field(changeset, :email)
    {:cont, Ecto.Changeset.put_change(changeset, :email, String.downcase(email))}
  end
end

# Add behavior after database operations
defmodule AuditLogger do
  use EctoMiddleware

  def process_after({:ok, user}, _resolution) do
    Logger.info("User created: #{user.id}")
    {:cont, {:ok, user}}
  end
end

# Replace operations entirely
defmodule SoftDelete do
  use EctoMiddleware

  def process(record, resolution) do
    # Instead of deleting, mark as deleted
    changeset = Ecto.Changeset.change(record, deleted_at: DateTime.utc_now())
    {:halt, resolution.repo.update(changeset)}
  end
end
```

This is inspired by [Absinthe's middleware](https://hexdocs.pm/absinthe/Absinthe.Middleware.html) and provides a clean way to add cross-cutting concerns to your Ecto operations.

**Upgrading from v1?** See the [Migration Guide](https://hexdocs.pm/ecto_middleware/migration-v2.html) for details on the new API.

Please see the [docs for more information](https://hexdocs.pm/ecto_middleware)!

## Example Usage

My library [EctoHooks](https://hexdocs.pm/ecto_hooks) is a small library which allows you to define `before_*` and `after_*` callbacks directly in your `Ecto.Schema`s much like the old [Ecto.Model](https://hexdocs.pm/ecto/1.0.5/Ecto.Model.html) callbacks before they were removed.

This library was re-implemented entirely to be defined as a pair of `Ecto.Middleware` middleware.

See [the callback implementations](https://github.com/vereis/ecto_hooks/tree/main/lib/ecto_hooks/middleware) for example usage!

## Links

- [hex.pm package link](https://hex.pm/packages/ecto_middleware)
- [online documentation](https://hexdocs.pm/ecto_middleware)

<p align="center">
  <img src="https://github.com/user-attachments/assets/26a771f6-320c-4609-ae4a-dad7477caa58" alt="EctoMiddleware" style="max-width: 100%; height: auto;" />
</p>

# EctoMiddleware

[![Hex Version](https://img.shields.io/hexpm/v/ecto_middleware.svg)](https://hex.pm/packages/ecto_middleware)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/ecto_middleware/)
[![CI Status](https://github.com/vereis/ecto_middleware/workflows/CI/badge.svg)](https://github.com/vereis/ecto_middleware/actions)
[![Coverage Status](https://coveralls.io/repos/github/vereis/ecto_middleware/badge.svg?branch=main)](https://coveralls.io/github/vereis/ecto_middleware?branch=main)

> Intercept and transform Ecto repository operations using a middleware pipeline pattern.

EctoMiddleware provides a clean, composable way to add cross-cutting concerns to your Ecto operations. Inspired by [Absinthe's middleware](https://hexdocs.pm/absinthe/Absinthe.Middleware.html) and [Plug](https://hexdocs.pm/plug), it allows you to transform data before and after database operations, or replace operations entirely.

## Features

- **Transform data** before it reaches the database (normalization, validation, enrichment)
- **Transform data** after database operations (logging, notifications, caching)
- **Replace operations** entirely (soft deletes, read-through caching, authorization)
- **Intercept batch operations** like `insert_all/3`, `update_all/3`, and `delete_all/2` (opt-in per middleware via `use EctoMiddleware, bulk_operations: true`)
- **Halt execution** with authorization checks or validation failures
- **Telemetry integration** for observability
- **Backwards compatible** with v1.x middleware

## Installation

Add `ecto_middleware` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ecto_middleware, "~> 2.0"}
  ]
end
```

## Quick Start

### 1. Enable middleware in your Repo

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres

  use EctoMiddleware.Repo

  # Define middleware for specific operations
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
```

### 2. Write middleware

```elixir
defmodule NormalizeEmail do
  use EctoMiddleware

  @impl EctoMiddleware
  def process_before(changeset, _resolution) do
    case Ecto.Changeset.fetch_change(changeset, :email) do
      {:ok, email} ->
        {:cont, Ecto.Changeset.put_change(changeset, :email, String.downcase(email))}

      :error ->
        {:cont, changeset}
    end
  end
end
```

### 3. Use your Repo as normal

```elixir
# Middleware runs automatically!

%User{}
|> User.changeset(%{name: "Alice", email: "ALICE@EXAMPLE.COM"})
|> MyApp.Repo.insert()
# => Email is normalized to "alice@example.com" before insertion
```

## Core Concepts

### The API

Implement `process_before/2` to transform data **before** the database operation:

```elixir
defmodule AddTimestamp do
  use EctoMiddleware

  @impl EctoMiddleware
  def process_before(changeset, _resolution) do
    {:cont, Ecto.Changeset.put_change(changeset, :processed_at, DateTime.utc_now())}
  end
end
```

Implement `process_after/2` to process data **after** the database operation:

```elixir
defmodule NotifyAdmin do
  use EctoMiddleware

  @impl EctoMiddleware
  def process_after({:ok, user} = result, _resolution) do
    Task.start(fn -> send_notification(user) end)
    {:cont, result}
  end

  def process_after(result, _resolution) do
    {:cont, result}
  end
end
```

Implement `process/2` to wrap around the entire operation:

```elixir
defmodule MeasureLatency do
  use EctoMiddleware

  @impl EctoMiddleware
  def process(resource, resolution) do
    start_time = System.monotonic_time()

    # Yields control to the next middleware (or Repo operation) in the chain
    # before resuming here.
    {result, _updated_resolution} = yield(resource, resolution)

    duration = System.monotonic_time() - start_time
    Logger.info("#{resolution.action} took #{duration}ns")

    result
  end
end
```

**Important**: When using `process/2`, you must call `yield/2` to continue the middleware chain.

### Halting Execution

Return `{:halt, value}` to stop the middleware chain and return a value immediately:

```elixir
defmodule RequireAuth do
  use EctoMiddleware

  @impl EctoMiddleware
  def process(resource, resolution) do
    if authorized?(resolution) do
      {result, _} = yield(resource, resolution)
      result
    else
      {:halt, {:error, :unauthorized}}
    end
  end

  defp authorized?(resolution) do
    get_private(resolution, :current_user) != nil
  end
end
```

### Guards for Operation Detection

EctoMiddleware provides guards to detect operations, especially useful for `insert_or_update`:

```elixir
defmodule ConditionalMiddleware do
  use EctoMiddleware

  @impl EctoMiddleware
  def process_before(changeset, resolution) when is_insert(changeset, resolution) do
    {:cont, add_created_metadata(changeset)}
  end

  def process_before(changeset, resolution) when is_update(changeset, resolution) do
    {:cont, add_updated_metadata(changeset)}
  end

  def process_before(changeset, _resolution) do
    {:cont, changeset}
  end
end
```

## Return Value Conventions

### `process_before/2` and `process_after/2`

Returning bare values from middleware is supported, but to be explicit, return one of:

- `{:cont, value}` - Continue to next middleware
- `{:halt, value}` - Stop execution, return `value`
- `{:cont, value, updated_resolution}` - Continue with updated resolution
- `{:halt, value, updated_resolution}` - Stop with updated resolution

Bare values are always treated as `{:cont, value}`.

## Telemetry

EctoMiddleware emits telemetry events for observability:

### Pipeline Events

- `[:ecto_middleware, :pipeline, :start]` - Pipeline execution starts
  - Measurements: `%{system_time: integer()}`
  - Metadata: `%{repo: module(), action: atom(), pipeline_id: reference()}`

- `[:ecto_middleware, :pipeline, :stop]` - Pipeline execution completes
  - Measurements: `%{duration: integer()}`
  - Metadata: `%{repo: module(), action: atom()}`

- `[:ecto_middleware, :pipeline, :exception]` - Pipeline execution fails
  - Measurements: `%{duration: integer()}`
  - Metadata: `%{repo: module(), action: atom(), kind: atom(), reason: term()}`

### Middleware Events

- `[:ecto_middleware, :middleware, :start]` - Individual middleware starts
  - Measurements: `%{system_time: integer()}`
  - Metadata: `%{middleware: module(), pipeline_id: reference()}`

- `[:ecto_middleware, :middleware, :stop]` - Individual middleware completes
  - Measurements: `%{duration: integer()}`
  - Metadata: `%{middleware: module(), result: :cont | :halt}`

- `[:ecto_middleware, :middleware, :exception]` - Individual middleware fails
  - Measurements: `%{duration: integer()}`
  - Metadata: `%{middleware: module(), kind: atom(), reason: term()}`

Example handler:

```elixir
:telemetry.attach(
  "log-slow-middleware",
  [:ecto_middleware, :middleware, :stop],
  fn _event, %{duration: duration}, %{middleware: middleware}, _config ->
    if duration > 1_000_000 do  # 1ms
      Logger.warn("Slow middleware: #{inspect(middleware)} took #{duration}ns")
    end
  end,
  nil
)
```

## Migration from V1

V1 middleware continue to work but emit deprecation warnings. See the [Migration Guide](https://hexdocs.pm/ecto_middleware/migration_v1_to_v2.html) for details.

Key differences:
- Use `EctoMiddleware.Repo` instead of `EctoMiddleware` in Repo modules
- Implement `process_before/2`, `process_after/2`, or `process/2` instead of `middleware/2`
- No need for `EctoMiddleware.Super` marker
- Return `{:cont, value}` or `{:halt, value}` instead of bare values

### Silencing Deprecation Warnings

During migration, you can silence warnings temporarily:

```elixir
# In config/config.exs
config :ecto_middleware, :silence_deprecation_warnings, true
```

This should only be used during migration - deprecated APIs will be removed in v3.0.

## Example Usage in the Wild

[**EctoHooks**](https://hex.pm/packages/ecto_hooks) - Adds `before_*` and `after_*` callbacks to Ecto schemas, similar to the old `Ecto.Model` callbacks. Implemented entirely using EctoMiddleware.

See [the implementation](https://github.com/vereis/ecto_hooks/tree/main/lib/ecto_hooks/middleware) for real-world middleware examples.

## Documentation

- [API Documentation](https://hexdocs.pm/ecto_middleware)
- [Migration Guide (v1 → v2)](https://hexdocs.pm/ecto_middleware/migration_v1_to_v2.html)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License. See [LICENSE](LICENSE) for details.

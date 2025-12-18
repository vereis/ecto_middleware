# Migrating from V1 to V2

## Overview

V2 introduces a cleaner middleware API that removes the need for `EctoMiddleware.Super` and gives middleware full control over execution flow. V1 middleware continue to work but emit deprecation warnings.

This guide will help you migrate your V1 middleware to V2. We'll use [EctoHooks](https://github.com/vereis/ecto_hooks/tree/main/lib/ecto_hooks/middleware) as a real-world example of V1 middleware.

## What V1 Middleware Looks Like

Here's a V1 middleware from EctoHooks that runs before database operations:

```elixir
defmodule EctoHooks do
  defmacro __using__(_opts) do
    quote do
      # ... other code ...
      def middleware(_action, _resource) do
        [
          EctoHooks.Middleware.Before,
          EctoMiddleware.Super,
          EctoHooks.Middleware.After
        ]
      end
    end
  end
end

defmodule EctoHooks.Middleware.Before do
  @behaviour EctoMiddleware

  @impl EctoMiddleware
  def middleware(resource, resolution) when resolution.action in [:insert, :insert!] do
    EctoHooks.before_insert(resource, resolution.action)
  end

  def middleware(resource, resolution) when resolution.action in [:update, :update!] do
    EctoHooks.before_update(resource, resolution.action)
  end

  def middleware(resource, _resolution) do
    resource
  end
end
```

V1 middleware had limitations:
- Required `EctoMiddleware.Super` to determine if a middleware is run before/after repo operation
- Couldn't halt execution cleanly
- No control over middleware flow
- Couldn't easily wrap operations (before + after in same middleware)
- Couldn't override repo action entirely

## Breaking Changes

### 1. Repo Setup

**Before (V1):**
```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app
  use EctoMiddleware  # Deprecated
end
```

**After (V2):**
```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app
  use EctoMiddleware.Repo
end
```

### 2. `yield/2` Return Value

If you're using a middleware intended to run before the repo operation, you need to make the following change:

**Before (V1):**
```elixir
def middleware(resource, resolution) do
  result = yield(resource, resolution)
  transform(result)
end
```

**After (V2):**
```elixir
@impl EctoMiddleware
def process_before(resource, resolution) do
  {result, _updated_resolution} = yield(resource, resolution)
  {:cont, transform(result)}
end
```

Ditto for after middleware:

**Before (V1):**
```elixir
def middleware(result, resolution) do
  result = yield(result, resolution)
  transform(result)
end
```

**After (V2):**
```elixir
@impl EctoMiddleware
def process_after(result, resolution) do
  {result, _updated_resolution} = yield(result, resolution)
  {:cont, transform(result)}
end
```

If your middleware is intended to ship with both before and after logic, you can now do that in a single middleware using `process/2`:

```elixir
@impl EctoMiddleware
def process(resource, resolution) do
  # Before logic
  transformed = transform_before(resource)

  # Yield to repo operation
  {result, _updated_resolution} = yield(transformed, resolution)

  # After logic
  final_result = transform_after(result)
end
```

## Migration Strategies

For most V1 middleware, you can use a simple pattern. EctoMiddleware includes V1 wrapper implementations you can reference:

- [`EctoMiddleware.V1.Before`](https://github.com/vereis/ecto_middleware/blob/main/lib/ecto_middleware/v1/before.ex) - Wraps V1 before middleware
- [`EctoMiddleware.V1.After`](https://github.com/vereis/ecto_middleware/blob/main/lib/ecto_middleware/v1/after.ex) - Wraps V1 after middleware

These show a verbose but generalizable pattern that works for any V1 middleware.

## Real-World Examples

### Example 1: Simple Transformation

**V1:**
```elixir
defmodule MyApp.Middleware.AddTimestamp do
  @behaviour EctoMiddleware

  def middleware(changeset, _resolution) do
    Ecto.Changeset.put_change(changeset, :updated_at, DateTime.utc_now())
  end
end

# In Repo:
def middleware(:update, _resource) do
  [AddTimestamp, EctoMiddleware.Super]
end
```

**V2:**
```elixir
defmodule MyApp.Middleware.AddTimestamp do
  use EctoMiddleware

  @impl EctoMiddleware
  def process_before(changeset, _resolution) do
    {:cont, Ecto.Changeset.put_change(changeset, :updated_at, DateTime.utc_now())}
  end
end

# In Repo:
@impl EctoMiddleware.Repo
def middleware(:update, _resource) do
  [AddTimestamp]  # No Super needed
end
```

### Example 2: Result Processing

**V1:**
```elixir
defmodule MyApp.Middleware.EnrichUser do
  @behaviour EctoMiddleware

  def middleware(user, _resolution) do
    %{user | full_name: "#{user.first_name} #{user.last_name}"}
  end
end

# In Repo:
def middleware(:get, User) do
  [EctoMiddleware.Super, EnrichUser]
end
```

**V2:**
```elixir
defmodule MyApp.Middleware.EnrichUser do
  use EctoMiddleware

  @impl EctoMiddleware
  def process_after({:ok, user}, _resolution) do
    {:cont, {:ok, %{user | full_name: "#{user.first_name} #{user.last_name}"}}}
  end

  def process_after(other, _resolution), do: {:cont, other}
end

# In Repo:
def middleware(:get, User) do
  [EnrichUser]  # No Super needed
end
```

### Example 3: Before + After (V2 Improvement)

**V1 (Required Two Middleware):**
```elixir
defmodule MyApp.Middleware.LogBefore do
  @behaviour EctoMiddleware
  def middleware(resource, resolution) do
    Logger.info("Before #{resolution.action}")
    resource
  end
end

defmodule MyApp.Middleware.LogAfter do
  @behaviour EctoMiddleware
  def middleware(result, resolution) do
    Logger.info("After #{resolution.action}: #{inspect(result)}")
    result
  end
end

# In Repo:
def middleware(:insert, _) do
  [LogBefore, EctoMiddleware.Super, LogAfter]
end
```

**V2 (Single Middleware):**
```elixir
defmodule MyApp.Middleware.Logger do
  use EctoMiddleware

  @impl EctoMiddleware
  def process(resource, resolution) do
    Logger.info("Before #{resolution.action}")
    {result, _updated_resolution} = yield(resource, resolution)
    Logger.info("After #{resolution.action}: #{inspect(result)}")
    result
  end
end

# In Repo:
def middleware(:insert, _) do
  [Logger]  # Single middleware!
end
```

## Return Value Conventions

### `process_before/2` and `process_after/2`

Must return `{:cont, value}` to continue or `{:halt, value}` to stop:

```elixir
def process_before(changeset, _resolution) do
  if valid?(changeset) do
    {:cont, transform(changeset)}
  else
    {:halt, {:error, :invalid}}
  end
end
```

For convenience, you can return bare values, but this will emit deprecation warnings:

```elixir
def process_before(changeset, _resolution) do
  transform(changeset)  # Works but warns
end
```

### `process/2`

Can return anything. The value you return is what gets passed up the chain:

```elixir
def process(resource, resolution) do
  {result, _} = yield(resource, resolution)
  transform(result)  # This is what the next middleware sees
end
```

Use `{:halt, value}` to explicitly signal halting (optional but recommended for clarity):

```elixir
def process(resource, resolution) do
  if should_halt?(resource) do
    {:halt, {:error, :stopped}}  # Explicit
  else
    {result, _} = yield(resource, resolution)
    result
  end
end
```

## Reference Implementations

For a complete, generalizable pattern that works for any V1 middleware, see the V1 wrapper implementations in EctoMiddleware:

- **[`EctoMiddleware.V1.Before`](https://github.com/vereis/ecto_middleware/blob/main/lib/ecto_middleware/v1/before.ex)** - Shows how V1 before middleware is wrapped in V2
- **[`EctoMiddleware.V1.After`](https://github.com/vereis/ecto_middleware/blob/main/lib/ecto_middleware/v1/after.ex)** - Shows how V1 after middleware is wrapped in V2

These implementations are verbose but demonstrate the pattern you can follow to migrate any V1 middleware. However, many middleware can be simplified by using V2's `process/2` callback instead of separate before/after middleware.

## Removed Features

### `EctoMiddleware.Super`

Not needed in V2. Just list your middleware without `Super`:

```elixir
# V1
def middleware(:insert, _resource) do
  [Before1, Before2, EctoMiddleware.Super, After1, After2]
end

# V2
def middleware(:insert, _resource) do
  [Before1, Before2, After1, After2]
end
```

### Resolution Fields (Deprecated)

The following resolution fields will be removed in v3.0:
- `before_input`
- `before_output`
- `after_input`
- `after_output`

Don't rely on these in new code. Use `resolution.private` to pass data between middleware instead.

## Silencing Deprecation Warnings

During migration, you may want to silence warnings temporarily:

```elixir
# In config/config.exs
config :ecto_middleware, :silence_deprecation_warnings, true
```

This should only be used during migration - deprecated APIs will be removed in v3.0.

## Testing Your Migration

1. Update your Repo to use `EctoMiddleware.Repo`
2. Run your test suite - V1 middleware should still work with warnings
3. Migrate middleware one at a time, running tests after each
4. Once all middleware are migrated, warnings should stop

## Need Help?

See the [API documentation](https://hexdocs.pm/ecto_middleware) for detailed examples and common patterns.

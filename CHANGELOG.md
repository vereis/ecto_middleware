# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0]

### Added

- **Bulk operation support** - `insert_all/3`, `update_all/3`, and `delete_all/2` now run
  through the middleware pipeline. Previously they bypassed it entirely.
- **Opt-in per middleware** - `use EctoMiddleware, bulk_operations: true` opts a middleware
  into bulk actions. Middleware default to `false`, and non-opted middleware are filtered
  out before middleware execution.
- `is_bulk_action/2` guard, for opted-in middleware to branch on the differing resource
  shape. `is_insert/2`, `is_update/2`, and `is_delete/2` remain scoped to single-record
  operations and intentionally do not match bulk actions; `is_write/2` still matches them.

### Migration

The Repo's `middleware/2` callback now receives bulk operations before the opt-in filter
runs. Callbacks that inspect the resource as a struct or changeset may need an explicit
bulk clause before their existing clauses:

```elixir
def middleware(action, resource) when is_bulk_action(resource, action), do: []
```

Return bulk-aware middleware instead of `[]` to enable middleware for these calls.

### Fixed

- **Resolution updates no longer stranded by the generated `process/2`.** The default
  `process/2` returned a bare value, discarding the resolution updated deeper in the chain.
  Any v2 middleware not positioned outermost therefore swallowed `before_output` and
  `after_input`, silently breaking outer middleware that read them (`ecto_hooks` dispatches
  its `after_*` hooks off `before_output`). It now returns the `{:cont | :halt, value,
  resolution}` 3-tuple that `yield/2` already accepted.
- **3-tuple returns from `process_before/2` and `process_after/2` now work.** They are
  documented as supported since 2.0.0, but `normalize/1` had no clause for them, so they
  fell through to the bare-value clause -- wrapping the whole tuple as the value and
  emitting a spurious bare-return deprecation warning.
- **`EctoMiddleware.Super` survives the bulk middleware filter.** Super is not a middleware
  but the marker `validate_middleware!/1` uses to split a v1 chain into its `:before` and
  `:after` phases. Filtering it out under a bulk opt-in predicate left that reduce stuck in
  `:before`, so an opted-in v1 middleware positioned after Super was handed the resource
  instead of the operation's result.

## [2.0.0] - 2025-12-21

### Added

- **New V2 Middleware API** with three callback options:
  - `process_before/2` - Transform data before database operations
  - `process_after/2` - Process results after database operations
  - `process/2` - Full control over middleware execution with `yield/2`
- **Halting support** - Return `{:halt, value}` to stop middleware chain execution
- **Resolution updates** - Pass updated resolution through chain with 3-tuple returns
- **Private storage** - `put_private/3` and `get_private/2` for sharing data between middleware
- **Type-safe guards** - `is_insert/2`, `is_update/2`, `is_delete/2` for operation detection
- **Telemetry integration** - Pipeline and middleware execution events with measurements
- **Comprehensive documentation** - Production-quality README, module docs, and migration guide
- **Configuration option** to silence deprecation warnings during migration
- **100% test coverage** for Utils module with 16 new guard tests
- Migration guide at `guides/migration_v1_to_v2.md`

### Changed

- **BREAKING**: `yield/2` now returns `{result, updated_resolution}` tuple (was just `result`)
- **BREAKING**: Repo setup now uses `use EctoMiddleware.Repo` (was `use EctoMiddleware`)
- Middleware execution engine completely rewritten for better composability and control
- `EctoMiddleware.Super` no longer required in middleware lists
- Return value convention changed to `{:cont, value}` / `{:halt, value}` for clarity
- Improved deprecation warnings with actionable migration guidance
- Enhanced type specifications for better Dialyzer support

### Deprecated

- V1 `middleware/2` callback (use `process_before/2`, `process_after/2`, or `process/2`)
- `EctoMiddleware.Super` middleware (no longer needed)
- `use EctoMiddleware` in Repo modules (use `use EctoMiddleware.Repo`)
- Resolution fields: `before_input`, `before_output`, `after_input`, `after_output`
- Bare return values from middleware (wrap with `{:cont, value}`)
- Ambiguous `{:ok, value}` and `{:error, reason}` returns without explicit wrapping

All deprecated features will be removed in v3.0.

### Removed

- None - full backwards compatibility maintained with V1 middleware

### Fixed

- Middleware execution order now consistent and predictable
- Better error handling and propagation through middleware chains
- Improved Dialyzer compatibility with proper specs
- Edge case handling for `insert_or_update` operations
- Documentation clarity around `Utils.apply/3` context parameter

### Migration

Existing V1 middleware continue to work with deprecation warnings. See the
[Migration Guide](https://hexdocs.pm/ecto_middleware/migration_v1_to_v2.html) for
step-by-step migration instructions.

Quick migration summary:
1. Change `use EctoMiddleware` to `use EctoMiddleware.Repo` in Repo modules
2. Update middleware to implement `process_before/2`, `process_after/2`, or `process/2`
3. Return `{:cont, value}` or `{:halt, value}` instead of bare values
4. Remove `EctoMiddleware.Super` from middleware lists
5. Destructure `yield/2` return: `{result, _} = yield(resource, resolution)`

## [1.0.0] - Previous Release

Initial stable release with v1 API.

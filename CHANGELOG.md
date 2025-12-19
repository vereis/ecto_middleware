# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - Unreleased

### Added

- New `process_before/2` callback for transforming data before database operations
- New `process_after/2` callback for transforming data after database operations  
- New `process/2` callback for full control over middleware execution
- `EctoMiddleware.Resolution` struct for tracking execution context
- Support for halting middleware chain with `{:halt, value}` returns
- Configuration option to silence deprecation warnings: `config :ecto_middleware, :silence_deprecation_warnings, true`
- Comprehensive migration guide (`MIGRATION_V2.md`)
- Quick reference guide (`V2_QUICK_REFERENCE.md`)

### Changed

- **BREAKING**: `yield/2` now returns `{result, updated_resolution}` tuple instead of just `result`
- Middleware execution engine completely rewritten for better composability
- `EctoMiddleware.Super` is no longer required in middleware lists
- Simplified middleware API - no need to manually manage execution flow
- Improved deprecation warnings with clear migration paths

### Deprecated

- V1 `middleware/2` callback (use `process_before/2`, `process_after/2`, or `process/2` instead)
- `EctoMiddleware.Super` middleware (no longer needed in v2)
- Resolution fields: `before_input`, `before_output`, `after_input`, `after_output` (will be removed in v3.0)
- Bare return values from middleware (wrap with `{:cont, value}` or `{:halt, value}`)
- Ambiguous return tuples like `{:ok, value}` (use `{:cont, {:ok, value}}` instead)

### Removed

- None (full backwards compatibility maintained)

### Fixed

- Middleware execution order now matches expectations (before → operation → after in reverse)
- Better error handling and propagation through middleware chains
- Type specs improved for better dialyzer support

### Migration

Existing v1 middleware continue to work unchanged but will emit deprecation warnings.
See `MIGRATION_V2.md` for detailed migration instructions.

## [1.0.0] - Previous Release

Initial stable release with v1 API.

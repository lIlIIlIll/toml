# Changelog

All notable changes will be documented in this file. The project has not made
a stable release.

## Unreleased

### Added

- Strict TOML 1.0 and 1.1 semantic parsing with structured diagnostics and
  resource limits.
- Deterministic semantic encoding and exact TOML temporal value types.
- Lossless document parsing, immutable revisions, atomic text and structured
  edits, formatter, and linter.
- Manual codecs and compile-time `@TomlCodec` generation without `stdx`
  DataModel or runtime field discovery.
- Optional programmatic, TOML-native, and generated schemas in separate
  packages.
- A pinned `toml-test` v2.2.0 decoder adapter, mutation/property smoke tests,
  line-coverage gates, API drift inventory, examples, and CI configuration.

### Security

- Fail-closed handling for invalid UTF-8, resource budgets, cyclic semantic
  values, nonportable integer encoding, remote schema references, and mismatched
  codec providers.

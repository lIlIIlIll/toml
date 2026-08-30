# Contributing

This repository targets Cangjie 1.1.0 and Apache-2.0-licensed, `std`-only
source. Keep changes narrow, preserve unrelated work, and add public-behavior
tests for every behavior change.

## Development setup

Put the Cangjie SDK tools on `PATH`, then run:

```bash
bash scripts/check.sh
```

The check runs the core tests, verifies both macro packages compile, exercises
the aggregate packages, runs schema tests, checks the basic example, validates
the source-level API inventory, and rejects `stdx` dependencies.

Run the quantitative gates separately:

```bash
bash scripts/coverage.sh
TOML_VERSION=1.1 bash scripts/run_toml_test.sh
TOML_VERSION=1.0 bash scripts/run_toml_test.sh
```

The conformance commands may download `toml-test` v2.2.0 through Go. Set
`TOML_TEST_BIN` to an existing runner to avoid that download.

## Change workflow

1. Add or update a scenario in `docs/testing/TEST_PLAN.md`.
2. Add the smallest focused regression test that demonstrates the behavior.
3. Implement the change without introducing `stdx` or runtime field discovery.
4. Run the focused package test, then `scripts/check.sh`.
5. Run conformance for parser changes and coverage for production-code changes.
6. Regenerate and review the API inventory when a public declaration changes.

```bash
python3 scripts/public_api_inventory.py --write
python3 scripts/public_api_inventory.py --check
```

The inventory is a source-drift guard. It is not an ABI or semantic
compatibility verdict.

## Compatibility

The project is pre-1.0, but public changes must still be intentional. Describe
source, behavior, and generated-code effects in the change. Keep generated
code against `TomlGeneratedSupportV1`; introduce a new support contract instead
of silently changing the existing one when generated output needs an
incompatible runtime contract.

## Tests and claims

Keep these evidence levels separate:

- local compilation and focused tests;
- full local acceptance checks;
- line coverage;
- external `toml-test` decoder conformance;
- hosted CI on an exact commit;
- official stable-SDK and release qualification.

Do not turn a local result into a hosted-CI or release claim. The conformance
adapter is decoder-only, and `cjcov` branch coverage is not used as a gate.

## Style

- Preserve TOML byte spans and diagnostic codes when changing recovery paths.
- Fail closed on resource limits and unsafe type boundaries.
- Keep stream ownership with callers; parser and encoder APIs must not close
  caller-owned streams, and encoders must not flush them implicitly.
- Keep schema dependencies out of the core aggregate.
- Add SPDX headers to Cangjie source files.

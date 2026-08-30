# Testing and evidence

This document records reproducible gates and the limits of each result. The
detailed scenario mapping is in [`testing/TEST_PLAN.md`](testing/TEST_PLAN.md).

## Local acceptance

```bash
bash scripts/check.sh
```

The command verifies `std`-only imports and the API inventory, then runs:

- 19 `toml` core/codec tests;
- compile checks for `toml_macros` and `toml_schema_macros`;
- one generated-codec aggregate test;
- four `toml_schema` tests;
- one generated-schema aggregate test;
- the basic executable with exact expected output.

The 2026-08-30 local run passed all 25 runtime tests. This is local evidence,
not hosted CI or stable-release acceptance.

## Decoder conformance

```bash
TOML_VERSION=1.1 bash scripts/run_toml_test.sh
TOML_VERSION=1.0 bash scripts/run_toml_test.sh
```

The script builds `tools/toml_test_adapter`, then runs the decoder protocol from
the pinned `toml-test` v2.2.0 module. Set `TOML_TEST_BIN` to use an existing
runner instead of `go run`.

The local results were:

| Mode | Valid | Invalid | Skipped |
|---|---:|---:|---:|
| TOML 1.1 | 214/214 | 467/467 | 0 |
| TOML 1.0 | 205/205 | 474/474 | 0 |

This adapter is decoder-only. The result does not certify encoder formatting,
encoder rejection behavior, or byte-for-byte round trips.

## Property and mutation smoke tests

`T019` runs 128 fixed-seed semantic encode/parse round trips. `T020` mutates
every byte in a representative fixture with seven replacement bytes and checks
the fatal-or-recoverable document invariant, exact source-byte retention, and
selected depth/token/node/key budgets.

These deterministic tests are regression gates. They are not long-duration,
coverage-guided fuzzing or a proof that every parser state is safe.

## Line coverage

```bash
bash scripts/coverage.sh
```

The script cleans coverage artifacts, rebuilds each measured package, runs its
tests with `cjpm test --coverage`, generates `cjcov` JSON/HTML under
`coverage_out`, excludes `*_test.cj`, and enforces:

| Package | Gate | Local result |
|---|---:|---:|
| `toml` | 70% | 2240/3191 (70.20%) |
| `toml_schema` | 65% | 467/714 (65.41%) |

The core manifest uses `-O2`, so `cjpm` warns that coverage should be collected
without optimization. The numbers are retained as a production-line drift
signal, not as precise branch/path coverage. `cjcov` branch reporting is
experimental and is not enabled or claimed.

## CI configuration

`.github/workflows/ci.yml` defines:

- local acceptance checks on Ubuntu, macOS, and Windows;
- the line-coverage gate on Ubuntu;
- decoder conformance for TOML 1.0 and 1.1 on Ubuntu.

Third-party actions are pinned to full commit SHAs. The workflow has not been
observed on hosted runners in this workspace, so its presence is configuration
evidence only.

## Release evidence still required

Before a stable release claim, run and retain results for the exact release
commit on official stable Cangjie SDKs and supported platforms. Investigate all
hosted CI outcomes, run longer fuzz/resource tests appropriate to the threat
model, and qualify encoder behavior separately from decoder conformance.

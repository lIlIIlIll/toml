# TOML test scenario plan

This matrix is organized around public APIs and observable behavior. TOML
1.0.0, TOML 1.1.0, and the pinned `toml-test` v2.2.0 suite are the normative
syntax references.

## Behavioral contracts

- `TomlParser` accepts `String`, UTF-8 bytes, or a caller-owned `InputStream`.
  It does not close the stream. Any error diagnostic makes semantic parsing
  fail.
- `TomlDocumentParser` returns a recovered document unless UTF-8 or resource
  processing is fatal. `semantic()` still fails while errors remain.
- `TomlEncoder` is deterministic for fixed order/options. `encodeTo` neither
  flushes nor closes a caller-owned `OutputStream`.
- Semantic containers reject cycles. Documents are immutable revisions, and
  edit batches are atomic.
- Manual and generated codecs use the same typed contracts. The generated path
  performs no runtime field discovery.
- Schema validation and default application are isolated in optional packages;
  defaults are applied to detached copies.

## Control-flow paths

| Path | Surface | Important branches |
|---|---|---|
| P001 | semantic parse | scalar, array, table, AoT, temporal, numeric |
| P002 | UTF-8 | reject, replacement warning, BOM policy |
| P003 | syntax recovery | malformed statement, later valid statement, stable diagnostics |
| P004 | version mode | TOML 1.0 versus 1.1-only syntax |
| P005 | resource policy | input, depth, key, diagnostic, token, node limits |
| P006 | semantic conflicts | duplicate key/table, dotted-key conflict, sealed inline table |
| P007 | encode | scalar, fragment, table, child table, AoT, style/version |
| P008 | encode/runtime errors | cycle, range, invalid AoT, unsupported value, stream failure |
| P009 | value isolation | deep copy, freeze/thaw, semantic/order equality |
| P010 | document/edit | spans, revisions, ID reuse, raw and structured transactions |
| P011 | codec | built-ins, collections, provider, generated/manual, policies |
| P012 | tooling | formatter preview/apply, lint diagnostics/fixes |
| P013 | schema | constraints, defaults, refs, parser, macros, budgets |
| P014 | hardening | fixed-seed properties and deterministic byte mutation |
| P015 | stream lifecycle | EOF, partial reads, read/write failure, no implicit flush |

## Input partitions

- Strings and keys: empty quoted keys, ASCII, Unicode, every escape family,
  multiline values, controls, CRLF, quote runs, and unterminated delimiters.
- Integers and floats: every radix, sign, underscore positions, leading zeroes,
  signed base rejection, Int64 boundaries, arbitrary precision, exponent,
  infinities, NaNs, signed zero, malformed separators, and range overflow.
- Temporal values: all four TOML kinds, leap days, omitted seconds in 1.1,
  offsets, exact fractions, and `DateTime` precision boundaries.
- Collections: empty, singleton, mixed, nested, trailing comma, AoT, duplicate
  values, and depth limits.
- Tables: quoted/dotted keys, implicit parents, duplicate definitions, AoT
  parents, inline sealing, insertion order, and structured-edit ambiguity.
- Schema: every supported keyword, wrong keyword type, unknown keyword/type,
  combinator cardinality, local/remote references, cycles, and budgets.

## Scenario matrix

| Scenario | Behavior | Paths | Priority |
|---|---|---|---|
| S001 | representative TOML 1.1 semantic document and order | P001 | P0 |
| S002 | explicit TOML 1.0/1.1 split | P004 | P0 |
| S003 | recovery, duplicates, and path-aware errors | P003,P006 | P0 |
| S004 | invalid UTF-8 policy and byte span | P002 | P0 |
| S005 | BigInt/Int64 and resource boundaries | P001,P005 | P0 |
| S006 | deterministic semantic encode and round trip | P007 | P0 |
| S007 | NaN/order equality and frozen isolation | P009 | P1 |
| S008 | graph cycles and nonportable encoding | P008 | P0 |
| S009 | caller-owned streams and I/O failures | P001,P008,P015 | P0 |
| S010 | source bytes, revision, handles, and reused node IDs | P010 | P0 |
| S011 | overlapping, invalid, and stale edits reject atomically | P010 | P0 |
| S012 | manual and generated record/enum codecs | P011 | P0 |
| S013 | replace/insert/upsert/remove/rename/move structured edits | P010 | P0 |
| S014 | pure formatter/linter preview and atomic fixes | P010,P012 | P1 |
| S015 | programmatic schema constraints and detached defaults | P013 | P0 |
| S016 | schema arrays, combinators, references, and budgets | P013 | P0 |
| S017 | TOML-native schema and remote-reference rejection | P013 | P0 |
| S018 | generated record, enum, and generic schemas | P013 | P1 |
| S019 | 128 fixed-seed semantic round trips | P001,P007,P014 | P1 |
| S020 | per-byte mutation smoke and resource budgets | P002,P005,P014 | P1 |
| S021 | fresh schema registries and unresolved references | P013 | P0 |
| S022 | conformance regressions for numbers/comments/dotted keys | P001,P003,P007 | P0 |
| S023 | every built-in scalar and temporal codec | P011 | P0 |
| S024 | collection codec aggregation, fail-fast, and depth | P011 | P0 |
| S025 | document wrappers, providers, support ABI, type boundary | P011 | P0 |

## Test traceability

| Test | Scenario | Package/file | Main assertions |
|---|---|---|---|
| T001-T008 | S001-S008 | `toml_core_test.cj` | semantic values, mode split, diagnostics, isolation, encode errors |
| T010-T011 | S010-S011 | `toml_core_test.cj` | exact bytes/IDs/revisions and atomic rejection |
| T012 | S012 | `src/toml_codec_test.cj` | generated/manual values and ordered errors |
| T013-T014 | S013-S014 | `toml_core_test.cj` | structured operations, formatting/lint purity |
| T015-T017 | S015-S017 | `schema_test.cj` | constraints/defaults, refs/budgets, native schema |
| T018 | S018 | `schema_macro_test.cj` | generated static schema behavior |
| T019-T020 | S019-S020 | `toml_core_test.cj` | deterministic property and mutation smoke |
| T021 | S021 | `schema_test.cj` | registry isolation and unknown reference |
| T022 | S022 | `toml_core_test.cj` | fixed conformance regressions |
| T023-T025 | S023-S025 | `codec_contract_test.cj` | built-ins, collections, wrappers/provider boundary |
| T026 | S009 | `toml_core_test.cj` | partial reads, limits, I/O diagnostics, no flush |

## Quantitative and external gates

- Core production-source line coverage: minimum 70%; local snapshot 70.20%.
- Schema production-source line coverage: minimum 65%; local snapshot 65.41%.
- `toml-test` v2.2.0 decoder, TOML 1.1: 214/214 valid and 467/467 invalid.
- `toml-test` v2.2.0 decoder, TOML 1.0: 205/205 valid and 474/474 invalid.

Coverage is a line-drift gate; optimized core instrumentation and experimental
branch coverage are not promoted as path proof. The property/mutation cases are
deterministic smoke tests, not long-duration fuzzing. Hosted CI, official stable
SDK matrices, supported-platform evidence, and independent encoder
qualification remain release-candidate gates.

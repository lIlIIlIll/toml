# TOML test scenario plan

This matrix tests only public APIs and user-observable behavior. TOML 1.0.0,
TOML 1.1.0, and the pinned `toml-test` suite are the normative specifications.

## Semantics and side effects

`TomlParser` accepts `String`, UTF-8 bytes, or a caller-owned `InputStream` and
returns `TomlOutcome<TomlTable>`. It does not close streams. Errors cause
semantic parsing to fail and preserve diagnostics. `TomlEncoder` accepts a
root table, returns deterministic text, and neither flushes nor closes a
caller-owned `OutputStream`. Mutable value containers reject cycles.

## Control-flow path matrix

| Path ID | Conditions and values | Runtime checks | Reachability | Notes |
|---|---|---|---|---|
| P001 | Valid scalar, collection, table, or AoT | bounds and UTF-8 decode | reachable | normal parse |
| P002 | Invalid UTF-8 with Reject or ReplaceInvalid | UTF-8 state machine | reachable | fatal vs warning |
| P003 | Syntax error followed by another statement | bounds and recovery cursor | reachable | diagnostics retained |
| P004 | TOML 1.0 versus 1.1-only syntax | version branch | reachable | explicit mode |
| P005 | Input, depth, key, token, node, or diagnostic limit crossed | resource counters | reachable | fail closed |
| P006 | Duplicate key/table, dotted-key conflict, sealed inline table | map membership/type match | reachable | semantic error |
| P007 | Encode scalar, array, inline table, child table, or AoT | graph depth and value kind | reachable | stable order |
| P008 | Encode cycle, nonportable integer, or stream failure | identity/range/IO | reachable | structured failure |
| P009 | Freeze, thaw, deep copy, semantic equality, ordered equality | graph walk | reachable | no alias mutation |
| P010 | Document parse and raw/incremental edit | span and revision checks | planned | 0.2 |
| P011 | Codec/manual/generated mapping | provider and field checks | planned | 0.3 |
| P012 | Edit transaction, format, lint, schema | state machine and constraints | planned | 0.4-0.5 |

## Input-domain partitioning

- Strings: empty quoted keys, ASCII, Unicode, escapes, multiline, controls,
  invalid bytes, CRLF, and unterminated delimiters.
- Integers: every radix, signs, underscores, leading zeroes, Int64 boundaries,
  and arbitrary-precision opt-in.
- Floats: fraction/exponent, signed zero, infinities, NaNs, malformed separators.
- Temporal values: four kinds, leap days, omitted seconds in 1.1, offsets, and
  arbitrary exact fractions.
- Collections: empty, singleton, nested, trailing comma, mixed values, and
  depth/resource boundaries.
- Tables: quoted/dotted keys, implicit parents, duplicate definitions, AoT
  parents, inline sealing, and insertion order.

## Semantic scenario matrix

| Scenario ID | Input | Pre-state | Triggered path IDs | Expected behavior | Required assertions | Type | Priority |
|---|---|---|---|---|---|---|---|
| S001 | representative valid TOML 1.1 document | fresh parser | P001 | semantic tree produced | exact kinds, values, and key order | normal | P0 |
| S002 | TOML 1.0 and 1.1-only escapes/time/inline syntax | two parser modes | P004 | 1.1 accepts and 1.0 rejects | outcome and diagnostic code | boundary | P0 |
| S003 | malformed statement then valid statement | fresh parser/document | P003 | semantic result fails; document later recovers | diagnostics and recovered node | error | P0 |
| S004 | invalid byte sequence | both UTF-8 policies | P002 | Reject is fatal; replacement warns | outcome, severity, span | error | P0 |
| S005 | duplicate/conflicting table definitions | fresh parser | P006 | reject with path-aware error | stable code and path | error | P0 |
| S006 | Int64 edges and one larger value | default/arbitrary modes | P001,P005 | default rejects overflow; opt-in preserves BigInt | exact integer | boundary | P0 |
| S007 | semantic tree with tables and AoT | fresh encoder | P007 | readable deterministic TOML | exact output and parse roundtrip | normal | P0 |
| S008 | NaN, signed zero, table order variants | two trees | P009 | semantic equality follows contract | equivalentTo and sameOrder | boundary | P1 |
| S009 | attach ancestor; encode over-limit integer | mutable graph/default encoder | P008 | mutation/encoding rejected | exception or diagnostic code | error | P0 |
| S010 | caller-owned streams | open streams | P001,P007,P008 | read/write without close/flush | bytes and lifecycle counters | lifecycle | P1 |
| S011 | default limits and explicit small limits | fresh parser | P005 | resource failure is deterministic | failure and limit code | error | P1 |
| S012 | freeze then thaw and mutate | mutable source | P009 | snapshots remain independent | values before/after mutation | state | P1 |
| S013 | raw document plus non-overlapping edit batch | revision N | P010 | unchanged bytes preserved and revision advances | exact bytes, IDs, revision | state | P0 |
| S014 | overlapping/stale edits | revision mismatch | P010 | atomic rejection, no mutation | diagnostic and original bytes | error | P0 |
| S015 | manual and generated codecs | configured policies | P011 | aggregate ordered errors | values, paths, diagnostic order | normal,error | P0 |
| S016 | formatter/linter/schema | valid and invalid documents | P012 | pure preview/fixes/default application | edits, no implicit mutation | normal,error | P1 |

## Test-plan matrix

| Test ID | Scenario IDs | Path IDs | Input | Expected result | Assertions | Type |
|---|---|---|---|---|---|---|
| T001 | S001 | P001 | scalar/table/AoT fixture | success | all public values and order equal | minimal |
| T002 | S002 | P004 | 1.1 escapes and omitted seconds | mode split | success/failure plus code | boundary |
| T003 | S003,S005 | P003,P006 | malformed and duplicate definitions | failure | stable diagnostics | error |
| T004 | S004 | P002 | invalid UTF-8 bytes | policy split | fatal/warning and byte span | boundary |
| T005 | S006,S011 | P001,P005 | numeric and resource boundaries | configured outcomes | exact BigInt and codes | boundary |
| T006 | S007 | P007 | nested semantic tree | stable output | exact text and roundtrip equality | minimal |
| T007 | S008,S012 | P009 | equality/freeze cases | contract preserved | semantic/order/alias assertions | state |
| T008 | S009 | P008 | ancestor attach and large integer encode | rejected | exception/diagnostic code | error |
| T009 | S010 | P001,P007,P008 | tracking streams | success/failure | lifecycle counters unchanged | lifecycle |
| T010 | S013 | P010 | valid raw edit batch | new revision | exact bytes and reused IDs | incremental |
| T011 | S014 | P010 | overlap and stale session | failure | no committed mutation | error |
| T012 | S015 | P011 | manual/derived records | mapped/failure | values and ordered paths | codec |
| T013 | S016 | P012 | format/lint/schema fixtures | preview | edits, diagnostics, purity | tooling |

## Feedback and gaps

Coverage, mutation, fuzz, and external conformance artifacts are not yet
provided, so quantitative adequacy claims are evidence-insufficient. Their
results will be mapped to the IDs above. Platform-specific stream behavior and
official stable-SDK compatibility remain external confirmation gates.

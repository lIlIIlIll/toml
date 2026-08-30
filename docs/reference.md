# Behavior and API reference

The exact source-level declaration snapshot is
[`api/public-api.txt`](../api/public-api.txt). Regenerate it with
`python3 scripts/public_api_inventory.py --write` after an intentional public
API change.

## Outcome and diagnostics

Most operations return `TomlOutcome<T>`:

- `Success(value, diagnostics)` may contain warning or info diagnostics.
- `Failure(diagnostics)` never carries a partial `T`.
- `getOrThrow()` returns the value or throws `TomlException`.

`TomlDiagnostic` has a stable code, severity, message, optional primary byte
span, labels, and optional semantic path. Positions are one-based for
`TomlPosition` and zero-based UTF-16 line/character pairs for
`TomlUtf16Position`.

## Parser contracts

| API | Input | Result | Recovery |
|---|---|---|---|
| `TomlParser.parse` / `parseToml` | `String`, UTF-8 bytes, `InputStream` | `TomlOutcome<TomlTable>` | fails if an error is reported |
| `TomlDocumentParser.parse` / `parseTomlDocument` | same | `TomlDocumentParseResult` | returns a document unless UTF-8/resource processing is fatal |
| `TomlDocument.semantic` | recovered document | `TomlOutcome<TomlTable>` | fails while document errors remain |

Input streams are read to EOF and remain caller-owned. The library does not
close them.

Default parser behavior is TOML 1.1, UTF-8 rejection, portable signed 64-bit
integers, BOM allowed, and the limits declared in `TomlLimits.defaults`.

## Semantic model

`TomlValue` has ten kinds: string, integer, float, boolean, four temporal
kinds, array, and table. Downcast helpers throw `IllegalArgumentException` on
a kind mismatch.

Tables and arrays return defensive collection copies from `keys()` and
`values()`. Child `TomlValue` objects remain mutable. Attaching an ancestor is
rejected to prevent cyclic graphs.

`TomlInteger` stores `BigInt`. `TomlFloat` stores `Float64`; semantic equality
treats NaN values as equivalent and otherwise follows `Float64` equality,
including equivalence of positive and negative zero.

## Encoder contracts

`TomlEncoder.encode` accepts a root table. `formatValue` accepts a value
fragment. `encodeBytes` returns UTF-8, and `encodeTo` writes without flushing
or closing the output.

The encoder preserves table insertion order and produces deterministic output
for fixed input and options. It fails on cycles, unsupported value
implementations, invalid array-of-table structure, excessive depth, and
integers outside the selected integer policy.

## Document and edit contracts

`TomlDocument` owns an immutable source revision, syntax tree, diagnostics, and
partial semantic root. `sourceBytes`, `text`, syntax collections, diagnostics,
and semantic roots are returned as detached values where mutation could leak.

Raw and structured edit operations validate UTF-8 byte boundaries, spans,
overlap, target ambiguity, and base revision before committing. A successful
commit returns revision `N + 1`; the original remains unchanged. Parsing is
re-run for the edited source, while syntax IDs for unchanged mapped spans are
reused when their kind and span still match.

## Codec contracts

`TomlCodec<T>` combines `TomlEncode<T>` and `TomlDecode<T>`. Built-ins cover
strings, booleans, signed and unsigned integers, `BigInt`, `Float32`,
`Float64`, all TOML temporal classes, `DateTime`, raw `TomlValue`, arrays,
`ArrayList`, string-keyed `HashMap`, and `Option`.

`TomlAnyCodec` is an opaque sealed handle. It deliberately exposes no dynamic
`Any` encode/decode operation. `TomlCodecProvider` must return the handle made
by `eraseTomlCodec` for that same provider type; `tomlCodecOf<T>` rejects a
mismatched provider with `IllegalArgumentException`.

Default codec policy rejects unknown fields, preserves exact field names,
aggregates independent errors, and limits nesting to 256.

## Formatter and linter contracts

The formatter returns text edits or a new document. The linter returns
diagnostics and non-overlapping repairs. Neither mutates the source document.
Custom lint rules implement `TomlLintRule`.

## API stability

The inventory is a deterministic source drift guard, not ABI proof. The project
is pre-release. Generated code targets the explicit
`TomlGeneratedSupportV1.abiVersion == 1` contract so runtime support changes can
be versioned instead of silently breaking existing generated source.

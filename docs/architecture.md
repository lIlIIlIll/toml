# Architecture

The repository separates the standard-library-only core from optional compile-
time and schema layers.

```text
UTF-8 text/bytes/stream
        |
        v
  parser core ---------> diagnostics + recovered statements
      |                              |
      v                              v
semantic TomlValue graph       lossless TomlDocument
      |                              |
      v                              v
deterministic encoder       edit / format / lint -> new revision

Cangjie value <-> TomlCodec<T> <-> semantic TomlValue graph

semantic TomlValue graph -> optional toml_schema validation/default copy
```

## Core package

`packages/toml` contains one parser core that builds semantic values,
diagnostics, and statement spans. `TomlParser` exposes the strict semantic
result. `TomlDocumentParser` builds the recoverable syntax/document view from
the same parse result, avoiding two parsers with diverging TOML rules.

Semantic containers are mutable and ordered. Documents are immutable. A
document edit applies a piece-based source change, reparses the resulting
bytes, and maps unchanged spans so stable syntax node IDs can be reused. This
is an incremental editing contract, not a claim that only a changed parser
region executes.

Codec providers are static. The opaque provider handle exists only to bridge a
generated or manually declared codec back to a statically typed
`TomlCodec<T>`. There is no global registry or initialization-order dependency.

## Macro packages

`toml_macros` and `toml_schema_macros` use `std.ast` at compile time. They emit
ordinary Cangjie declarations into the consuming package. Generated codecs use
the versioned `TomlGeneratedSupportV1` surface and never inspect fields at
runtime.

The macro packages are separate dependencies so applications that use only
manual APIs do not need macro expansion support.

## Schema boundary

`toml_schema` depends on `toml`, but `toml` does not depend on schema code.
Schema macros are separate again. This keeps experimental validation semantics
out of the core aggregate and prevents schema evolution from changing parser
or codec dependencies.

Schema references are resolved only through an explicit per-operation
`TomlSchemaRegistry`. No file or network resolver exists.

## Failure model

Recoverable syntax and semantic problems are values (`TomlDiagnostic`). Fatal
UTF-8/resource failures do not return a document. API precondition violations,
such as invalid spans or a codec provider returning another type's codec, throw
`IllegalArgumentException`. Caller-controlled input should otherwise flow
through `TomlOutcome` or `TomlDocumentParseResult`.

## Resource ownership

Parser instances and options are reusable and immutable. Callers retain
ownership of streams. Value and document accessors clone state where returning
internal mutable storage would violate isolation.

## Dependency rule

Production Cangjie sources may import `std.*` and sibling project packages.
They must not import `stdx.*`. `scripts/check_std_only.py` enforces this rule.

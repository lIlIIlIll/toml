# Guide

This guide covers the public workflows. See the generated
[API inventory](../api/public-api.txt) for exact declarations.

## Choose the data model

Use the semantic model when you need configuration values:

```cj
let result = parseToml("name = \"demo\"\n")
match (result) {
    case TomlOutcome<TomlTable>.Success(root, diagnostics) =>
        println(root["name"].asString().value)
    case TomlOutcome<TomlTable>.Failure(diagnostics) =>
        for (diagnostic in diagnostics) { println(diagnostic) }
}
```

Use `TomlDocument` when comments, whitespace, byte spans, recovery, or minimal
edits matter. A recoverable document can contain errors; call `semantic()` to
request an error-free semantic root.

## Select TOML 1.0 or 1.1

Strict TOML 1.1 is the default:

```cj
let v11 = parseToml(source)
let v10 = parseToml(source, options: TomlParseOptions.strict10)
```

The modes are explicit. The parser does not silently retry input under another
version.

## Configure safety limits

```cj
let limits = TomlLimits(
    maxInputBytes: 1024 * 1024,
    maxDepth: 64,
    maxKeySegments: 64,
    maxDiagnostics: 50,
    maxTokens: 100_000,
    maxNodes: 100_000
)
let options = TomlParseOptions(limits: limits)
let result = parseToml(source, options: options)
```

Crossing a limit fails closed with a structured diagnostic. Invalid UTF-8 is
fatal by default. `TomlUtf8Policy.ReplaceInvalid` keeps a recoverable document
and reports a warning.

## Work with values

`TomlTable` preserves insertion order. Integers use `BigInt` internally, but
the default parser and encoder enforce the portable signed 64-bit range. Opt
into arbitrary precision explicitly:

```cj
let parseOptions = TomlParseOptions(
    integerMode: TomlIntegerMode.ArbitraryPrecision
)
let encodeOptions = TomlEncodeOptions(
    integerMode: TomlIntegerMode.ArbitraryPrecision
)
```

`TomlArray` and `TomlTable` are mutable and reject cyclic attachment.
`deepCopy()` detaches a value graph. `freeze()` creates an immutable snapshot,
and `thaw()` returns a detached mutable graph.

Use `equivalentTo` for semantic equality and `sameOrder` when table ordering is
part of the assertion.

## Encode deterministically

```cj
let table = TomlTable()
    .put("title", TomlString("demo"))
    .put("enabled", TomlBoolean(true))

let text = encodeToml(table).getOrThrow()
```

Encoding is deterministic for a fixed value order and options. `encodeTo`
writes to a caller-owned `OutputStream` without flushing or closing it.

The exact temporal classes preserve TOML distinctions:

- `TomlOffsetDateTime`
- `TomlLocalDateTime`
- `TomlLocalDate`
- `TomlLocalTime`

Conversion to `std.time.DateTime` accepts at most nine fractional digits and
minute-precision offsets. Keep the TOML temporal value when greater source
precision must remain exact.

## Apply raw edits atomically

```cj
let document = parseTomlDocument(source).getOrThrow()
let batch = TomlEditBatch(document.revision)
    .replace(TomlSpan(0, 5), "title")
let updated = document.apply(batch).getOrThrow()
```

Every span uses UTF-8 byte offsets. A batch fails as a unit if spans overlap,
split UTF-8 sequences, exceed bounds, use a stale revision, or produce a fatal
parse result.

## Apply structured edits

```cj
let path = TomlPath().withKey("server").withKey("port")
let session = document.beginEdit()
let _ = session.upsertValue(path, TomlInteger(9090), createParents: true)
    .getOrThrow()
let updated = session.commit().getOrThrow()
```

Available operations replace, insert, upsert, remove, rename, and move values.
A session has one base revision and can be committed or cancelled once.

## Format and lint

```cj
let formatter = TomlFormatter(style: TomlStyle.canonical)
let edits = formatter.preview(document).getOrThrow()
let formatted = formatter.apply(document).getOrThrow()

let lint = TomlLinter().lint(document)
if (lint.hasFixes) {
    let fixed = TomlLinter().applyFixes(document).getOrThrow()
}
```

Preview, lint, and formatting do not mutate the input document. Fixes are
applied as one validated edit batch. Formatting requires a document without
TOML errors.

## Use manual codecs

A manual codec implements `TomlCodec<T>`:

```cj
class PortCodec <: TomlCodec<Int64> {
    public func encode(value: Int64, context: TomlEncodeContext): TomlOutcome<TomlValue> {
        TomlCodecs.int64.encode(value, context)
    }

    public func decode(value: TomlValue, context: TomlDecodeContext): TomlOutcome<Int64> {
        TomlCodecs.int64.decode(value, context)
    }
}
```

Compose codecs with `array`, `arrayList`, `stringMap`, and `option`. Codec
diagnostics retain a `TomlPath`; aggregate mode reports independent field or
element failures in stable traversal order.

## Generate codecs

`@TomlCodec` supports classes, structs, and payload-free enums. It emits a
`<Type>Toml` codec and a static provider for non-open records.

- `@TomlName["wire_name"]` changes a field or enum wire name.
- `@TomlUsing[expression]` supplies an explicit field codec.
- `@TomlIgnore` excludes a field.
- `@TomlDefault` uses the field initializer when the input omits the field.
- `@TomlFlatten` merges an object codec into its parent table.

An absent `Option<T>` record field decodes as `None`; encoding `None` as a
standalone TOML value is rejected because TOML has no null value.

Generated code does not inspect runtime fields. It depends only on the core
API and `TomlGeneratedSupportV1`.

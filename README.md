# toml

A pre-release TOML library for Cangjie 1.1. It provides strict TOML 1.0 and
1.1 parsing, deterministic semantic encoding, a lossless revisioned document
model, typed codecs, structured edits, formatting, linting, and an optional
schema package.

[中文说明](README_zh.md)

The implementation uses `std` only. It does not depend on `stdx`,
`stdx.serialization.DataModel`, reflection-based field discovery, or a global
codec registry.

## Status

The manifests currently report version `0.1.0`, but no stable release is
claimed. Public APIs can still change.

The local evidence snapshot from 2026-08-30 is:

- 25 focused tests passed across core, generated codecs, schema, and schema
  macros.
- The `toml-test` v2.2.0 decoder suite passed for TOML 1.1 (214 valid and 467
  invalid cases) and TOML 1.0 (205 valid and 474 invalid cases).
- Production-source line coverage was 70.20% for `toml` and 65.41% for
  `toml_schema`.

The GitHub Actions workflow has not been observed on hosted runners in this
workspace. Official stable-SDK and multi-platform acceptance therefore remain
pending.

## Requirements

- Cangjie SDK 1.1.0
- `cjpm`
- Bash and Python 3 for repository checks
- Go 1.19 or newer, or an installed `toml-test`, for external conformance tests

## Add the package

The project is not published to a package registry. Use path dependencies from
your checkout:

```toml
[dependencies]
toml = { path = "../toml/packages/toml" }
```

Add `toml_macros` as a second dependency when using `@TomlCodec`.

## Parse and encode

```cj
import toml.*

main(): Int64 {
    let source = "title = \"demo\"\n[server]\nport = 8080\n"
    let root = Toml.parse(source).getOrThrow()

    println(root["title"].asString().value)
    println(root["server"].asTable()["port"].asInteger().value)

    let encoded = Toml.encode(root).getOrThrow()
    println(encoded)
    0
}
```

Parsing defaults to strict TOML 1.1. Select TOML 1.0 explicitly with
`TomlParseOptions.strict10`. Semantic parsing fails when any error diagnostic
is present; use the document API when recovery and source preservation matter.

## Edit without rewriting unrelated text

```cj
let document = parseTomlDocument(source).getOrThrow()
let port = TomlPath().withKey("server").withKey("port")
let session = document.beginEdit()
let _ = session.replaceValue(port, TomlInteger(9090)).getOrThrow()
let edited = session.commit().getOrThrow()

println(edited.text())
```

Documents are immutable revisions. Edit batches are atomic, stale revisions
are rejected, and unchanged syntax nodes retain stable IDs when possible.

## Derive a typed codec

```cj
import toml.*
import toml_macros.*

@TomlCodec
struct ServerConfig {
    @TomlName["listen_port"]
    public let port: Int64
    public let host: Option<String>

    public init(port: Int64, host: Option<String>) {
        this.port = port
        this.host = host
    }
}

let text = encodeTomlWith(
    ServerConfig(8080, Some("127.0.0.1")),
    ServerConfigToml
).getOrThrow()
```

The macro emits ordinary Cangjie source against the versioned
`TomlGeneratedSupportV1` contract. Manual codecs implement `TomlCodec<T>` and
use the same behavior and diagnostics.

## Packages

- `toml`: semantic model, parser, encoder, document/edit APIs, codecs,
  formatter, and linter.
- `toml_macros`: compile-time typed-codec generation.
- `toml_all`: aggregate package that re-exports `toml`; import
  `toml_macros.*` separately for macros.
- `toml_schema`: optional experimental schema model, parser, validation, and
  default application.
- `toml_schema_macros`: compile-time schema generation.
- `toml_schema_all`: schema aggregate package.

## Verify a checkout

Run these commands inside an environment where the Cangjie SDK tools are on
`PATH`:

```bash
bash scripts/check.sh
bash scripts/coverage.sh
TOML_VERSION=1.1 bash scripts/run_toml_test.sh
TOML_VERSION=1.0 bash scripts/run_toml_test.sh
```

The conformance adapter is decoder-only. A passing decoder suite does not
qualify encoder formatting or byte-for-byte round trips.

## Documentation

- [Guide](docs/guide.md)
- [Behavior and API reference](docs/reference.md)
- [Architecture](docs/architecture.md)
- [Schema package](docs/schema.md)
- [Testing and evidence](docs/testing.md)
- [Public API inventory](api/public-api.txt)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

Apache License 2.0. See [LICENSE](LICENSE).

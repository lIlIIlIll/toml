# Schema package

`toml_schema` is optional and experimental. It is not part of the core
`toml_all` behavior contract. Add it only when validation or default
application is required:

```toml
[dependencies]
toml = { path = "../toml/packages/toml" }
toml_schema = { path = "../toml/packages/toml_schema" }
```

## Programmatic schemas

```cj
import std.math.numeric.BigInt
import toml.*
import toml_schema.*

let schema = TomlSchema.table()
    .property(
        "port",
        TomlSchema.integer()
            .minimumInteger(BigInt(1))
            .maximumInteger(BigInt(65535)),
        required: true
    )
    .property("host", TomlSchema.string().withDefault(TomlString("localhost")))
    .additionalProperties(false)

let value = parseToml("port = 8080\n").getOrThrow()
let validation = schema.validate(value)
let defaulted = schema.validateAndApplyDefaults(value).getOrThrow()
```

Validation does not mutate the input. Default application returns a detached
copy and validates the resulting value.

Supported constraints include kinds, required and additional properties,
array items and lengths, unique items, integer/float ranges, string lengths,
constant and enum values, `allOf`, `anyOf`, `oneOf`, defaults, and local
references.

## TOML-native schema documents

Schemas can themselves be expressed as TOML:

```toml
type = "table"
required = ["port"]
additionalProperties = false

[properties.port]
ref = "#/definitions/positive"

[properties.host]
type = "string"
minLength = 1
default = "localhost"

[definitions.positive]
type = "integer"
minimum = 1
maximum = 65535
```

Parse and use the schema with:

```cj
let schemaValue = parseToml(schemaSource).getOrThrow()
let schemaDocument = TomlSchemaDocument.fromToml(schemaValue).getOrThrow()
let validation = schemaDocument.validate(configuration)
```

Recognized keywords are `type`, `properties`, `required`,
`additionalProperties`, `items`, `minimum`, `maximum`, `exclusiveMinimum`,
`exclusiveMaximum`, `minLength`, `maxLength`, `minItems`, `maxItems`,
`uniqueItems`, `default`, `const`, `enum`, `allOf`, `anyOf`, `oneOf`, `ref`,
`$ref`, `description`, and top-level `definitions`.

Types are `string`, `integer`, `float`/`number`, `boolean`/`bool`,
`offset-date-time`, `local-date-time`, `local-date`, `local-time`, `array`, and
`table`/`object`.

## References

Only named local references are supported:

- `positive`
- `#/definitions/positive`
- `#/$defs/positive`

URLs, file references, arbitrary fragments, and paths are rejected. A
`TomlSchemaRegistry` belongs to the caller and is passed explicitly. Every call
to `TomlSchemaRegistry.empty()` returns a fresh registry.

## Generated schemas

Add `toml_schema_macros` and annotate a class, struct, or payload-free enum:

```cj
import toml_schema.*
import toml_schema_macros.*

@TomlSchema
struct ServiceConfig {
    @TomlSchemaName["listen_port"]
    public let port: Int64
    public let host: Option<String>

    public init(port: Int64, host: Option<String>) {
        this.port = port
        this.host = host
    }
}

let validation = ServiceConfigTomlSchema.validate(configuration)
```

`@TomlSchemaIgnore` excludes a field. `@TomlSchemaOptional` removes the
required-field constraint even for a non-`Option` field. Generated schemas are
static declarations and do not depend on runtime field reflection.

## Budgets and diagnostics

`TomlSchemaLimits` bounds validation depth, node visits, diagnostics, and
reference depth. Budget exhaustion reports `schema_budget_exceeded`. Invalid
schema documents fail with path-aware diagnostics instead of partially
activating unsupported keywords or references.

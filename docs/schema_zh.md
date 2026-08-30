# Schema 包

`toml_schema` 是独立、可选、实验性的包，不属于 core aggregate 的稳定行为边界。

## 编程式 schema

```cj
let schema = TomlSchema.table()
    .property("port", TomlSchema.integer()
        .minimumInteger(BigInt(1)).maximumInteger(BigInt(65535)), required: true)
    .property("host", TomlSchema.string().withDefault(TomlString("localhost")))
    .additionalProperties(false)

let validation = schema.validate(configuration)
let copied = schema.validateAndApplyDefaults(configuration).getOrThrow()
```

校验不修改输入。默认值应用返回脱离输入的副本，并校验结果。支持 kind、required、额外属性、
array items/长度/唯一性、整数和浮点范围、字符串长度、const/enum、`allOf`/`anyOf`/`oneOf`、
default 和本地引用。

## TOML-native schema

支持 `type`、`properties`、`required`、`additionalProperties`、`items`、`minimum`、`maximum`、
exclusive 边界、长度限制、`uniqueItems`、`default`、`const`、`enum`、三个组合器、`ref`/`$ref`、
`description` 和顶层 `definitions`。

引用只允许名称、`#/definitions/name` 或 `#/$defs/name`。URL、文件引用、任意 fragment 和路径
会被拒绝。`TomlSchemaRegistry.empty()` 每次都返回全新的 registry。

## 生成 schema

`@TomlSchema` 支持 class、struct 和无 payload enum，生成 `<Type>TomlSchema`。
`@TomlSchemaName` 修改字段名，`@TomlSchemaIgnore` 忽略字段，`@TomlSchemaOptional` 取消非
`Option` 字段的 required 约束。生成代码不依赖运行时字段反射。

`TomlSchemaLimits` 限制深度、访问次数、diagnostic 和引用深度；耗尽预算时报告
`schema_budget_exceeded`。

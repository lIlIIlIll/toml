# 使用指南

精确声明见生成的[公开 API 清单](../api/public-api.txt)。

## 选择语义模型或文档模型

只关心配置值时使用语义模型：

```cj
let root = parseToml("name = \"demo\"\n").getOrThrow()
println(root["name"].asString().value)
```

需要保留注释、空白、字节 span、错误恢复或最小编辑时，使用 `TomlDocument`。可恢复文档允许
包含错误；`semantic()` 只会在没有 error diagnostic 时返回完整语义根。

## 版本与资源限制

默认严格解析 TOML 1.1。TOML 1.0 必须显式选择：

```cj
let v10 = parseToml(source, options: TomlParseOptions.strict10)
```

通过 `TomlLimits` 限制输入字节数、深度、key 段数、diagnostic、token 和 node。超过限制时
会 fail closed。无效 UTF-8 默认 fatal；`TomlUtf8Policy.ReplaceInvalid` 会保留可恢复文档并报告 warning。

## 值与编码

`TomlTable` 保留插入顺序，`TomlInteger` 内部保存 `BigInt`。默认 parser/encoder 只接受可移植
的有符号 64 位整数；需要任意精度时，分别在 parse/encode options 中选择
`TomlIntegerMode.ArbitraryPrecision`。

`TomlArray` 和 `TomlTable` 可变，但拒绝形成环。`deepCopy()` 返回脱离原图的副本；
`freeze()`/`thaw()` 用于不可变快照。固定输入顺序和 options 下，语义 encoder 输出确定。

`encodeTo` 不会 flush 或 close 调用方提供的 `OutputStream`。

## 原子编辑

```cj
let document = parseTomlDocument(source).getOrThrow()
let path = TomlPath().withKey("server").withKey("port")
let session = document.beginEdit()
let _ = session.upsertValue(path, TomlInteger(9090), createParents: true)
    .getOrThrow()
let updated = session.commit().getOrThrow()
```

raw edit 的 span 是 UTF-8 字节偏移。重叠、切断 UTF-8、越界、过期 revision 或产生 fatal 解析
结果时，整个批次失败。结构化 edit 支持 replace、insert、upsert、remove、rename 和 move。

## 格式化与 lint

`TomlFormatter.preview` 返回 edit，`apply` 返回新 revision。`TomlLinter` 返回 diagnostic 和可选
修复。它们都不修改输入文档，修复以单个已校验 edit batch 原子应用。存在 TOML 错误的文档
不能格式化。

## 手写与生成 codec

手写 codec 实现 `TomlCodec<T>`。`TomlCodecs` 提供标量、时间、数组、`ArrayList`、字符串 key
的 `HashMap` 和 `Option` 组合器。diagnostic 会保留 `TomlPath`，aggregate 模式按稳定遍历顺序
收集独立错误。

`@TomlCodec` 支持 class、struct 和无 payload enum，并生成 `<Type>Toml`：

- `@TomlName["wire_name"]` 修改 wire 名称；
- `@TomlUsing[expression]` 指定字段 codec；
- `@TomlIgnore` 忽略字段；
- `@TomlDefault` 在缺失字段时使用初始化表达式；
- `@TomlFlatten` 把对象字段合并到父 table。

生成代码只依赖 `TomlGeneratedSupportV1`，不在运行时扫描字段，也不依赖 DataModel。

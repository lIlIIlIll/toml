# 行为与 API 参考

精确公开声明见 [`api/public-api.txt`](../api/public-api.txt)。有意修改公开声明后执行：

```bash
python3 scripts/public_api_inventory.py --write
```

该清单是源码漂移门禁，不是 ABI 或语义兼容性结论。

## Outcome 与 diagnostic

大多数操作返回 `TomlOutcome<T>`。`Success` 可以携带 warning/info；`Failure` 不携带部分 `T`；
`getOrThrow()` 在失败时抛出包含 diagnostic 的 `TomlException`。

`TomlDiagnostic` 包含稳定 code、severity、message，以及可选的主字节 span、label 和语义 path。

## Parser

- `TomlParser`/`parseToml` 返回严格语义结果，出现 error 即失败。
- `TomlDocumentParser`/`parseTomlDocument` 在 UTF-8/资源处理不 fatal 时返回可恢复文档。
- `TomlDocument.semantic()` 仅在文档无 error 时成功。
- `InputStream` 读到 EOF，但所有权仍属于调用方，库不会 close。

## 模型与 encoder

模型包含字符串、整数、浮点、布尔、四种 TOML 时间、数组和 table。table/array 的集合访问器
返回集合副本，但其中的子 `TomlValue` 仍可变。encoder 保留 table 插入顺序，拒绝环、非法 AoT、
超深结构、未知 value 实现和超出所选整数策略的值。

`encodeTo` 不 flush、不 close 输出流。

## 文档与 edit

`TomlDocument` 是不可变 revision。edit 在提交前校验字节边界、span、重叠、目标歧义和基线
revision。成功提交得到 `N + 1`，原文档不变。编辑后会重新解析完整文本，并为 kind/span 仍匹配
的未变节点复用 ID。

## Codec

`TomlCodec<T>` 合并 encode/decode。`TomlAnyCodec` 是 sealed opaque handle，不公开对任意 `Any`
做动态转换的入口。provider 必须返回由同一类型 codec 创建的 handle；类型不匹配会抛
`IllegalArgumentException`。

默认 codec 策略拒绝未知字段、保留字段原名、聚合独立错误，并把嵌套深度限制为 256。

项目仍为预发布。生成代码显式面向 `TomlGeneratedSupportV1.abiVersion == 1`，以便将未来不兼容
的运行时支持作为新版本契约处理。

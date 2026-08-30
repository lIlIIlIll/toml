# toml

面向仓颉 1.1 的预发布 TOML 库。它提供严格的 TOML 1.0/1.1 解析、确定性的语义编码、
保留源码的版本化文档模型、类型化 codec、结构化编辑、格式化、lint，以及独立可选的
schema 包。

[English](README.md)

实现只依赖 `std`，不依赖 `stdx`、`stdx.serialization.DataModel`、基于反射的字段发现，
也不使用进程级 codec 注册表。

## 当前状态

清单中的版本是 `0.1.0`，但目前不宣称稳定发布，公开 API 仍可能调整。

截至 2026-08-30 的本地证据为：

- core、生成 codec、schema 和 schema macro 共 25 个聚焦测试通过。
- `toml-test` v2.2.0 decoder 套件全部通过：TOML 1.1 为 214 个 valid、467 个 invalid；
  TOML 1.0 为 205 个 valid、474 个 invalid。
- 生产源码行覆盖率：`toml` 70.20%，`toml_schema` 65.41%。

当前工作区尚未观察到托管 GitHub Actions 的执行结果，因此正式稳定 SDK 和多平台验收仍待完成。

## 环境要求

- 仓颉 SDK 1.1.0
- `cjpm`
- 仓库检查需要 Bash 和 Python 3
- 外部一致性测试需要 Go 1.19+，或者已安装的 `toml-test`

## 引入依赖

项目尚未发布到包仓。请从本地 checkout 使用路径依赖：

```toml
[dependencies]
toml = { path = "../toml/packages/toml" }
```

使用 `@TomlCodec` 时，再加入 `toml_macros` 依赖。

## 解析与编码

```cj
import toml.*

main(): Int64 {
    let source = "title = \"demo\"\n[server]\nport = 8080\n"
    let root = Toml.parse(source).getOrThrow()

    println(root["title"].asString().value)
    println(root["server"].asTable()["port"].asInteger().value)

    println(Toml.encode(root).getOrThrow())
    0
}
```

默认使用严格 TOML 1.1。需要 TOML 1.0 时显式传入 `TomlParseOptions.strict10`。
语义解析只要出现 error diagnostic 就会失败；需要错误恢复和源码保留时，请使用文档 API。

## 保留无关文本的编辑

```cj
let document = parseTomlDocument(source).getOrThrow()
let port = TomlPath().withKey("server").withKey("port")
let session = document.beginEdit()
let _ = session.replaceValue(port, TomlInteger(9090)).getOrThrow()
let edited = session.commit().getOrThrow()

println(edited.text())
```

文档是不可变 revision。编辑批次原子提交，过期 revision 会被拒绝，未受影响的语法节点会尽量复用 ID。

## 生成类型化 codec

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

macro 会针对版本化的 `TomlGeneratedSupportV1` 契约生成普通仓颉源码。手写 codec 实现
`TomlCodec<T>`，与生成代码共享相同的行为和 diagnostic。

## 包结构

- `toml`：语义模型、parser、encoder、文档/编辑 API、codec、formatter 和 linter。
- `toml_macros`：编译期类型化 codec 生成。
- `toml_all`：重导出 `toml` 的聚合包；macro 仍需单独 `import toml_macros.*`。
- `toml_schema`：可选、实验性的 schema、解析、校验和默认值应用。
- `toml_schema_macros`：编译期 schema 生成。
- `toml_schema_all`：schema 聚合包。

## 验证 checkout

请先确保仓颉 SDK 工具已在 `PATH` 中：

```bash
bash scripts/check.sh
bash scripts/coverage.sh
TOML_VERSION=1.1 bash scripts/run_toml_test.sh
TOML_VERSION=1.0 bash scripts/run_toml_test.sh
```

一致性适配器只测试 decoder。decoder 通过不等于 encoder 格式或逐字节 round trip 已完成认证。

## 文档

- [使用指南](docs/guide_zh.md)
- [行为与 API 参考](docs/reference_zh.md)
- [架构](docs/architecture_zh.md)
- [Schema 包](docs/schema_zh.md)
- [测试与证据](docs/testing_zh.md)
- [公开 API 清单](api/public-api.txt)
- [贡献指南](CONTRIBUTING.md)
- [安全策略](SECURITY.md)

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。

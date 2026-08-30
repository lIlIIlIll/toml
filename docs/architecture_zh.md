# 架构

```text
UTF-8 文本/字节/流
        |
        v
  parser core -------> diagnostic + 可恢复 statement
      |                              |
      v                              v
语义 TomlValue 图                TomlDocument
      |                              |
      v                              v
确定性 encoder            edit / format / lint -> 新 revision

仓颉值 <-> TomlCodec<T> <-> TomlValue
TomlValue -> 独立 toml_schema 校验/默认值副本
```

`packages/toml` 只有一套 parser core，同时生成语义值、diagnostic 和 statement span。
严格语义 API 与可恢复文档 API 因此不会维护两套 TOML 规则。

语义容器可变且有序，文档不可变。edit 使用 piece 方式生成新源码、重新解析，并映射未变化 span
以复用语法 node ID。这里的“增量”是编辑和 identity 契约，不表示 parser 只执行局部区域。

`toml_macros` 和 `toml_schema_macros` 在编译期使用 `std.ast`，输出普通仓颉声明。codec provider
是静态的 opaque handle，不使用全局注册表或运行时字段反射。

`toml_schema` 依赖 `toml`，反向依赖不存在。schema registry 由调用方显式持有，只解析本地命名
引用，不进行文件或网络访问。

生产源码只能依赖 `std.*` 和仓库内 sibling package；`scripts/check_std_only.py` 拒绝
`stdx.*` import。

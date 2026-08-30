# 测试与证据

详细场景映射见 [`testing/TEST_PLAN.md`](testing/TEST_PLAN.md)。

## 本地验收

```bash
bash scripts/check.sh
```

该门禁校验 std-only import 和 API 清单，并运行 core/codec、生成 codec、schema、生成 schema
测试和 basic example。截至 2026-08-30，本地 25 个运行时测试全部通过；这不是托管 CI 或稳定
发布证据。

## Decoder 一致性

```bash
TOML_VERSION=1.1 bash scripts/run_toml_test.sh
TOML_VERSION=1.0 bash scripts/run_toml_test.sh
```

固定使用 `toml-test` v2.2.0。本地结果：TOML 1.1 valid 214/214、invalid 467/467；
TOML 1.0 valid 205/205、invalid 474/474；均无 skip。适配器只覆盖 decoder，不能据此宣称
encoder 或逐字节 round trip 已通过认证。

## Property、mutation 与覆盖率

`T019` 使用固定 seed 执行 128 次语义 encode/parse round trip。`T020` 对代表 fixture 的每个
字节应用 7 种替换，并检查 fatal/可恢复不变量、源码字节保留和多个资源预算。这是确定性 smoke，
不是长时间 coverage-guided fuzzing。

```bash
bash scripts/coverage.sh
```

行覆盖率门禁为 core 70%、schema 65%；本地结果分别为 2240/3191（70.20%）和
467/714（65.41%）。core 以 `-O2` 编译，因此 `cjpm` 会提示 coverage 不应优化；这些数字只作为
生产源码行漂移信号，不宣称精确 branch/path coverage。实验性的 cjcov branch coverage 未启用。

GitHub Actions 已配置三平台本地验收、Linux 覆盖率和 TOML 1.0/1.1 decoder 一致性，但当前
工作区没有托管 runner 结果。稳定发布前仍需在精确 release commit 上完成正式 SDK、多平台、
更长 fuzz/资源测试及独立 encoder 资格验证。

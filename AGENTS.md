# AGENTS.md

## 范围与参考

- 先阅读 `README.md`、`CONTRIBUTING.md`、`docs/testing/TEST_PLAN.md` 和当前任务。项目处于 pre-1.0，仍须明确记录所有公共行为变动及生成代码 ABI 影响。
- 严格区分 TOML 1.0 与 1.1 语义、确定性语义编码、lossless document/source spans、revisioned edit、typed codec、schema 扩展和流接口。核心必须只使用 `std`，不引入 `stdx` 或运行时反射。
- 宏生成结果必须遵循 `TomlGeneratedSupportV1` 已定义的运行时边界；不因一个反例降低资源预算、诊断精度、原文保留或原子编辑保证。

## 证据与验证

- 行为变化先更新 `docs/testing/TEST_PLAN.md` 并增加定向回归测试；根据受影响范围运行 `bash scripts/check.sh`、`TOML_VERSION=1.1 bash scripts/run_toml_test.sh`、`TOML_VERSION=1.0 bash scripts/run_toml_test.sh` 与 `bash scripts/coverage.sh`。
- 公共 API 变动使用 `python3 scripts/public_api_inventory.py --check` 验证；其结果仅是源码漂移检查，不是 ABI/语义兼容的完整证明。
- 分开报告本机 SDK、toml-test、覆盖率、托管 CI 和发布验证的实际结果。

## Code Review 专项不变量

- Parser/encoder 检查 1.0/1.1 方言差异、日期/数字边界、重复键、数组/表、错误恢复及输出确定性，拒绝以接受非法输入或跳过报错换取通过。
- Lossless document/edit 检查空/缺失节点、冲突/过期 revision、原子失败、span 与稳定 NodeId、无关文本保留；正向修复需同步覆盖反向或跨编辑路径。
- 流和 codec 检查调用方 ownership、有限预算、失败回滚、类型精度与生成代码版本约束；核心与 schema 的依赖方向不变。

## Code Review Rules

- 每条阻塞性意见应给出可触发输入/执行序列、违反的具体契约、影响及相关代码；不要把纯风格、未经验证的假设或已有问题的无关优化升级为阻塞缺陷。
- 对同一根因，在**一次审查**中检查相邻的正反、缺失/空值、边界、回退和对称路径；合并同一不变量的反例，而非分多轮逐个提出。只检查受影响的调用链，不穷举无关情况。
- 对照输入生产者、解码/校验者和最终使用方；确认修复同时保留合法输入与失败语义。可访问 Review Thread 时先去重，后来发现的真实回归仍必须指出。
- 后续提交重点复核当前修复、相关不变量与引入的回归；区分当前 PR 引入/加重的问题、历史缺陷和可独立跟进的建议。不得仅因审查次数多就跳过真实阻塞问题。

## Review 反馈处理与收敛

- 先验证每条 Review 意见并按根因归类；同组边界情况集中修复并补回归/参数化测试。避免“修一条、Push 一次”的循环。
- 聚合一轮实现与受影响测试后再推送；记录已修复、证据反驳、仍阻塞及范围外跟进的具体原因。
- 合并前核对最新 HEAD 上实际完成的复审与 CI；旧 SHA 的 Review、评论数归零或本地构建通过不能替代最新提交的证据。自动复审是否触发由 Codex 设置管理，`AGENTS.md` 本身不会触发 Review。
- 当前 PR 的真实阻塞缺陷与 Issue 验收必须满足；非阻塞独立改进可单开 Issue。不能用固定轮数或“全部 Thread 清零”作为唯一条件，也不应自动合并。

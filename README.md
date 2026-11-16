# Mailpipe

把已有 Agent Harness 接到 Apple Mail。
用自然语言整理邮件，在伴随 App 中查看摘要。

**当前阶段：M0 工程骨架与 Adapter。**
仓库核查日期：2026-11-16。
已有宿主、空动作扩展、两个 Adapter 和隔离测试。
真实邮件入口关闭；尚无签名安装包或发布流水线。

## 产品与边界

| 项目 | 设计目标 |
|---|---|
| 用户 | 使用 Apple Mail，且已安装并登录 Harness 的 Mac 用户 |
| P0 | 新邮件分类、自然语言规则、摘要、日志与条件撤销 |
| 模型接入 | Claude Code、Codex CLI；真实邮件受限能力待验证 |
| 交互 | 菜单栏入口、独立工作台、系统通知 |
| 整理 | MailKit 采集；Apple Events 定位、执行与核验 |
| 数据去向 | 由用户 Harness 配置决定；不宣称完全本地推理 |
| P1 | 历史搜索、Agent 增删改查、Daily Digest、AI 起草 |
| P2 | 白名单自动发送；未实现，不属于当前开发授权 |

App 不直连模型 API，不保管模型凭据。
用户继续在 Apple Mail 收发邮件。
P1 历史搜索是单独授权的只读能力，方案尚未实机验证。
P1 的增删改只产生意图，由 Mailpipe 经 Apple Events 执行。
P1 只打开草稿，不调用发送。

## 文档入口

| 需要 | 阅读 |
|---|---|
| Agent 开始工作 | [AGENTS.md](AGENTS.md) |
| 架构和责任边界 | [DESIGN.md](DESIGN.md) |
| 按任务找文档 | [Agent 维护参考](docs/agent-reference.md) |
| 产品范围和原 PRD 差异 | [产品方案](docs/product.md) |
| 页面、流程和异常态 | [交互设计](docs/interaction-design.md) |
| MailKit / Apple Events 边界 | [邮件集成](docs/mail-integration.md) |
| 模型调用和路由 | [Harness 契约](docs/harness-adapter.md) |
| 队列、动作、回执 | [数据契约](docs/data-contracts.md) |
| 隐私、权限和安全 | [安全设计](docs/security.md) |
| 验证与开发顺序 | [验证计划](docs/testing.md)、[里程碑](docs/roadmap.md) |
| 安装、签名和升级 | [部署方法](docs/deployment.md) |
| 风险和未决项 | [已知限制](docs/known-issues.md) |
| 原始材料与核查范围 | [来源](docs/sources.md) |

## 本地开发

需要完整 Xcode 和 Swift 6。工程部署下限为 macOS 13。
该下限尚未通过多版本实机验收。

```sh
./scripts/swift.sh build
./scripts/test.sh
./scripts/swift.sh run mailpipe-m0 offline
./scripts/swift.sh run mailpipe-m0 discover
./scripts/build-app.sh
```

用 Xcode 打开 `Mailpipe.xcodeproj`，选择 `Mailpipe` scheme。
构建输出位于 `.build/xcode/Build/Products/Debug/`。
构建脚本不签名、不安装、不启用 Mail 扩展。
修改工程目标后运行 `python3 scripts/generate-project.py`。
生成器是工程配置的维护入口，不手改生成文件。

`inspect claude|codex /absolute/path` 只检查版本和帮助。
App 的“运行样例”和 CLI 的 `offline` 都不调用模型。
库中的 `runSyntheticProbe()` 会消耗模型额度。
它仅接受固定合成样本；Codex 已完成真实合成探测。
App 和 CLI 不暴露真实模型探测入口。

## 验证状态

正文重入及宿主退出、Mail 重启后的单样本采集已实测通过。
单封移动、宿主独立读回与移回已实测通过。
写入由 Mail UI 执行，生产 Bridge 尚未接入。
Codex 固定分类及两次 canary 挑战通过。
Claude 被账户验证要求阻断。
完整身份、条件撤销和受限工具门槛仍未解除。
详见 [最新验证进展](docs/validation/2026-11-16-m0-move-harness.md)。

已有签名宿主、扩展启用和 Apple Events 实测证据。
工程与早期隔离测试见 [M0 工程记录](docs/validation/2026-11-15-m0-scaffold.md)。
尚未核验订阅条款、跨版本兼容和用户转化。

## 文档更新规则

`README.md` 记录现状，`DESIGN.md` 记录设计。
专题文档维护唯一详细契约。
设计变更先更新对应专题，再更新索引与摘要。
参考记录只保存通用结论，不保存私人邮件。

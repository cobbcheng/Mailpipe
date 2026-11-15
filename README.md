# Mailpipe

把已有 Agent Harness 接到 Apple Mail。
用自然语言整理邮件，在伴随 App 中查看摘要。

**当前阶段：文档设计，尚无可运行 App。**
仓库核查日期：2026-11-15。
目前没有 Xcode 工程、安装包、测试套件或发布流水线。

## 产品与边界

| 项目 | 设计目标 |
|---|---|
| 用户 | 使用 Apple Mail，且已安装并登录 Harness 的 Mac 用户 |
| P0 | 新邮件分类、自然语言规则、摘要、日志与条件撤销 |
| 模型接入 | 首批 Claude Code、Codex CLI；具体参数待验证 |
| 交互 | 菜单栏入口、独立工作台、系统通知 |
| 整理 | MailKit 采集；Apple Events 定位、执行与核验 |
| 数据去向 | 由用户 Harness 配置决定；不宣称完全本地推理 |
| P1 | Daily Digest、AI 起草、更多 Adapter |
| P2 | 白名单自动发送；未实现，不属于当前开发授权 |

App 不直连模型 API，不保管模型凭据。
用户继续在 Apple Mail 收发邮件。
P1 仅打开草稿，由用户在 Mail 中发送。

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

先读 Agent 入口，再按任务读取相关设计。
当前仅需检查 Markdown、引用和 Git diff。
不要把设计中的源码目录当作已实现代码。
工程建立后，在这里补真实构建和测试命令。

## 验证状态

已完成两份 Notion 材料的阅读。
已核对关键 Apple 文档、SDK 头文件和 Mail 脚本字典。
尚未运行 Mail 扩展、Apple Events 或真实模型。
尚未核验订阅条款、跨版本兼容和用户转化。

## 文档更新规则

`README.md` 记录现状，`DESIGN.md` 记录设计。
专题文档维护唯一详细契约。
设计变更先更新对应专题，再更新索引与摘要。
参考记录只保存通用结论，不保存私人邮件。

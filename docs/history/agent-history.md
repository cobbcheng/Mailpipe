# Agent 维护参考记录

只保存通用决策与验收边界。
不保存私人邮件、账户、部署地址或诊断原文。

## 文档分工

入口规则在 [AGENTS.md](../../AGENTS.md)。
当前事实在 [README.md](../../README.md)。
系统设计在 [DESIGN.md](../../DESIGN.md)。
任务索引在 [Agent 维护参考](../agent-reference.md)。

## 2026-11-15：建立设计基线

依据 PRD v0.3 与 MailKit API 汇总建立文档。
补充关键 Apple 官方资料、SDK 与脚本字典核查。
当前仅文档，没有应用工程或运行验收。

关键修订：

- MailKit 负责采集，Apple Events 负责事后动作。
- 自动化权限进入 P0，而非仅在 P2 发送时申请。
- 待处理状态只在 Mailpipe 显示，不占用原旗标。
- 日志、条件撤销和账户路由约束前移到 P0。
- 区分建议完成、动作核验和草稿交接。
- 账户不明不自动外发，定位歧义不改邮件。

以上是工程化设计建议，仍受 M0 门槛约束。
没有改动原 Notion 文档，没有运行真实模型或 Mail 操作。

## 2026-11-15：M0 工程骨架与 Adapter

建立 Swift Package 与双 target Xcode 工程。
新增 Claude Code / Codex CLI Adapter 和严格输出校验。
进程使用 stdin、输出上限、超时与取消清理。
真实邮件调用保持阻断，MailBridge 尚未连接 Mail。
验证范围和未完成项见 [工程记录](../validation/2026-11-15-m0-scaffold.md)。

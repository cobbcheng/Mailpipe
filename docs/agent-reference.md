# Agent 维护参考

本页只索引入口，不重复详细契约。
更新：2026-11-16。已有 M0 工程骨架。标题是“Apple Mail 主动回复助手”。P0 含 L2，落点见产品方案。

## 文档分工

| 文件 | 唯一职责 |
|---|---|
| [AGENTS.md](../AGENTS.md) | 工作规则与权限边界 |
| [README.md](../README.md) | 当前状态、用户入口与验证范围 |
| [DESIGN.md](../DESIGN.md) | 系统边界与架构决策 |
| 本页 | 按任务查找详细契约 |
| [参考记录](history/agent-history.md) | 通用决策历史 |

## 按任务读取

| 任务 | 先读 | 完成后同步 |
|---|---|---|
| 修改范围或优先级 | [产品方案](product.md) | 里程碑、交互与验收 |
| 主动回复、分拣或数据去向 | [产品方案](product.md)、[设计](../DESIGN.md) 第 10 节、[数据契约](data-contracts.md) 第 11 节 | 安全、Harness、邮件集成与验证 |
| 页面或交互状态 | [交互设计](interaction-design.md)、[新手引导](onboarding.md) | 对应错误码和验证用例 |
| MailKit / Mail 操作 | [邮件集成](mail-integration.md) | 数据契约、权限矩阵 |
| 模型调用 / 路由 | [Harness 契约](harness-adapter.md) | 安全和用量显示 |
| 身份 / 状态 / 撤销 | [数据契约](data-contracts.md) | 交互状态与恢复测试 |
| 权限 / 隐私 | [安全设计](security.md) | 引导、日志和部署 |
| 开发或验收 | [验证计划](testing.md) | 验证记录和已知限制 |
| 安装 / 更新 / 发布 | [部署方法](deployment.md) | README 中的真实命令 |
| 排期 / 接手 | [里程碑](roadmap.md)、[已知限制](known-issues.md) | 已完成证据与未决项 |
| 核对外部事实 | [来源](sources.md) | 核查日期和证据等级 |

## 源码与检查入口

| 任务 | 入口 |
|---|---|
| 五步向导、草案和恢复 | `Mailpipe/App/OnboardingView.swift`、`Packages/MailpipeRuntime/Sources/Onboarding.swift` |
| 待处理 UI 与账户设置 | `Mailpipe/App/PendingWorkbench.swift` |
| 工具诊断 | `Mailpipe/App/MailpipeApp.swift` |
| 持久化队列与调度 | `Packages/MailpipeRuntime/Sources/` |
| 入站暂存与纯文本 MIME | `Packages/MailpipeCore/Sources/InboundCapture.swift` |
| 扩展生命周期 | `Mailpipe/MailExtension/MailExtension.swift` |
| 输入、输出与路由校验 | `Packages/MailpipeCore/Sources/Classification.swift` |
| 回复分拣、草稿、级别与去向 | `Packages/MailpipeCore/Sources/ReplyContracts.swift` |
| CLI 探测和调用 | `Packages/HarnessAdapters/Sources/CLIAdapter.swift` |
| CLI 参数与包装解析 | 同目录 `DeepSeekHarnessAdapter.swift`、`CodexCLIAdapter.swift` |
| 进程生命周期 | 同目录 `POSIXProcessRunner.swift` |
| Bridge 边界 | `Packages/MailBridge/Sources/MailBridge.swift` |
| 无模型命令行检查 | `Tools/MailpipeM0/MailpipeM0.swift` |
| 回归 | `Tests/`、`scripts/test.sh` |
| 工程配置 | `scripts/generate-project.py`、`Package.swift` |
| 应用图标与菜单栏图标 | `design/icon/`、`Mailpipe/Assets.xcassets` |
| 当前验证 | [M0 工程记录](validation/2026-11-15-m0-scaffold.md) |

## 数据与诊断入口

| 对象 | 规划位置 | 排查顺序 |
|---|---|---|
| 扩展入站材料 | App Group 的 `inbox/` | 是否采集、是否完整、是否已导入 |
| 当前回复事实库 | `$HOME/Library/Application Support/Mailpipe/pipeline/state.sqlite` | records → runs / decision / draft；动作回执未实现 |
| 私有正文缓存 | `$MAILPIPE_DATA_DIR/content/` | 来源、到期时间、清洗状态 |
| 脱敏诊断 | `$MAILPIPE_DATA_DIR/diagnostics/` | error_code、版本、耗时 |
| 私有实机验收 | `$MAILPIPE_DATA_DIR/validation/` | 原始回执、截图和脱敏摘要 |
| 可提交验收 | `docs/validation/` | 仅合成或脱敏材料 |

当前宿主库位于 `$HOME/Library/Application Support/Mailpipe/pipeline/state.sqlite`。
扩展暂存在签名 App Group 的 `inbox/`。
诊断启动参数 `--pipeline-directory` 指定独立目录。
该模式不使用正式 App Group，也不访问 Mail 账户。

`MAILPIPE_DATA_DIR` 仍是设计中的数据目录符号。
目前没有实现此环境变量或对应 CLI。
不要在共享报告写真实账户、邮件或机器路径。

## 接手步骤

1. 检查 Git 状态和最近提交。
2. 阅读 README 的现状。
3. 按本表读取任务相关契约。
4. 核查代码与文档是否一致。
5. 先补缺失证据，再更新结论。
6. 报告未验证范围与外部状态。

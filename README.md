# Mailpipe

Apple Mail 主动回复助手。
收信即备好回复，邮件不经我们的服务器。

产品定义：帮助 Apple Mail 用户在自己的 Mac 上，收信即备好回复，借用你已经装好的 harness，邮件不经第三方服务器。

调度与执行在用户的 Mac 上，经本机 Harness 的 CLI 或本地 HTTP。
邮件内容仍会发给该 Harness 使用的模型厂商。
不声称全部在本地发生，也不声称端侧 AI。
标题不用“本地 AI”，也不用“本地 AI 邮件助手”。

**当前阶段：DeepSeek 持久化回复链路。**
仓库核查日期：2026-11-16。
已有新邮件暂存、SQLite 队列、分拣和 L2 草稿。
菜单栏与工作台共用待处理数据。
仅 DeepSeek 回复链路接入授权账户；Codex 仍限探针。
当前只接受有界纯文本，复杂 MIME 转待核对。
尚无发布安装包或发布流水线。

## 产品与边界

| 项目 | 设计目标 |
|---|---|
| 用户 | 使用 Apple Mail，且已安装并登录 Harness 的 Mac 用户 |
| 定位 | 帮助 Apple Mail 用户在自己的 Mac 上，收信即备好回复，借用你已经装好的 harness，邮件不经第三方服务器 |
| P0 | L0、L1、L2、单封数据去向标签、要不要回复的分拣 |
| 模型接入 | DeepSeek Harness、Codex CLI；真实邮件受限能力待验证 |
| 交互 | 菜单栏待处理、独立工作台、系统通知；不自动打开撰写窗口 |
| 整理 | MailKit 采集；Apple Events 定位、执行与核验 |
| 数据去向 | 每封标明 Harness 与模型厂商；未知显示未知 |
| 触发 | Mail 运行并下载新邮件时；合盖不承诺处理 |
| P1 | 历史搜索、Agent 增删改查、Daily Digest、用户主动起草 |
| P2 | L3 白名单延迟自动发送；未实现，须单独授权，不属于当前开发授权 |

App 不直连模型 API，不保管模型凭据，也不经 Mailpipe 的服务器转发。
用户继续在 Apple Mail 收发邮件。
L2 是默认级别。草稿只进菜单栏待处理。
Mail 草稿邮箱要等实机验证，未通过前不写入。
发送只打开草稿，不调用 send。
P1 历史搜索是单独授权的只读能力，方案尚未实机验证。
P1 的增删改只产生意图，由 Mailpipe 经 Apple Events 执行。
入站邮件的 Harness 调用只读、无工具。生成输出只能是草稿。
用户主动的查找不在这条限制里，也不能由来信触发。

## 当前使用入口

在工作台的“账户与设置”中选择 DeepSeek。
填写 Apple Mail 账户名称和邮箱，确认采集范围。
L2 为默认级别，已有暂停状态不会自动恢复。
新回调先留在本机；账户唯一核验后才调用模型。
“运行合成端到端验证”只用固定样本。
它最多消耗两次模型调用，不访问 Mail。
草稿只在待处理中展示，尚不能交接给 Mail。

## 文档入口

| 需要 | 阅读 |
|---|---|
| Agent 开始工作 | [AGENTS.md](AGENTS.md) |
| 架构和责任边界 | [DESIGN.md](DESIGN.md) |
| 按任务找文档 | [Agent 维护参考](docs/agent-reference.md) |
| 产品范围和 PRD v0.5 | [产品方案](docs/product.md) |
| 页面、流程和异常态 | [交互设计](docs/interaction-design.md) |
| 首次设置与首封草稿 | [新手引导 PRD](docs/onboarding.md) |
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

`inspect dsh|codex /absolute/path` 只检查版本和帮助。
App 的“运行样例”和 CLI 的 `offline` 都不调用模型。
库中的 `runSyntheticProbe()` 会消耗模型额度。
它仅接受固定合成样本；Codex 已完成真实合成探测。
App 不暴露真实模型探测入口。
CLI 新增 `reply-probe <dsh绝对路径> <新建输出目录>`。
它仅运行固定合成分拣和草稿，最多两次模型调用。
输出目录须为仓库外、尚不存在的绝对路径。

## 验证状态

分拣、草稿、服务级别和去向契约已有实现。
持久化后跨进程接续与 App 重启验证通过。
MailKit 单封合成入站到工作台草稿验证通过。
暂停和撤权后保留已生成草稿，不继续处理。
见 [持久化链路验收](docs/validation/2026-11-16-persistent-reply-pipeline.md)。
菜单栏弹窗独立点击、广泛 MIME 与邮箱兼容性未验证。
早期契约见 [回复契约验收](docs/validation/2026-11-16-reply-contracts.md)。

正文重入及宿主退出、Mail 重启后的单样本采集已实测通过。
单封移动、宿主独立读回与移回已实测通过。
写入由 Mail UI 执行，生产 Bridge 尚未接入。
Codex 固定分类及两次 canary 挑战通过。
一期已移除 Claude；DeepSeek 合成分类与零工具检查通过。
见 [DeepSeek 验证记录](docs/validation/2026-11-16-deepseek-harness.md)。
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

### 新手引导实现进展（2026-11-16）

本地实现五步向导、独立设置草案和重启恢复。
默认 L2；最终确认才生效，保留已有暂停。
DeepSeek 合成测试与正式采集队列隔离。
详见 [本轮验收](docs/validation/2026-11-16-onboarding.md)。

签名 build 4 已完成限定 Google IMAP 实机验收。
覆盖最终授权、系统拒绝（-1743）与首封 L2 草稿。
修正拒绝提示，恢复权限后可主动重试确认。
更新期间的扩展实例冲突及失败样本均有记录。
见 [实机验收](docs/validation/2026-11-16-onboarding-live.md)。

第四步选择邮箱账户，可多选；自动使用各账户收件箱。
选择先存草案，最终确认才授权整个集合。
详见 [账户收件箱验证](docs/validation/2026-11-16-account-inboxes.md)。

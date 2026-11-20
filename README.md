# Mailpipe

**让你的 Agent，帮你回邮件**

继续用 Apple Mail 收信。你授权的 Agent 起草回复，你在 Mac 上改稿，再去 Apple Mail 发送。

Mailpipe 把来信和草稿保存在你的 Mac 上。只有你授权的来信内容才会交给所选 Agent 起草，邮件不经 Mailpipe 服务器。可选择 Codex CLI、DeepSeek Harness、Claude Code、OpenCode、OpenClaw 或 Hermes Agent 起草。OpenClaw 和 Hermes Agent 使用官方 DeepSeek Flash。Claude Code 使用本机 CLI 的默认模型。OpenCode 使用你在连接测试后确认的模型。

**[下载 Mac 版](https://mailpipeai.com/)**

## 产品与边界

| 项目 | 设计目标 |
|---|---|
| 用户 | 使用 Apple Mail，且已安装并登录 Harness 的 Mac 用户 |
| 定位 | 用你已安装的 Agent 为 Apple Mail 来信起草回复，由你审阅和发送 |
| P0 | L0、L1、L2、单封数据去向标签、要不要回复的分拣 |
| 模型接入 | 六种 Agent 可起草回复 |
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
明确的简报、促销和付款回执可在本机跳过。
其余授权来信由 Agent 阅读，只为需要答复的邮件备稿。
DeepSeek Harness 可只读核对 GitHub PR 变更。Codex CLI、Claude Code、OpenCode、OpenClaw 和 Hermes Agent 仅依据来信起草。
用户主动的查找不在这条限制里，也不能由来信触发。

## 当前使用入口

首次设置时，从菜单选择本机已配置的起草 Agent。
连接测试会用一封示例邮件调用一次模型。
中途关闭后，再次打开可继续原步骤。

在 Apple Mail 中启用 Mailpipe 扩展。
选择允许 Agent 处理的来信范围，可涵盖所有账户今后的新来信，也可限定完整主题。
最后一步核对授权范围。已有的暂停状态会保留。
常见邮件会在本机提取为有界纯文本。加密、仅附件和超过 4 MiB 的原文转待核对。
草稿可在工作台查看、修改。发送前由你在 Apple Mail 核对收件人和正文。
验证范围见[紧凑引导验收](docs/validation/2026-11-19-compact-onboarding.md)和[手动来信入口移除验收](docs/validation/2026-11-19-remove-manual-intake.md)。

### 在 Apple Mail 中使用回复草稿

回复或转发一封邮件时，点撰写窗口工具栏里的 Mailpipe。
已有草稿会显示在面板里，可以直接修改或点「重新生成」。
尚无草稿时，点「生成草稿」。准备好后点「复制回复」，
粘贴到 Mail 的正文，在 Mail 中确认并发送。
重新打开已保存的转发时，也可以点「选取已有草稿」。

### 自定义回复提示词

完成首次设置后，在「设置 → 回复」中填写提示词并保存。
例如：“用来信的语言回复。先回答问题，结尾写明下一步。”
提示词适用于所有已授权账户，随起草请求发给所选 Agent。
保存后，新草稿和手动重新生成的草稿会使用这段提示词。
清空并保存即可恢复默认写法。

### 每日回复提醒

在「设置 → 通用 → 每日回复提醒」允许通知并选择时间。
默认按本地时间每天上午 10 点检查一次。
通知只显示仍在交接有效期内的待回复邮件数。
打开草稿后仍会计入。丢弃或交接给 Mail 后移出。
菜单栏也显示该数量。点击数量或通知，可在工作台查看最新一封。
如果 Mac 在睡眠或 Mailpipe 已退出，当天恢复运行后再检查。
队列为空、处理已暂停或授权已撤销时保持安静。

### 应用更新

0.1.1 开始，Mailpipe 会自动检查更新。
也可在菜单栏选择「检查更新…」。
安装前退出 Apple Mail，安装后再打开以加载新版扩展。
0.1.0 用户需从官网手动安装首个带更新器的版本。
候选包状态见[自更新验收](docs/validation/2026-11-20-self-update.md)。

## 文档入口

| 需要 | 阅读 |
|---|---|
| Agent 开始工作 | [AGENTS.md](AGENTS.md) |
| 架构和责任边界 | [DESIGN.md](DESIGN.md) |
| 按任务找文档 | [Agent 维护参考](docs/agent-reference.md) |
| 产品范围和 PRD v0.5 | [产品方案](docs/product.md) |
| 路线图重排（对照 PRD v0.5） | [路线图重排](docs/product/roadmap-v0.5.md) |
| 假设确认与措辞修订 | [假设与措辞](docs/product/assumptions-and-wording.md) |
| 好回复标准与 harness 记忆提示 | [好回复标准](docs/product/good-reply-standard.md) |
| 文档总索引 | [docs/README.md](docs/README.md) |
| 页面、流程和异常态 | [交互设计](docs/interaction-design.md) |
| 首次设置与首封草稿 | [新手引导 PRD](docs/onboarding.md) |
| MailKit / Apple Events 边界 | [邮件集成](docs/mail-integration.md) |
| 模型调用和路由 | [Harness 契约](docs/harness-adapter.md) |
| 队列、动作、回执 | [数据契约](docs/data-contracts.md) |
| 隐私、权限和安全 | [安全设计](docs/security.md) |
| 验证与开发顺序 | [验证计划](docs/testing.md)、[里程碑](docs/roadmap.md)（已被 [路线图重排](docs/product/roadmap-v0.5.md) 取代） |
| 安装、签名和升级 | [部署方法](docs/deployment.md) |
| 风险和未决项 | [已知限制](docs/known-issues.md) |
| 原始材料与核查范围 | [来源](docs/sources.md) |

## 本地开发

需要完整 Xcode 和 Swift 6。工程部署下限为 macOS 13。
该下限尚未通过多版本实机验收。

```sh
./scripts/swift.sh build
./scripts/test.sh
./scripts/swift.sh run mailpipe-m0 discover
./scripts/build-app.sh
```

用 Xcode 打开 `Mailpipe.xcodeproj`，选择 `Mailpipe` scheme。
构建输出位于 `.build/xcode/Build/Products/Debug/`。
构建脚本不签名、不安装、不启用 Mail 扩展。
修改工程目标后运行 `python3 scripts/generate-project.py`。
生成器是工程配置的维护入口，不手改生成文件。
菜单栏图标在 `Mailpipe/Assets.xcassets`。
应用图标使用 `design/icon/AppIcon.icon`。
源文件与生成脚本在 `design/icon/`。
运行 `python3 design/icon/build.py` 重新生成图标。
需安装 CairoSVG 与 Cairo 动态库。
背景与信封分层，圆角交给系统遮罩。
PNG 与 ICNS 保留为旧版设计导出。

`inspect <dsh|claude|opencode|openclaw|hermes|codex> /absolute/path` 只检查版本和帮助。
工具诊断只发现本机工具并检查参数，不调用模型。
Codex CLI 0.169.1 使用已有登录，通过 GPT-6.2 Sol 起草。

## 验证状态

分拣、草稿、服务级别和去向契约已有实现。
持久化后跨进程接续与 App 重启验证通过。
MailKit 单封合成入站到工作台草稿验证通过。
暂停和撤权后保留已生成草稿，不继续处理。
见 [持久化链路验收](docs/validation/2026-11-16-persistent-reply-pipeline.md)。
菜单栏弹窗独立点击、广泛 MIME 与邮箱兼容性未验证。
build 8 的 MIME 实测发现超限提示和候选残留问题。
build 9 已修复两项，并通过限定 Google IMAP 复测。
见 [MIME 复测记录](docs/validation/2026-11-17-mime-fix-retest.md)。
早期契约见 [回复契约验收](docs/validation/2026-11-16-reply-contracts.md)。

正文重入及宿主退出、Mail 重启后的单样本采集已实测通过。
单封移动、宿主独立读回与移回已实测通过。
写入由 Mail UI 执行，生产 Bridge 尚未接入。
Codex 固定分类及两次 canary 挑战通过。
早期 DeepSeek 合成分类与零工具检查通过。
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

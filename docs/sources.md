# 来源与事实核查

核查日期：2026-11-15。
只记录本轮实际读取的材料，不声明全量 API 审计。
同日另收一条安装观察转写，见第 6 节。截图未入库。

## 1. 用户提供的材料

| ID | 材料 | 使用范围 |
|---|---|---|
| P1 | [产品 PRD v0.3](https://app.notion.com/p/PRD-Apple-Mail-AI-v0-3-418632b374f5810e8813f604addec32a) | 2026-11-15 读过的目标、范围与商业假设 |
| P2 | [MailKit API 汇总](https://app.notion.com/p/MailKit-API-418632b374f581f7838fce48e9c5926c) | 四类扩展、数据模型与需求映射 |
| P3 | PRD v0.5 | 2026-11-16 产品负责人确认的版本。本轮未重新打开 Notion。产品方案按此版本对齐 |

P1 与 P2 通过已登录浏览器阅读。
P1 日期为 2026-11-14，文中未标来源的数字是其假设。
P3 是产品负责人确认的版本号。
本轮没有重新打开 Notion，也没有新的页面链接。
P2 自述遍历 193 个页面；本轮未复做该遍历。
不将该自述写成 Mailpipe 的独立验证结果。

Notion 与本仓库没有自动同步。
后续修改需记录版本与差异，不能静默覆盖两边。

## 2. Apple 官方资料

| ID | 来源 | 本轮确认 |
|---|---|---|
| A1 | [MailKit](https://developer.apple.com/documentation/mailkit) | 四类扩展职责 |
| A2 | [Action handler 回调](https://developer.apple.com/documentation/mailkit/memessageactionhandler/decideaction(for:completionhandler:)) | 下载时返回动作；带正文重入 |
| A3 | [MEMessageAction](https://developer.apple.com/documentation/mailkit/memessageaction) | 固定动作；系统邮箱移动 |
| A4 | [MEMessage](https://developer.apple.com/documentation/mailkit/memessage)、[rawData](https://developer.apple.com/documentation/mailkit/memessage/rawdata) | 只读属性、原始内容 |
| A5 | [MEExtensionManager](https://developer.apple.com/documentation/mailkit/meextensionmanager) | 内容规则和可见邮件刷新 |
| A6 | [ComposeSession](https://developer.apple.com/documentation/mailkit/mecomposesession) | 本轮以 SDK 头文件交叉核对 |
| A7 | [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events) | 发布时需进一步核对配置 |
| A8 | [NSAppleEventsUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription) | 发布时需进一步核对配置 |
| A9 | [WWDC21：Build Mail app extensions](https://developer.apple.com/videos/play/wwdc2021/10168/) | P2 的参考来源，本轮未重新观看 |

A2 网页示例仍出现旧 `bodyData` 名称。
A4 与本机 SDK 使用 `rawData`。
代码实现以选定 SDK 的真实声明为准。

官方清单未提供任意事后动作接口。
据此不采用“等待 AI 后重入扩展”架构。
这是 API 边界推导，不是运行失败实验。

## 3. 本机只读声明核查

| 项目 | 核查结果 | 不代表 |
|---|---|---|
| MailKit SDK 头文件 | 读取 Message、ActionHandler、ExtensionManager、ComposeSession | 已编译运行 |
| SDKSettings 元数据 | 标示 macOS SDK 27.0 | 当前工具链可正常构建 |
| Mail 脚本字典 | 有 selection、账户、邮箱、message id、读写状态、move、reply、send | 每种账户都可靠执行 |
| 系统版本 | 本轮环境为 macOS 27.0.1 | 产品最低或全部支持版本 |

脚本字典位置为系统 Mail.app 的 `Contents/Resources/Mail.sdef`。
只读取字典，没有向 Mail 发送 Apple Events。
没有读取用户邮箱内容或账户列表。

本轮 `xcrun --show-sdk-version` 查询失败。
错误为 SDK 无法定位；SDKSettings 文件仍可读取。
因此未声明工具链可用，也未执行构建。
M0 需先解决实际构建环境并记录选用 SDK。

## 4. 资料检索限制

Context7 只返回同名 .NET MailKit 库。
本项目使用 Apple MailKit，没有引用 .NET 资料。
改用 Apple 官方资料和本机 SDK 声明核查。

尚未独立验证：竞品价格、市场规模、订阅条款。
竞品安装界面另有一条一手转写，见第 6 节。
该转写不覆盖价格、条款、库表结构或 Spotlight 行为。
后续 P1 读库决定见 [邮件集成](mail-integration.md) 第 10 节。
O1 不是该决定的实机证据。
尚未实测：共享容器、自动化桥接、模型受限模式。
P1 的共享服务附件、线程与发件账户也未实测。

## 5. 文档组织来源

参照 Thread Harness 的文档职责划分：
`AGENTS.md` → `README.md` / `DESIGN.md` → 按需专题索引。
维护历史保存在 `docs/history/agent-history.md`。
没有移植其业务逻辑、私有账本或部署配置。

## M0 Adapter 工程核查补充

核查：2026-11-15。Claude 来源仅保留为历史。

| 来源 | 用途 | 证据边界 |
|---|---|---|
| [Claude CLI reference](https://code.claude.com/docs/en/cli-reference) | print、JSON、工具和会话参数 | CLI 声明，不是实机受限验收 |
| [Claude settings](https://code.claude.com/docs/en/settings) | hooks 与 managed policy 限制 | 生产策略仍需 canary |
| [Codex config reference](https://developers.openai.com/codex/config-reference/) | shell、图片、搜索配置 | read-only 不等于禁止全部工具 |
| 本机 Claude 2.1.296 帮助 | 核对完整参数名 | 只执行元数据命令 |
| 本机 Codex 0.169.0-alpha.11.1 帮助 | 核对 exec 参数名 | 只执行元数据命令 |
| Xcode 27.2 Mail Extension 模板 | extension point 与 principal class | 构建通过，未在 Mail 启用 |

此前 SDK 路径查询失败已解决。
构建脚本清除继承的 SDKROOT，再解析所选 Xcode SDK。
当前证据见 [M0 工程记录](validation/2026-11-15-m0-scaffold.md)。

## 6. 一手安装观察

记录日期：2026-11-15。

| ID | 材料 | 使用范围 |
|---|---|---|
| O1 | Cobb 于 2026-11-15 安装 Mailbutler 时的文字转写。来源是其 Mac 上的 11 张截图 | 可见的安装步骤、权限原文、路径、文件名和弹窗标题 |

截图未随附，也未入库。
仓库侧没有原截图可核对。
边界以转写为准。

| 项目 | 边界 |
|---|---|
| 已写入文档的内容 | 转写中的界面原文、路径和可见文件名 |
| 用户目录 | 写成 `<user>`。不含真实账户或邮件 |
| 未记录 | Mailbutler 版本、该 Mac 的系统版本、扩展是否启用成功 |
| 归纳 | Mail Library 指本地邮件、附件和 Envelope Index。未做格式审计 |
| 推断，待验证 | `Library/Accounts` 的账户范围、钥匙串凭据位置、`NSOpenPanel`、沙盒用户选择授权、security-scoped bookmark |
| 不证明 | 竞品功能可用、Envelope Index 的表结构、Spotlight 覆盖、辅助功能范围 |

详细拆解见 [邮件集成](mail-integration.md) 第 9 节。
未决项编号为 [Q-17](known-issues.md)。
O1 本身不是权限决定。
后来的只读搜索决定见同文第 10 节。

## DeepSeek Harness 一手核查

核查：2026-11-16。一期替换 Claude。

| 来源 | 用途 | 证据边界 |
|---|---|---|
| [官方仓库](https://github.com/deepseek-ai/deepseek-harness) | profile、插件、无头运行机制 | 文档不是实机验收 |
| [headless bundle](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/bundle/headless/README.md) | JSONL、审批与退出事件 | 以本机版本源码交叉核对 |
| 本机 dsh 0.2.2-rc.1 帮助与安装包源码 | 参数、credentials、tools guard、llm/stream | 版本固定；更新后需重验 |
| [本次验收](validation/2026-11-16-deepseek-harness.md) | 真实合成调用与反向暴露 | 不代表真实邮件或自定义工具已开放 |

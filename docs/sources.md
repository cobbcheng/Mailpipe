# 来源与事实核查

核查日期：2026-11-15。
只记录本轮实际读取的材料，不声明全量 API 审计。

## 1. 用户提供的材料

| ID | 材料 | 使用范围 |
|---|---|---|
| P1 | [产品 PRD v0.3](https://app.notion.com/p/PRD-Apple-Mail-AI-v0-3-418632b374f5810e8813f604addec32a) | 目标、范围、Harness 前提与商业假设 |
| P2 | [MailKit API 汇总](https://app.notion.com/p/MailKit-API-418632b374f581f7838fce48e9c5926c) | 四类扩展、数据模型与需求映射 |

两份材料均通过已登录浏览器阅读。
P1 日期为 2026-11-14，文中未标来源的数字是其假设。
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
尚未实测：共享容器、自动化桥接、模型受限模式。
P1 的共享服务附件、线程与发件账户也未实测。

## 5. 文档组织来源

参照 Thread Harness 的文档职责划分：
`AGENTS.md` → `README.md` / `DESIGN.md` → 按需专题索引。
维护历史保存在 `docs/history/agent-history.md`。
没有移植其业务逻辑、私有账本或部署配置。

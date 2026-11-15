# MailKit 与 Apple Mail 集成

状态：API 核查 + 推荐方案，未做实机集成。
核查日期：2026-11-15。证据索引见 [来源](sources.md)。
同日补充 Mailbutler 安装观察，见第 9 节。

## 当前工程状态

扩展入口已编译并嵌入宿主。
回调只调用 `completionHandler(nil)`。
它不读取正文、不设置动作、不请求正文重入。
尚未在 Mail 中启用或验证扩展发现。

MailBridge 已有定位、快照和歧义结果类型。
`UnavailableMailBridge` 始终返回不可用错误。
尚未实现 Apple Events、采集、App Group 或动作回执。

## 1. 核心结论

MailKit 能在下载邮件时返回动作。
它没有按邮件标识稍后写回动作的公开入口。
`invokeAgainWithBody` 只请求正文可用后的回调。
不能把它当作 AI 队列完成后的唤醒机制。[A2]

`MEMessageAction` 只提供固定动作。
移动目标仅归档、垃圾邮件和垃圾箱。
没有自定义邮箱参数。[A3]

## 2. 能力矩阵

| 需求 | MailKit | 推荐路径 | 证据状态 |
|---|---|---|---|
| 新邮件元数据 | `MEMessage` | Action handler | 官方 + SDK |
| 原始正文 | `rawData` 可空 | 授权后获取，解析 MIME | 官方 + SDK |
| 立即旗标 / 已读 | 固定 Action | 暂不用于排队标记 | 官方 |
| 异步 AI 动作回写 | 无公开入口 | Apple Events | 路径未实测 |
| 自定义邮箱移动 | 不支持 | MailBridge move | 字典存在，未实测 |
| 当前选中邮件 | 不支持 | MailBridge selection | 字典存在，未实测 |
| 账户、历史邮件 | 不支持枚举 | 授权后的有界查询 | 字典存在，未实测 |
| 线程 | 无线程对象 | 头字段关联已采集邮件 | 设计推断，不保证完整 |
| Mail 阅读侧栏 | 不支持 | 独立工作台 | 框架能力边界 |
| Compose | 可标注收件人、拦截发送 | P1 可选增强 | SDK |
| 草稿正文写入 | 无公开 setter | 宿主交接 | 尚未验证 |
| 自动发送 | 无主动 send API | P2 独立桥接 | 本轮不实现 |

`rawData` 包含原始邮件内容，需自行解析。[A4]
M0 不自动解析或发送附件内容。
不把网页示例的旧 `bodyData` 名称写入实现契约。
以所选 SDK 的 `rawData` 声明为准。

## 3. 扩展入口

初版只声明 `MEMessageActionHandler`。
入口遵循 `MEExtension`。
扩展点是 `com.apple.email.extension`。
Info.plist 以当前 Xcode 模板核对，不手写假定模板。

回调处理顺序：

1. 校验处理范围的最小配置。
2. 正文不可用时请求带正文重入。
3. 重入仍无正文时记录缺失，不循环等待。
4. 有界写入 App Group 入站材料。
5. 完成回调；无动作返回 `nil`。

不在回调中等待 Harness。
不承诺固定系统超时时间；M0 实测记录。
去重区分元数据阶段与正文阶段。
不因第一次回调已存在而丢掉后到的正文。

扩展没有可靠账户 ID。
入站数据先停留本地，身份确认后才允许自动模型调用。
无账户归属时，只允许用户逐封确认的建议请求。
扩展授权前说明：账户未解析时会本地暂存内容。
用户不接受该范围时，不启用自动采集。
宿主关闭时不保证自动拉起。
需验证宿主退出、Mail 重启、权限拒绝和磁盘满。

## 4. MailBridge 契约（拟定）

| 操作 | 输入 | 输出与约束 |
|---|---|---|
| `listAccounts` | 用户授权 | 账户标识；不读取密码 |
| `listMailboxes` | 已选账户 | 可选择目标，禁用跨账户移动 |
| `resolveMessage` | 受限范围 + 头字段线索 | 唯一 / 缺失 / 歧义 |
| `readSnapshot` | 已解析 locator | 邮箱、已读、旗标及身份校验字段 |
| `applyAction` | 有效意图 + 前置状态 | 执行返回值；不直接等于成功 |
| `verifyAction` | 意图 + 新定位结果 | 成功 / 明确失败 / 未知 / 冲突 |
| `openMessage` | 唯一 locator | 是否成功交给 Mail |
| `readSelection` | 用户主动触发 | 当前选择快照，调用后不随焦点变化 |

本机 Mail 脚本字典已确认上述相关字段与命令存在。
这不证明 Exchange、IMAP、POP 行为一致。
读账户、选中邮件和写邮件都按自动化权限处理。

初版采用固定 AppleScript 模板或有类型 Apple Events。
输入用参数或 descriptor 传递，不拼接脚本源码。
不运行模型产生的 AppleScript、Shell 或对象选择器。
App 不依赖辅助功能点击 Mail 界面。

## 5. 身份与范围

`MEMessage` 不提供账户、邮箱或 Mail 内部 ID。
收件人、Delivered-To 等头字段只作线索。
不能据此确定账户或授权云端处理。

优先在用户选择的账户与邮箱范围内匹配。
结合 Message-ID、日期、发件人及内容摘要。
Message-ID 可缺失、重复或跨账户出现。
缺失或歧义时转人工确认，不取第一条。
Mail 的数值 ID 仅作本地 locator，不作永久身份。
移动、重建索引后必须重新核验。

不得用全邮箱逐封扫描作为每次回调的默认路径。
M0 要测候选查询数量、延迟与准确率。
若定位成本不可接受，重评采集路径。
私有库映射是未验证候选。
见第 9 节与 [Q-17](known-issues.md)。
对照实验没有结论前，不用它定位。

## 6. 动作与回执

初版允许：移动到用户选定邮箱、设置已读、设置旗标。
默认保留原值；只有规则明确要求才改变。
不执行删除、垃圾邮件判定或发送。

多字段操作不是 Mail 的原子事务。
每个子动作独立记录结果。
模型完成后规则版本变动，废弃旧动作计划。
发送 Apple Event 前复查权限、暂停和原状态。

Apple Event 返回成功后仍要读回。
超时后不得直接补发相同操作。
重启只恢复核对任务，不重放未知写入。
撤销契约见 [数据契约](data-contracts.md)。

## 7. P1 草稿交接

| 方案 | 用途 | 限制 |
|---|---|---|
| `NSSharingService` composeEmail | 新建邮件与用户选定附件 | 发件账户、富文本和线程待实测 |
| `mailto:` | 短纯文本新邮件 | 长度、编码、默认客户端与附件限制 |
| AppleScript `reply` | 保留原回复上下文的候选 | 需权限；正文与线程结果须实测 |

本机字典存在 `reply` 与 `send`。
P1 bridge 不暴露 `send` 操作。
草稿交接只生成 `handed_off` 回执。
无“已发送”事实时，不能推断发送成功。
默认邮件客户端不是 Apple Mail 时需明确提示。
不得静默把草稿交给其他客户端。

## 8. 不采用的替代

不读取 Mail 私有 SQLite 或磁盘目录。
第 9 节的竞品观察不构成例外。
不借 Message Security 解码回调展示 AI 摘要。
不以 `reloadVisibleMessages` 重放指定邮件动作。
官方仅提供可见邮件刷新接口，SDK 注明会节流。[A5]
不依赖旧 `.mailbundle` 注入。

## 9. 竞品观察：Mailbutler 安装权限

状态：一手观察转写，不是实现审计。
日期：2026-11-15。来源编号 O1，见 [来源](sources.md)。
截图未入库。下文只保留转写中的可见文字与路径。
用户目录写成 `<user>`。
第 8 节仍然有效。本节只增加观察和候选。
[产品方案](product.md) 的“不读取 Mail 私有数据库”不变。
[安全设计](security.md) 的权限矩阵不变。
[数据契约](data-contracts.md) 不变。

### 9.1 本次看到的流程

主程序列出四种安装项。
本次记录继续的是 Mail Extension。

| 安装项 | 本次记录 |
|---|---|
| Mail Extension | 继续安装 |
| Outlook Add-in | 未记录后续安装 |
| Gmail Safari 扩展 | 未记录后续安装 |
| Gmail Chrome 扩展 | 未记录后续安装 |

选择 Mail Extension 后，界面显示 “Downloading remaining components”。
随后打开 .pkg，名称是 “Mailbutler for Mail”。
安装器要求管理员密码或 Touch ID。
提示原文是 “安装器”正在尝试安装新软件。
转写没有 Mailbutler 版本。
转写也没有该 Mac 的系统版本。

接着出现 “Privacy & Security Setup” 向导。
清单有四项：Accessibility、Mail Data、AppleScript、Mail Extension。
可见步骤是 Welcome → Accessibility → Mail Data → Automation。
清单中的 AppleScript 与步骤名 Automation，转写视为同一项。
Mail Extension 在清单里，并要在 Mail 中启用。
转写没有把它写成向导里的独立步骤页。
启用是否成功，本次没有核验。

```mermaid
flowchart LR
  A[选择 Mail Extension] --> B[下载剩余组件]
  B --> C[打开 Mailbutler for Mail.pkg]
  C --> D[管理员密码或 Touch ID]
  D --> E[Privacy and Security Setup]
  E --> F[Accessibility]
  F --> G[Mail Data 三项]
  G --> H[Automation]
```

启用 Mail Extension 的先后，转写没有单独标出。
因此上图在 Automation 处结束。

### 9.2 向导中的权限

| 项 | 转写中的可见内容 | 附注 |
|---|---|---|
| Accessibility | 见下方原文 | 记录者附注：系统层面不限定目标 App。本次未复测系统设置 |
| Mail Data | 三项 Grant Access，说明文字相同 | 此页使用文件选择框。转写未出现完全磁盘访问开关 |
| AppleScript | 向导步骤名为 Automation | 记录者归纳为 Apple Events 控制 Mail。未见脚本正文 |
| Mail Extension | 在 Mail 中启用 | 记录中记为 MailKit。未核对扩展点标识符 |

Accessibility 原文：

> This permission lets Mailbutler interact with the Apple Mail user interface which is required for features such as the sidebar or the integrated email tracking indicators.

上表附注来自记录者，不是面板原文。
该授权在系统层面不限定目标 App。
本次没有打开系统设置核对授权列表。
原文声称该权限用于侧栏和邮件跟踪指示。
本次没有使用这些功能。

Mail Data 三项的说明原文相同：

> Required to read email messages and Mail data used by Mailbutler features.

| 标签 | 预选路径 | 转写中可见的名称 | 弹窗标题 |
|---|---|---|---|
| Mail Library | `/Users/<user>/Library/Mail` | `PersistenceInfo.plist`、`V10` | grant Mailbutler access to Mail's database |
| Mail Settings | `/Users/<user>/Library/Containers/com.apple.mail` | 未列出内部文件 | access to Mail's preferences |
| Mail Account Settings | `/Users/<user>/Library/Accounts` | `Accounts4.sqlite`、`-shm`、`-wal`、`persona.cache`、`VerifiedBackup` | access to Mail's account management |

弹窗标题按转写保留原大小写。
Mail Library 的目录用途是归纳：本地邮件、附件和 Envelope Index。
本次没有打开这些文件。
也没有核对 schema。

`-shm` 与 `-wal` 按转写原文保留。
转写没有展开这两个后缀的完整文件名。

推断，待验证：`Library/Accounts` 是系统互联网账户库。
其中不只有 Mail 账户。
账户凭据一般在钥匙串，不在这个库里。
本次没有查询钥匙串。
不能把凭据位置写成事实。

### 9.3 文件选择上的引导

三项都通过系统文件选择框授权。
选择框预选了上表中的目标文件夹。
界面写明 “has been pre-selected for you, there is no need to navigate away”。
引导清单是 “1. Folder Selected ✓ / 2. Allow Access Button Clicked !”。
用户要点 “Allow Access”。
其他安装阶段是否另要完全磁盘访问，转写没有涉及。

推断，待验证：这是沙盒的用户选择授权。
持久化手段被记为 security-scoped bookmark。
文件选择框被记为可能的 `NSOpenPanel`。
本次没有检查沙盒、entitlement 或书签文件。
不能把这三项写成已证实实现。

### 9.4 对 Mailpipe 的启示

下表是分析，不是已验证事实。
现行引导仍是 Mail 扩展加自动化。
流程见 [交互设计](interaction-design.md)。

| 启示 | 定性 | 建议 |
|---|---|---|
| Mailbutler 用读库、辅助功能改界面、AppleScript 回写，补 MailKit 的缺口 | 单一产品的旁证。未复现其侧栏或跟踪指示 | 继续用 MailKit 采集、Apple Events 回写。不把辅助功能改 UI 列入当前方案 |
| `Accounts4.sqlite` 与 Envelope Index 可能帮助 Q-02 的邮件到账户映射 | 候选路径，未验证。不声称解决唯一对象定位 | 建议作为 M0 身份实验的只读对照。未排入当前顺序。见 Q-17 |
| 预选文件夹，再由用户点允许 | 将来若读库，可参考的授权体验 | 仅在单独立项后使用。不加入当前首次引导 |
| 默认只保留扩展与自动化；读库作为可选高级授权，并写明对应功能 | 产品与安全设计候选 | 未采纳。不替换现行权限矩阵 |

若将来单独立项读取这些文件，至少先处理下表。

| 风险 | 当前不能当作可用手段的原因 |
|---|---|
| Envelope Index 是私有格式 | schema 未核对。跨 macOS 版本可能变化 |
| 数据目录名 `V10` | 分析：该名称可能表示数据版本。未对照 Apple 文档 |
| `-wal` 中尚未合并的写入 | 只读主库可能漏掉未落盘记录。一致性未验证 |
| `Library/Accounts` 超出 Mail | 可能含其他互联网账户的元数据。范围未验证 |
| 辅助功能不限定目标 App | 一旦授予，控制面不限于 Mail。当前方案不申请 |

Q-02 的解除条件不变。
仍要求重复和缺失的 Message-ID 不误写。
私有库对照没有结论前，定位继续走有界查询。
歧义仍转人工确认。
未决项编号见 [已知限制](known-issues.md) 的 Q-17。

## 10. 来源与重评

[A2] [Action 回调](https://developer.apple.com/documentation/mailkit/memessageactionhandler/decideaction(for:completionhandler:))。
[A3] [MEMessageAction](https://developer.apple.com/documentation/mailkit/memessageaction)。
[A4] [rawData](https://developer.apple.com/documentation/mailkit/memessage/rawdata)。
[A5] [MEExtensionManager](https://developer.apple.com/documentation/mailkit/meextensionmanager)。

SDK 升级、Mail 行为变化或身份测试失败时重评。
待验证矩阵见 [验证计划](testing.md)。

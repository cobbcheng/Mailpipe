# MailKit 与 Apple Mail 集成

状态：API 核查 + 推荐方案，未做实机集成。
核查日期：2026-11-15。证据索引见 [来源](sources.md)。

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
不借 Message Security 解码回调展示 AI 摘要。
不以 `reloadVisibleMessages` 重放指定邮件动作。
官方仅提供可见邮件刷新接口，SDK 注明会节流。[A5]
不依赖旧 `.mailbundle` 注入。

## 9. 来源与重评

[A2] [Action 回调](https://developer.apple.com/documentation/mailkit/memessageactionhandler/decideaction(for:completionhandler:))。
[A3] [MEMessageAction](https://developer.apple.com/documentation/mailkit/memessageaction)。
[A4] [rawData](https://developer.apple.com/documentation/mailkit/memessage/rawdata)。
[A5] [MEExtensionManager](https://developer.apple.com/documentation/mailkit/meextensionmanager)。

SDK 升级、Mail 行为变化或身份测试失败时重评。
待验证矩阵见 [验证计划](testing.md)。

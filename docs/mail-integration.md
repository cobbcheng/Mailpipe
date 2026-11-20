# MailKit 与 Apple Mail 集成

状态：API 核查 + 推荐方案，未做实机集成。
核查日期：2026-11-15。证据索引见 [来源](sources.md)。
同日补充 Mailbutler 安装观察，见第 9 节。
同日把 P1 历史搜索定为只读邮件库，见第 10 节。
该方案尚未实机验证。
2026-11-16 起，触发时机见第 3 节，草稿落点见第 7 节。

## 当前工程状态

扩展入口已签名并嵌入宿主。
授权后，扩展先检查本封邮件的外层头、主题和发件地址。
明确的投递报告和自动回复直接跳过。
验证码、登录、发货和付款回执须匹配自动发件特征与主题模板。
订阅简报、产品动态和促销须匹配群发特征与主题模板。
群发特征包括有效退订头、群发标记或专用简报地址。
仅有退订头、免回复地址或含糊主题时放行。
人工转发、明确请求答复或带人工回复地址的来信也放行。
命中时原信留在 Mail，扩展不请求正文。
放行后才写入 App Group 暂存目录。
正文重入若匹配已有请求，沿用首次放行结果。
匹配使用授权、Message-ID 和主题。
请求记录超过 24 小时可被清理。无匹配记录时按本次回调判断。
正文缺失时有界请求重入，不执行 Mail 动作。
未授权时不采集，不调用模型。

`AppleMailReplyIdentity` 提供限定范围的只读核验。
唯一 Message-ID、主题和来源证据须一致。
宿主导入正文后，交由已授权的 Harness 判断是否需要回信。
首次自动处理在同一次调用中返回草稿或 `no_reply`。
例如，普通发票可能是例行通知，也可能要求回复核对。
判定无需回复后，工作台移除该条目，本地保留处理记录。
Google IMAP 单封合成样本已通过完整链路。
见 [持久化回复验收](validation/2026-11-16-persistent-reply-pipeline.md)。

`UnavailableMailBridge` 仍是整理路径的占位边界。
显式撰写交接由 `AppleMailComposer` 提供，见文末。
没有自动整理或发送能力。
正文提取已有隔离测试和限定 Google IMAP 实测。
跨邮箱兼容和菜单栏独立点击未验证。

## 正文提取

解析在本机完成。
不下载 HTML 里的图片或跟踪资源。
不把附件字节交给模型。

| 会提取 | 处理 |
|---|---|
| text/plain | 解码传输编码和字符集 |
| text/html | 转成纯文本。去掉脚本、样式和隐藏块 |
| multipart/alternative | 优先 text/plain。没有可用纯文本时用 HTML |
| multipart/mixed、related | 取正文。附件只记名称和类型 |
| 嵌套 multipart、内联 message/rfc822 | 继续提取可读正文 |
| multipart/signed、PGP 清签名 | 读取已有明文。不验证签名 |

标记为 `attachment` 的部分只记名称和类型。
此边界也适用于 `.eml` 和 multipart 容器。
不解码或递归提取这些附件的内容。

| 待核对原因 | 含义 |
|---|---|
| messageTooLarge | 原文超过 4 MiB |
| encryptedContent | S/MIME 或 PGP 加密，无法阅读 |
| signedOpaque | 不透明签名，没有可读正文 |
| attachmentOnly | 只有附件，没有正文 |
| calendarOnly | 只有日历邀请 |
| malformedMIME | 结构或传输编码无法解析 |
| unsupportedCharset | 字符集不支持，或字节无效 |
| unsupportedContent | 例如 text/enriched |
| emptyBody | 提取结果为空 |

| 上限 | 值 | 原因 |
|---|---|---|
| 原始邮件 | 4 MiB | 暂存和全文身份比对的硬顶 |
| 暂存文件 | 6 MiB | Base64 后的 JSON 捕获 |
| 解码工作集 | 256 KiB | 先截断，再裁引用 |
| 交给模型 | 16 KiB | 与分拣和草稿契约相同 |
| MIME 深度 | 8 | 更深视为畸形 |
| MIME 部分 | 64 | 更多视为畸形 |

字符集允许 UTF-8、US-ASCII、GBK、GB2312、GB18030、Big5、ISO-2022-JP。
也允许 ISO-8859-1 至 16（不含 12）和 windows-1250 至 1258。
标成 GB2312 的邮件按 GBK 解码。
GB2312 是 GBK 的子集，真实邮件常把 GBK 标成 GB2312。
传输编码允许 7bit、8bit、binary、base64 和 quoted-printable。
RFC 2047 头和 RFC 2231 附件名在本机解码。
Mail 提供的主题仍用 MailKit 已经解码的值。
超过 16 KiB 时，先去掉文末引用和 `-- ` 签名，再硬截断。
标记是 `[quoted history trimmed]`、`[signature trimmed]` 和 `[truncated]`。
附件记成 `[attachments: 名称 (类型)]`。
QP 或 base64 的中文原文仍是 ASCII，全文摘要可以比对。
8bit 且不是 UTF-8 的原文，摘要可能为空。
这种情况会停在身份待核对。实机表现未验证。

build 8 的 16 封合成入站已实测。
9 个可读样本通过账户核验并交给 fake Harness。
这不证明真实模型质量。
超大附件可被 MailKit 以不含附件字节的原文交付。
build 9 保留身份核验时的原文超限原因。
此类邮件显示原文超限，不交给 Harness。
原文硬顶按实际收到的字节计算。
正文拒绝回调合并到唯一匹配的等待正文候选。
匹配限制仍为授权 ID、主题、非空 Message-ID。
多个候选保持分离，不仅凭头部认定账户身份。
8bit GBK 的实机路径仍未验证。
初次失败见 [build 8 实机记录](validation/2026-11-17-mime-live.md)。
修复证据见 [build 9 复测](validation/2026-11-17-mime-fix-retest.md)。

### build 11：恢复 MailKit 丢失的 MIME 参数

跨账户样本中，MailKit 丢失顶层 MIME 参数。
纯文本缺少 charset；multipart 缺少 boundary。
Mail 中的完整原文仍包含这些参数。
正文传输字节未变化。
这会分别触发字符集或 MIME 解析拒绝。

宿主在已有授权范围内取得唯一完整原文。
先核验来源证据，再从完整原文提取正文。
来源证据包含稳定头字段与完整 MIME 正文摘要。
不会仅凭 Message-ID 或主题认定账户。

| 核验项 | 规则 |
|---|---|
| From、To、Cc、Reply-To | 地址与顺序一致；忽略显示名与域名大小写 |
| Subject | 解码 RFC 2047 后一致；兼容编码方式与字符集大小写 |
| Date、Message-ID、引用头 | 一致；只规范化折行空白 |
| MIME 类型、传输编码、Disposition | 一致 |
| 已采集 MIME 参数 | 原文必须保留相同值 |
| 完整 MIME 正文 | SHA-256 一致，包含附件及所有子部分 |
| 正文换行 | 统一 CRLF/LF，忽略末尾换行 |
| Received、ARC 等传输头 | 不作为稳定身份字段 |

复杂地址组、注释及引号本地部分暂不支持。
证据不足时保留旧的整封摘要核验。
旧摘要核验失败仍转人工，不猜测账户。
新证据仅存哈希与顶层 MIME 参数。
不增加原始邮件保留期。

所有者是宿主已有账户核验阶段。
触发是新入站带正文且能形成来源证据。
沿用每个授权范围一次查询及既有上限。
没有新增重试、后台任务或 MailKit 重放。
入站 ID 幂等、暂停和撤权边界保持有效。
已有失败记录不自动重试。
歧义、正文变化或解析失败均不调用模型。

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
| 回复窗口的工具栏按钮 | Compose 扩展提供弹出面板 | 查看、编辑、重新生成与复制建议 | 见下文 |
| 草稿正文写入 | 无公开 setter | 宿主交接 | 尚未验证 |
| 自动发送 | 无主动 send API | P2 独立桥接 | 本轮不实现 |

`rawData` 包含原始邮件内容，需自行解析。[A4]
M0 正文探针仍只检查合成标记。
生产分拣使用上面的正文提取，不把附件字节交给模型。
不把网页示例的旧 `bodyData` 名称写入实现契约。
以所选 SDK 的 `rawData` 声明为准。

## 3. 扩展入口

来信入口使用 `MEMessageActionHandler`。
回复窗口使用 `MEComposeSessionHandler`。
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
当前 MailKit 路径按用户确认的来信范围与目标 Harness 派发。
按账户授权的旧任务仍须核验归属。
扩展授权前说明：账户未解析时会在本机暂存内容。
用户不接受该范围时，不启用自动采集。
宿主关闭时不保证自动拉起。
MailKit 只在 Mail 运行并下载新邮件时进入回调。
Mail 没在运行时不会触发。
合盖期间不承诺处理。
睡眠和 Power Nap 期间是否仍会下载并回调，未验证，见 M0-17。
对外只说“打开 Mac 时，回复已经备好”。
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
| `createDraft` | 已确认的草稿意图 | P0 只记入待处理。实机验证通过后才写入草稿邮箱。不自动打开撰写窗口。发送只打开草稿 |
| `createMailbox` | 已确认的账户与邮箱名 | 是否出现在该账户；不写私有库 |
| `trashMessages` | 已确认的唯一 locator | 移到废纸篓；不永久删除 |

本机 Mail 脚本字典已确认选择、账户、移动、旗标和已读相关命令存在。
`createMailbox` 与移到废纸篓的具体命令名，本轮没有重新核对。
不在本文写死未核对的脚本。
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
P0 自动整理仍不用私有库定位。
见 [Q-02](known-issues.md)。
Envelope Index 的行号在验证能映射到 Mail 对象前，不能当作写操作 locator。
在此之前，历史命中可以展示。
写操作仍要求现有定位成功，否则转人工。

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

## 7. 草稿落点与交接

### 在 Mail 回复窗口使用建议

在 Mail 点「回复」或「回复所有人」，再点工具栏的 Mailpipe。
面板查找原邮件在本机已备好的回复。
没有草稿时，面板显示「暂无草稿」和「生成草稿」。
点击「生成草稿」后，Mailpipe 读取起草所需的正文。
首稿会显示在面板并保存到工作台。
已在处理的邮件可在面板刷新进度。
尚未采集的邮件需要 Mail 提供可读取的原文，
并且主题须符合当前 MailKit 授权。
用户可以直接编辑建议，也可以点「重新生成」。
已授权的工具依据原邮件和当前回复提示词重新起草。
成功后，新建议会替换面板里的文字。
生成失败时，用户可以继续编辑原建议。
面板与工作台共用每封邮件三次重新生成的额度。
用户点「复制回复」后，
在 Mail 正文选择插入位置，按 ⌘V。
引文、签名、收件人和发送均由 Mail 管理。

查找由宿主校验来源、授权范围与草稿版本。
单独打开面板或复制建议均不启动模型。
面板只展示能唯一匹配的建议。
宿主须在运行，扩展须已在 Mail 设置中启用。
接口见 [Compose 面板](https://developer.apple.com/documentation/mailkit/mecomposesessionhandler/viewcontroller(for:))。

### 工作台交接

P0 的落点只是菜单栏待处理列表。
Mail 草稿邮箱要等 M0-16 通过，未通过前不写入。
不自动打开撰写窗口。
发送只打开草稿，不调用 send。
用户点击“在 Mail 中打开”才打开撰写窗口。

| 方案 | 用途 | 限制 |
|---|---|---|
| 菜单栏待处理 | P0 默认落点 | 不改 Mail；不表示已同步到 iPhone |
| AppleScript `reply` | 验证通过后才写入草稿邮箱 | 需权限；线程与 iPhone 同步未验证。失败不阻塞 P0 |
| `NSSharingService` composeEmail | 用户主动的新邮件与选定附件 | 发件账户、富文本和线程待实测 |
| `mailto:` | 短纯文本新邮件 | 长度、编码、默认客户端与附件限制 |

AppleScript `reply` 能否保留原线程，以及草稿能否同步到 iPhone，是 M0-16。
它与 M0-02 正文重入、M0-03 移动后身份并列，都还不能当成已通过。
未通过前，不写入草稿邮箱，也不宣称线程保留或 iPhone 已同步。
M0-16 失败不把 L2 移出 P0。
本机字典存在 `reply` 与 `send`。
Bridge 不暴露 `send` 操作。
草稿交接只生成 `handed_off` 回执。
无“已发送”事实时，不能推断发送成功。
默认邮件客户端不是 Apple Mail 时需明确提示。
不得静默把草稿交给其他客户端。

## 8. 不采用的替代

不写入 Mail 私有 SQLite、`-wal` 或 `.emlx`。
P1 历史搜索可以只读打开已授权的邮件库，见第 10 节。
不读取 `Library/Accounts`。
那条路径仍只是 [Q-17](known-issues.md) 的未采纳候选。
不申请辅助功能，不依赖点击 Mail 界面。
不借 Message Security 解码回调展示 AI 摘要。
不以 `reloadVisibleMessages` 重放指定邮件动作。
官方仅提供可见邮件刷新接口，SDK 注明会节流。[A5]
不依赖旧 `.mailbundle` 注入。

## 9. 竞品观察：Mailbutler 安装权限

状态：一手观察转写，不是实现审计。
日期：2026-11-15。来源编号 O1，见 [来源](sources.md)。
截图未入库。下文只保留转写中的可见文字与路径。
用户目录写成 `<user>`。
本节只记录观察。
当时的“不读库”决定已由第 10 节替换为可选只读。
辅助功能仍然不申请。
[产品方案](product.md) 与 [安全设计](security.md) 已按第 10 节更新。

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

观察本身不是实现审计。
“建议”列已按第 10 节更新。
辅助功能没有改为采纳。
首次引导仍是 Mail 扩展加自动化，见 [交互设计](interaction-design.md)。

| 启示 | 定性 | 建议 |
|---|---|---|
| Mailbutler 用读库、辅助功能改界面、AppleScript 回写，补 MailKit 的缺口 | 单一产品的旁证。未复现其侧栏或跟踪指示 | 新邮件仍用 MailKit 采集、Apple Events 回写。不把辅助功能列入方案 |
| `Accounts4.sqlite` 与 Envelope Index 可能帮助 Q-02 | 账户映射仍未验证 | Envelope Index 已另作 P1 搜索来源。`Accounts4` 仍见 Q-17，未采纳 |
| 预选文件夹，再由用户点允许 | 授权体验参考 | 采纳为历史搜索的默认授权。不放入首次引导 |
| 读库作为可选高级授权，并写明对应功能 | 已确认的 P1 范围 | 见第 10 节。不授权时其他功能仍可用 |

下表仍是未验证风险。
它们不阻止把只读搜索写成方案。
在对应项解除前，不把查询结果当作已可用实现。

| 风险 | 尚未解除的原因 |
|---|---|
| Envelope Index 是私有格式 | schema 未核对。跨 macOS 版本可能变化 |
| 数据目录名 `V10` | 分析：该名称可能表示数据版本。未对照 Apple 文档 |
| `-wal` 中尚未合并的写入 | 只读主库可能漏掉未落盘记录。一致性未验证 |
| `Library/Accounts` 超出 Mail | 可能含其他互联网账户的元数据。范围未验证 |
| 辅助功能不限定目标 App | 一旦授予，控制面不限于 Mail。当前方案不申请 |

Q-02 的解除条件不变。
仍要求重复和缺失的 Message-ID 不误写。
自动整理在 Q-02 解除前继续走有界查询。
歧义仍转人工确认。
账户映射候选见 [Q-17](known-issues.md)。
搜索路径见 Q-18 至 Q-22。

## 10. P1 历史读取与增删改

状态：用户已确认的方案。库格式、Spotlight 覆盖和并发行为都未验证。
新邮件采集仍走 MailKit。
事后写入仍走 MailBridge，不走私有库。

### 10.1 查

不自建全文索引，也不建语义或向量索引。
元数据直接只读查询 Envelope Index。
范围是发件人、收件人、主题、日期、邮箱文件夹、已读和旗标。
正文检索使用 Spotlight，接口是 `mdfind` 或 `NSMetadataQuery`。
命中后只读对应 `.emlx`，取出原文。
具体谓词、表名和 `.emlx` 解析方式都未验证，本文不写。

| 假设 | 验证前的处理 |
|---|---|
| Envelope Index 是 SQLite，且含上述元数据 | 待验证。见 Q-18 |
| 正文不在该库中 | 待验证。见 Q-18 |
| Spotlight 覆盖 Mail 正文且结果稳定 | 待验证。见 Q-19 |
| 只读打开能看见 `-wal` 里尚未合并的写入 | 待验证。见 Q-20 |
| Mail 正在写库时，只读结果仍然完整 | 待验证。见 Q-21 |
| `V10` 这类目录名跨 macOS 版本保持不变 | 待验证。见 Q-22 |

只以只读方式打开数据库。
不创建、不修改、不删除 Mail 的库、日志或邮件文件。
Spotlight 返回的路径必须位于已授权的 Mail 库目录内。
目录外路径直接拒绝。
未证实需要锁或自动重试。
只读失败时向用户显示失败，不改写数据库。

自建索引只留作后续备选。

| 触发条件 | 到时再做的事 |
|---|---|
| 产品需要模糊语义查询，而元数据和 Spotlight 都不够 | 另立设计，再评估自建或向量索引 |
| 验证发现 Spotlight 漏索引或不稳定 | 停止把它当正文入口，再评估自建索引 |

这两条都尚未发生。
当前不建索引。

Envelope Index 的内部标识还不能当作 Q-02 的身份。
映射未验证前，自动整理不靠它定位。

### 10.2 增、删、改

所有写操作仍遵守持久意图、MailBridge 执行和读回核验。
结果未知时不盲重试。
协议见 [数据契约](data-contracts.md)。

| 类 | 允许的操作 | 确认 |
|---|---|---|
| 增 | 创建草稿；在已选账户下新建邮箱文件夹 | 草稿沿用交接预览。新建邮箱必须确认 |
| 删 | 只移到废纸篓 | 必须确认。不提供永久删除 |
| 改 | 移动、已读或未读、旗标 | 单封展示前后值后确认。批量必须确认 |

发送不因这些操作而放宽。
入站 L2 只准备草稿。
发送只打开草稿，不调用 send。
P1 的 Agent 起草也只打开草稿。
P2 的 L3 白名单延迟自动发送仍需单独授权，并要有日志和发出前撤销。
`createMailbox` 与废纸篓移动的脚本命令尚未重核。

已保存规则对未来新邮件的授权保持原样。
Agent 不能靠保存规则偷偷新建邮箱。

### 10.3 授权取舍

历史搜索单独授权。
拒绝后，新邮件、规则、草稿和自动整理仍按原权限工作。
不在首次引导里申请这项权限。

| 方案 | 用户确认的范围 | 决定 |
|---|---|---|
| 预选 `Library/Mail` 文件夹 | 邮件库目录。体验参考第 9 节 | 默认方案 |
| 完全磁盘访问 | 整块磁盘 | 不默认申请 |
| 辅助功能 | 不限定目标 App 的界面控制 | 不申请 |

预选文件夹只覆盖历史搜索需要的邮件库。
完全磁盘访问大于该功能，所以不作为默认。
若预选文件夹被验证为无法稳定读取，再另作决定。
在那之前不改走全盘访问，也不改走辅助功能。
`Library/Accounts` 不属于这项授权。

## 11. 来源与重评

[A2] [Action 回调](https://developer.apple.com/documentation/mailkit/memessageactionhandler/decideaction(for:completionhandler:))。
[A3] [MEMessageAction](https://developer.apple.com/documentation/mailkit/memessageaction)。
[A4] [rawData](https://developer.apple.com/documentation/mailkit/memessage/rawdata)。
[A5] [MEExtensionManager](https://developer.apple.com/documentation/mailkit/meextensionmanager)。

SDK 升级、Mail 行为变化或身份测试失败时重评。
邮件库格式或 Spotlight 行为变化时，重评第 10 节。
待验证矩阵见 [验证计划](testing.md)。

新来源证据记录主题规范化版本。
旧证据保留原摘要核验。
兼容 MailKit 的 UTF-8 Base64 主题表示。
该兼容仍校验全部选定头字段及完整 MIME 正文。
不会自动重新处理历史失败记录。

## 显式撰写交接

用户点击“在 Mail 中打开”后先预览发件地址、收件人和内容。
执行前重新核验授权、原信来源和编辑版本。
收件人取原信 Reply-To；没有该字段时才取 From。
畸形或重复 Reply-To 不回退为其他地址。
发件邮箱必须唯一属于当前授权账户。

固定 Apple Events handler 创建可见新撰写窗口。
参数通过描述符传入，不拼成可执行脚本。
读回 ID、发件人、收件人、主题及正文才记录成功。
没有调用 send，也不承诺新窗口保留原邮件 threading。

交接意图在调用 Mail 前写入本地记录。
相同成功交接不重复开窗，未知结果不自动重试。
每条记录只允许一次交接，之后编辑可手动复制到 Mail。
打开窗口不等于发送完成；最终发送由用户在 Mail 确认。

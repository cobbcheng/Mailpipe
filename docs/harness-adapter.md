# Harness Adapter 契约

普通草稿支持 DeepSeek Harness、Claude Code、OpenCode、OpenClaw 和 Hermes Agent。
Codex CLI 仅提供安装与能力检查。
OpenClaw 与 Hermes 的实测范围见[官方 DeepSeek 合成草稿验收](validation/2026-11-19-openclaw-hermes.md)。
OpenCode 的版本与实机范围见[菜单栏草稿验收](validation/2026-11-19-opencode-drafts.md)。
Claude Code 的实测范围见[合成草稿验收](validation/2026-11-19-claude-code-drafts.md)。
证据见 [DeepSeek 实测](validation/2026-11-16-deepseek-harness.md)。
Codex 证据见 [此前实测](validation/2026-11-16-m0-move-harness.md)。

## 当前实现边界

| 接口 | 行为 |
|---|---|
| `HarnessDiscovery.find()` | 只查可执行文件，不读取凭据 |
| `inspect()` | 执行版本和帮助，检查完整参数名 |
| `run(ReplyModelTask, route, authorize)` | 所选工具起草回复；调用前重查宿主授权 |

DeepSeek 仅接受已验证的 `dsh 0.2.2-rc.1`。
每次创建独立 DSH_HOME，加载应用自有配置。
普通草稿禁用内置工具、MCP、skills 和子代理。
个人措辞参考见[原生上下文验收](validation/2026-11-18-native-harness-memory.md)。
禁用后台任务、热更新、遥测和推理重试。
推理前核对注册及广告工具均为空。
工具 guard 拒绝所有调用，并限制一次模型请求。
固定路由为 `deepseek-official / deepseek-flash`。
原有凭据由 Harness 官方插件读取，App 不提取。
只验证了已有 API Key 登录；其他登录方式未验证。
正常结束删除临时会话；硬崩溃残留未验证。
这些限制不构成操作系统级沙盒。

Codex 目前只做发现、版本和参数检查。
真实邮件调用尚未接入，也没有可用入口。
各回复工具共用宿主的授权与持久化队列。
切换工具须试写并重新授权。旧授权不能转投新工具。

Runner 使用独立进程组、非阻塞管道和单个工作线程。
原因是 stderr 堵塞会阻止 stdin 写入和取消。
合成大输出、超时和取消测试覆盖此失败模式。
每次调用最多占用一个工作线程，无重试。
超时、取消或输出超限时终止进程组并回收父进程。
进程可主动逃离进程组；本机制不是安全沙盒。
取消标记用锁跨线程传递，不参与业务调度。

输入上限为 10 封；单封正文上限为 16 KiB。
stdout 与 stderr 总上限为 1 MiB。
模型调用最长 120 秒。Hermes 运行时探测限时 30 秒，其余元数据检查限时 10 秒。
这些是工程保护值，尚无吞吐量实测依据。

输出拒绝多余字段、缺项、重复和批次外 ID。
证据必须来自输入的 subject 或 body。
错误展示只返回错误码，不展示原始输出。
参数齐全只用于启动前检查，不构成安全认证。
Claude Code、OpenCode、OpenClaw 和 Hermes Agent 普通起草均使用空工具集。
下文第 8 节是已确认、尚未实现的工具边界。

## 1. 问题与接入选择

| 方式 | 优点 | 成本与约束 | 阶段 |
|---|---|---|---|
| CLI 无头调用 | 复用安装和登录；生命周期可控 | 冷启动、进程树、输出包装差异 | P0 |
| 本地 HTTP / Gateway | 可复用连接 | 鉴权、服务发现、权限隔离 | P1 验证 |
| 直连模型 API | 可自建简单调用 | 引入凭据与计费管理 | 不采用 |

原有回复入口为 `dsh`、`claude --print` 和 `opencode run --standalone`。
Claude 仅支持已验收的 CLI 2.1.296。
Claude 的模型与认证由 CLI 从用户配置加载。
App 从成功回执记录模型名和 token。
代理的模型名不足以确定供应方或实付费用。

OpenCode 接受已验收的 CLI 2.3.0。
未指定模型时，示例邮件使用隔离环境的默认模型。
保存授权后，普通起草固定使用试写确认的模型。
切换模型须重新试写并确认来信范围。

OpenClaw 接受 2026.11.5，用一次性 `agent exec` 起草。
在 OpenClaw 本机配置中使用
`openclaw models auth paste-api-key --provider deepseek` 保存密钥。
子进程自行读取其原生认证存储，调用官方 `deepseek/deepseek-flash`。
关闭插件、技能和模型工具。临时目录承载本轮会话。
仅接受单轮纯文本结果，并核对返回的提供方和模型。

Hermes Agent 接受 0.23.2 的官方原生启动器。
在 Hermes 默认配置目录的 `.env` 设置 `DEEPSEEK_API_KEY`。
启动器在自带的 Python 环境执行单次 `AIAgent` 起草。
禁用工具、工作目录上下文、记忆和后台评审。
Hermes 自行加载凭据，API 请求限于官方 DeepSeek 的 `deepseek-flash`。
该适配器不启动 Hermes Gateway，也不使用其个人会话。

## 2. 能力探测与生命周期

| 阶段 | 契约 |
|---|---|
| 检测 | 仅查可执行路径、版本；多个候选让用户选择 |
| 能力记录 | 版本、无头方式、输出格式、工具限制、会话保留 |
| 健康测试 | 用户点击；只传合成数据；明确消耗调用 |
| 调用 | 固定路径与参数数组，内容走 stdin |
| 结果 | 解析工具自身封装，再校验业务 JSON |
| 停止 | 用户取消或超时，终止可控进程树 |
| 更新 | 版本变化后旧能力认证失效，重新探测 |

不定时唤醒模型仅为健康检查。
优先利用真实请求结果更新健康状态。
登录失效、权限不足、额度不足使用不同错误码。
调用中不自动执行登录或安装命令。

## 3. 安全合格条件

| 能力 | 自动处理的要求 |
|---|---|
| 内置 shell、文件工具、任意 MCP | 必须可禁用，并由隔离测试证明 |
| 入站调用 | 不附加任何工具，包括 Mailpipe 工具 |
| 用户主动的 Agent | 只附加搜索、读取和产生意图的工具。接入方式未验证，见 Q-04 与 Q-23 |
| 文件访问 | Harness 自己不能读写邮件库或工作目录外的文件 |
| hooks / skills / 全局指令 | 明确是否加载；不能产生额外执行 |
| 空工作目录 | 每次独立；仅是环境隔离，不等于沙盒 |
| 网络 | 推理所需网络按配置；不允许任意工具外发 |
| 凭据 | 由 Harness 自管；App 不提取 |
| 会话保留 | 记录路径与清理能力；不能宣称自动清除 |

“只读”不等于“无工具”，读取文件也会泄露数据。
因此不把 Harness 的只读模式当作邮件库隔离。
不传跳过权限确认参数。
DeepSeek 使用 `approval-policy never` 且工具全禁用。
该策略本身不作为安全证明。
无法证明内置工具已被禁止时，不向该 Adapter 提交邮件。
可以继续用合成输入验证，不开放绕过按钮。

## 4. 调用接口与实现范围

输入包含 `request_id`、`task_kind`、`schema_version`。
生产调度须绑定 `account_scope`、`route_policy_version`。
回复队列已绑定宿主策略版本与核验后的账户。
合成探针不访问邮箱账户。
每封邮件以内部 `message_ref` 引用。
已实现单封 `reply_triage` 与 `reply_draft`。
下文简称 triage 与 draft。
`parse_rule` 和批次调度尚未实现。
`triage` 用类别和摘要回答“要不要回复”。
当前回复流水线对已授权来信直接调用 `draft`。
这次调用只读、无工具，输出只能是草稿。
classify 与 summarize 不再作为独立交付，只作为 triage 的输入字段。
历史搜索和写意图不走这些批次。
它们走第 8 节的 Mailpipe 工具，并且只能由用户主动发起。

模型可见内容仅含完成任务所需字段。
不传数据库路径、可执行路径或自动化控制参数。
正文清洗、截断和附件排除发生在调用之前。
实现和上限见 [邮件集成](mail-integration.md) 的正文提取。
显示截断事实；不把片段当完整线程。

合成分拣响应：

```json
{
  "schema_version": 1,
  "request_id": "req-demo",
  "message_ref": "msg-demo",
    "category": "billing",
    "needs_action": "no",
    "should_reply": "no",
    "summary": ["这是一封合成账单通知。"],
    "evidence": [{"field": "subject", "text": "示例账单"}]
}
```

`category` 枚举为 customer、billing、notification、newsletter、other、unknown。
`needs_action` 与 `should_reply` 的枚举都是 yes、no、unknown。
只有 `should_reply` 为 yes 才进入 draft。
摘要最多 3 项，每项长度受限。
draft 响应包含版本、请求 ID、分拣请求 ID。
内容只有 `message_ref`、主题和正文。
收件人由未来的可信 Mail 交接层确定，模型不可指定。
证据必须能在输入对应字段中找到。
入站的 triage 与 draft 不授予工具权限。
输出不得包含脚本、任意动作或文件访问请求。
draft 结果不能被解释成发送、移动或打开撰写窗口。

当前拒绝缺失或请求之外的 `message_ref`。
后续批次还须拒绝重复邮件引用。
未知字段与枚举按严格 schema 拒绝。
后续批次不完整时须隔离失败项。
不重复执行已核验动作。
schema 合法不代表分拣正确；质量单独评估。

## 5. 路由、批处理与预算

每批只含同账户、同路由和同策略版本的邮件。
不混入不同隐私要求的账户。
未知账户先停留本地，不走默认路由。
无账户归属的单封建议需用户确认内容与 Harness。

回退集合 = 用户顺序 ∩ 账户允许集合 ∩ 安全合格集合。
每次回退都重查该集合，并在日志显示实际 Adapter。
不通过切换模型、认证方式或 API Key 绕过限制。

设计初值：10 封或 2 分钟成批，单 Harness 串行。
单次 CLI 超时初值 120 秒，需 M0 校准。
每批设置总调用上限 3 次，含修复和回退。
用户全局每日调用上限由引导明确配置。
没有预算配置前，不开始自动后台调用。
“单封确认”生成一次性路由许可，只覆盖该内容摘要。
它不绑定账户、不允许回退，也不授权 Mail 写操作。
预算计入失败与取消；未知 token 不记为零。

## 6. 错误与重试

| 错误码 | 自动行为 | 用户提示 |
|---|---|---|
| `not_installed` / `unsupported_version` | 停止该 Adapter | 安装或核对版本 |
| `auth_required` | 不重试登录 | 在 Harness 中登录 |
| `unsafe_capability` | 阻止邮件调用 | 该版本未通过安全验证 |
| `quota_exhausted` | 停止该路由 | 检查额度或手动调整路由 |
| `rate_limited` | 最多一次延迟重试 | 显示等待，不循环唤醒 |
| `timeout` | 终止进程，丢弃迟到结果 | 保留任务，允许用户重试 |
| `invalid_output` | 最多一次 schema 修复 | 仍失败则标记失败 |
| `cancelled` | 不重试、不回退 | 已取消 |

限流等待尊重服务返回的等待时间。
等待超过任务有效期时结束，不延长到无限期。
Schema 修复、限流重试和回退共享总次数上限。
推理重试允许产生重复费用，必须计量。
Mail 动作未知时，不以重新推理绕过核对。

## 7. 可观察性与重评

记录版本、request_id、耗时、退出码、错误分类。
记录模型和 token 时标明来源；不可检测则未知。
不保存 stdout 原文到通用日志。
可用于诊断的摘要先脱敏并限制长度。

订阅条款尚未核验，技术可调用不代表允许商用集成。
上线前按提供商与版本记录结论。
若无安全无头模式或条款不允许，暂停该 Adapter。

## 8. Mailpipe 工具边界

状态：用户已确认，代码尚未实现。
入站分拣和草稿继续只交换固定 JSON，不调用这些工具。
来信不能触发工具。
历史查找和 Agent 增删改必须走这些工具，且只能由用户主动发起。

| 工具 | 执行者 | 结果 |
|---|---|---|
| `searchMail` | Mailpipe | 有上限的元数据与正文片段 |
| `readMail` | Mailpipe | 一封已命中邮件的有上限正文 |
| `proposeMailAction` | Mailpipe | 待确认或待执行的意图，不是回执 |

Harness 不能直接打开文件系统、运行 shell，或向 Mail 发命令。
写工具的入参和出参见 [数据契约](data-contracts.md)。
Mailpipe 校验参数、账户和上限后再执行读取。
需要确认的意图先交给用户，再由 MailBridge 执行。

DeepSeek Harness 与 Codex CLI 的工具挂载尚未验证。
可能的方式包括各自的自定义工具或 MCP。
本文不记录具体命令、开关或参数。
DeepSeek 的零内置工具配置已有实测。
挂载自有工具后的组合边界仍需验证。
这两项并入 [Q-04](known-issues.md)，细节编号为 Q-23。
验证前，真实邮件仍走 `unsafeCapability`，不调用进程。

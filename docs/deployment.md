# 安装、签名与发布

状态：支持本地开发签名；尚无发布安装包。
更新：2026-11-17。

## 1. 当前限制

运行 `./scripts/build-app.sh` 构建宿主与嵌入扩展。
原生分层图标编入宿主与扩展。
菜单栏使用资源目录中的模板图。
脚本默认关闭签名；不安装或启用扩展。
设置 `MAILPIPE_DEVELOPMENT_TEAM` 后使用 Apple Development。
例如：`MAILPIPE_DEVELOPMENT_TEAM="$TEAM_ID" ./scripts/build-app.sh`。
本机需已有对应开发签名证书。
宿主与扩展使用同一团队前缀的 App Group。
扩展声明沙盒，宿主声明 Apple Events 权限。
开发签名与实机进展见 [验收记录](validation/2026-11-15-m0-signed-identity.md)。
工程 Bundle ID 为开发占位，签名前须确定团队和标识。
没有安装或发布命令。
MailKit API 下限是 macOS 12，不等于产品支持下限。
产品最低系统、CPU 架构和签名团队在 M0 冻结。
本轮只读核查环境不代表目标支持矩阵。

## 2. 分发选择

推荐 Developer ID 签名与公证的官网直装包。
理由是宿主需调用用户安装的 Harness 和 Mail 自动化。
不在此宣称所有本地 HTTP 客户端都不能进 App Store。
若以后改变分发路径，重新核查沙盒与审核约束。

## 3. 拟定签名与权限

| 目标 | 要求 | 验证 |
|---|---|---|
| 宿主 App | Hardened Runtime、Developer ID | 签名身份与实际包一致 |
| Mail 扩展 | 嵌入宿主、App Sandbox | Mail 能发现并手动启用 |
| 共享材料 | 一致的 App Group 配置 | 宿主和扩展真实读写 |
| Mail 自动化 | Usage Description 与 Apple Events entitlement | 系统弹窗、拒绝和撤销 |
| 通知 | 用户选择时请求 | 拒绝不影响核心功能 |

实际 entitlement 按原型最小集确定。
不启用关闭沙盒、放宽库校验等无关例外。
不在文档中写私人 Team ID、签名凭据或部署地址。
Apple 配置来源见 [来源](sources.md)。

## 4. 后续发布顺序

1. 冻结版本、commit 和目标系统矩阵。
2. 跑受影响隔离测试与集成验收。
3. 检查包中无邮件和私有配置。
4. 逐项核对签名与 entitlements。
5. 提交公证并校验结果。
6. 在干净环境安装并验证权限。
7. 记录校验和与发布说明。
8. 按用户授权发布下载产物。

调试安装、公开发布与用户数据迁移分别报告。
签名成功不证明 Mail 功能可用。
公证成功不证明 Harness 条款合规。

## 5. 升级与回滚

升级前暂停新派发，并核对在途动作。
备份数据库 schema、规则版本与必要恢复材料。
不把私人备份打进发布包。

升级保留账户范围、暂停、规则停用与路由授权。
不要自动重放旧邮件或恢复 P2 发送。
数据库迁移先在备份副本验证。
不兼容的新 schema 禁止让旧版本直接写入。
回滚应恢复匹配的软件与备份，并核对外部动作。
备份恢复不能撤回 Mail 中已经发生的变化。

## 6. 卸载

退出 App 不等于禁用 Mail 扩展。
引导用户在 Mail 中关闭扩展。
本地数据是否保留由用户选择。
说明 Mail 中已完成的整理不会自动撤销。
说明 Harness 会话不随 App 卸载自动删除。

## 7. 回复队列本机验证更新

2026-11-16：本机测试 App 与扩展更新到 build 3。
签名和完整链路范围见 [验收记录](validation/2026-11-16-persistent-reply-pipeline.md)。
没有新增安装命令或发布脚本。
正式队列位于用户 Application Support 下的 Mailpipe/pipeline。
升级保留 state.sqlite、暂停状态与账户授权。
`--pipeline-directory` 只用于独立诊断目录。
该模式不连接正式 App Group 或 Mail 账户。
不要让两个宿主同时使用同一队列目录。
第二个写者会被独占锁拒绝，不自动抢占。

## 8. 新手引导验收更新

2026-11-16：签名 App 与扩展更新到 build 4。
[验收记录](validation/2026-11-16-onboarding-live.md) 包含最终授权、拒绝与首封草稿。

同路径覆盖构建前，先正常退出 Mail 与宿主。
本轮曾出现 PlugInKit Code=16：other version in use。
旧实例仍占用时，即使勾选启用也可能无法采集。
构建完成后核验签名，再正常启动宿主与 Mail。
不要通过重放旧邮件来掩盖更新期间的采集缺口。
系统权限验收使用正常 App 启动方式。
直接执行宿主二进制的结果不替代 TCC 拒绝验收。

本地构建可用 `MAILPIPE_DERIVED_DATA_PATH` 指定独立产物目录。
不设置时仍使用 `.build/xcode`，不改变应用数据位置。
邮箱多选测试包为 build 5，见 [验收记录](validation/2026-11-16-mailbox-multiselect.md)。

build 6 修正为账户多选、自动关联各账户收件箱。
替代 build 5 的文件夹选择交互，见 [验证记录](validation/2026-11-16-account-inboxes.md)。

2026-11-17：本机测试宿主与扩展更新到 build 8。
代码基线为 PR #15 合并提交 `2e07a72`。
原签名团队、Bundle ID 和 App Group 保持一致。
覆盖前正常退出 Mail 与宿主，保留旧包和队列备份。
验收结束后恢复原配置，撤销临时采集与 fake 工具授权。
测试队列另存私有证据，正式队列恢复为空。
Mail 与更新后的宿主已恢复运行。
范围与未通过项见 [MIME 实机记录](validation/2026-11-17-mime-live.md)。

同日 build 9 修复超限原因与正文候选残留。
先用签名候选包完成实机复测，再更新已安装测试包。
两端包版本均为 9，签名、Bundle ID 与权限保持一致。
覆盖后新增合成邮件确认安装位置的扩展已执行。
原配置与队列已恢复，不重放旧邮件。
详见 [MIME 修复复测](validation/2026-11-17-mime-fix-retest.md)。


2026-11-17：本机测试宿主与扩展更新到 build 11。
修复跨账户采集缺失 MIME 参数的问题。
来源证据核验后，使用 Mail 完整原文提取正文。
7 封合成邮件均完成 fake 分拣与备稿。
原队列、暂停、账户与 Harness 配置已恢复。
详见 [采集来源恢复验收](validation/2026-11-17-capture-source-recovery.md)。

同日 build 12 修复中文主题编码导致的来源误拒绝。
保留原引导修复，提供无正文身份失败的手动恢复入口。
签名与权限保持一致，数据库三张表逐项未变。
历史失败记录不自动重放。
详见 [中文主题来源核验](validation/2026-11-17-subject-identity.md)。


2026-11-17：用户授权更新原生 UI 本地测试包。
宿主与扩展均为 build 13，沿用原签名与权限。
更新前备份旧包、队列及共享采集目录。
更新后三张数据库表逐项一致。
已打开工作台和现有草稿供用户查看。
详见 [原生 UI 验证与更新](validation/2026-11-17-native-ui.md)。


同日用户授权将本地 App 更新到 build 14。
包含草稿详情 v1.2 和恢复后的顶部玻璃筛选栏。
沿用原签名和权限，备份旧包及队列。
更新后三张数据库表逐项一致，已打开现有草稿。
详见 [草稿详情验证与更新](validation/2026-11-17-draft-detail-v12.md)。

## 收件箱范围与详情分区更新

2026-11-18：用户授权本地测试包更新为 build 17。
宿主与扩展版本一致，签名和权限保持不变。
本次按用户要求不创建备份。
原数据保留，仅新增收件箱范围核验标记。
完整隔离回归、合成 UI 和安装后查看通过。
边界与证据见 [验收记录](validation/2026-11-18-inbox-scope-and-detail.md)。

同日 build 18 补充原邮件发件人、To/Cc 展示。
旧记录只在安全来源核验通过后补齐地址。
不把账户地址或 Reply-To 当作原收件人。
124 项隔离回归通过；继续沿用签名与权限，不创建备份。

2026-11-19：本地测试包更新至 build 20。
宿主与扩展保留原签名、权限和双架构。
工作台与菜单栏点击通过[卡顿修复验收](validation/2026-11-19-workbench-responsiveness.md)。

同日清除重复测试包，从空安装位置装入 build 21。
系统仅登记一个宿主和一个已启用的 Mail 扩展。
重装与授权复核见[实机记录](validation/2026-11-19-workbench-responsiveness.md#build-21-清理重装)。

同日更新 build 22，修复查询子进程反复显示 Dock 图标。
签名、双架构与安装路径已核对。见[实机记录](validation/2026-11-19-workbench-responsiveness.md#build-22-的-dock-图标)。

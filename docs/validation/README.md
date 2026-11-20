# 验证记录

当前已有工程与签名验证记录，尚无完整功能验收。

- [Apple Mail 回复工具栏](2026-11-20-mailkit-compose.md)
- [自定义回复提示词](2026-11-20-reply-prompt.md)
- [自更新与安装前退出保护](2026-11-20-self-update.md)
- [移除手动添加来信](2026-11-19-remove-manual-intake.md)
- [工作台布局与窗口缩放](2026-11-19-workbench-layout.md)
- [紧凑新手引导与工作台入口](2026-11-19-compact-onboarding.md)
- [build 9 超限原因与正文候选修复复测](2026-11-17-mime-fix-retest.md)
- [build 8 更新与 MIME 实机验收](2026-11-17-mime-live.md)
- [MIME 正文提取审查修复与 macOS 回归](2026-11-17-mime-review-fixes.md)
- [引导分级测试、扩展回执与逐封建议](2026-11-17-onboarding-completion.md)
- [DeepSeek Harness 替换与受限验证](2026-11-16-deepseek-harness.md)
- [单样本移动读回与受限 Harness 实测](2026-11-16-m0-move-harness.md)
- [移动闭环再次实机验证](2026-11-15-m0-move-retest.md)
- [正文重入与退出重启实机复测](2026-11-15-m0-live-body-lifecycle.md)
- [M0 正文、移动与生命周期验证进展](2026-11-15-m0-body-move-lifecycle.md)
- [M0 工程骨架验证](2026-11-15-m0-scaffold.md)
- [M0 签名与账户定位进展](2026-11-15-m0-signed-identity.md)

单封合成邮件的 Mail 扩展交接与账户定位已实测通过。
正文两阶段回调及宿主退出、Mail 重启后单样本采集已通过。
11 月 16 日普通列表单样本移动与移回已通过。
宿主独立读回了源、目标的前后状态。
生产写回、并发冲突撤销和崩溃恢复仍未通过。
同邮箱重复 ID 拒绝和 Google / iCloud 范围隔离已实测通过。
原始缺失 ID 的 mbox 导入已实测，Mail 源代码仍无该头。
SMTP / MailKit 缺失头入站、完整 Mail 门槛仍未通过。
Google 恢复待发草稿后，源代码已含 Message-ID。
该路径未保留代转语义；提交项仍待确认送达。
Codex 固定分类与两次 canary 挑战通过。
一期改为 DeepSeek Harness；零工具分类通过。
Mailpipe 自定义工具接入仍未验证。
核查边界见 [来源](../sources.md)。

后续记录采用 [验证计划](../testing.md) 的模板。
文件名建议使用 `YYYY-MM-DD-topic.md`。
只提交合成样本或脱敏结论。
真实邮件、截图与模型原始输出放私有数据目录。
每份记录区分接口声明、隔离测试和实机行为。

## 文档检查记录

- [2026-11-15 文档基线检查](2026-11-15-document-baseline.md)

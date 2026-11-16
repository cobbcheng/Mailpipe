import SwiftUI
import AppKit
import MailpipeCore
import MailpipeRuntime

struct OnboardingView: View {
    @ObservedObject var model: PendingModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    private let titles = ["看看它能做什么", "连接 AI 工具", "启用 Mail 扩展", "选择处理范围", "复核并开始"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("第 \(model.onboarding.step) 步，共 5 步").foregroundStyle(.secondary)
            Text(titles[model.onboarding.step - 1]).font(.largeTitle.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    page.disabled(model.onboardingBusy && model.onboarding.step != 2)
                    if let issue = model.onboardingIssue { Text(issue).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            Divider()
            HStack {
                Button("返回") { model.onboarding.step -= 1 }.disabled(model.onboarding.step == 1 || model.onboardingBusy)
                Button("保存草案，稍后继续") { model.saveOnboarding(); openWindow(id: "workbench"); dismiss() }
                Spacer()
                if model.onboarding.step < 5 {
                    Button("继续") { model.onboarding.step += 1 }.buttonStyle(.borderedProminent).disabled(model.onboardingBusy || (model.onboarding.step == 4 && !model.mailboxSelectionValid))
                } else if model.onboarding.completed {
                    Button("打开工作台") { openWindow(id: "workbench"); dismiss() }
                } else {
                    Button(model.onboarding.level == .l2 ? "确认范围，开始为新邮件备稿" : "确认范围并保存级别") { model.finishOnboarding() }
                        .buttonStyle(.borderedProminent).disabled(!canConfirm)
                }
            }
        }.padding(28).frame(minWidth: 660, minHeight: 560)
            .onAppear { model.offeredOnboarding = true }
            .task(id: model.onboarding.step) {
                if model.onboarding.step >= 4 && !model.attemptedMailboxDiscovery { model.loadMailboxes() }
            }
            .onChange(of: model.onboarding) { _ in model.saveOnboarding() }
    }
    private var canConfirm: Bool {
        !model.onboardingBusy && model.onboarding.extensionAcknowledged &&
        !model.mailboxLoading && model.mailboxSelectionValid &&
        model.onboardingResult?.state == .draftReady && model.hasSharedInbox
    }
    @ViewBuilder private var page: some View {
        switch model.onboarding.step {
        case 1:
            Text("继续用 Apple Mail，收信即备好回复").font(.title2)
            Text("邮件不经我们的服务器，仍会交给所选模型厂商。")
            GroupBox("离线合成示例 · 未读取邮件、未调用模型、未发送") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("colleague@example.com · 请确认收到项目简报")
                    Text("原文：请回复确认收到这份示例项目简报。")
                    Text("分拣：需要回复，依据是明确的确认请求。")
                    Text("草稿：已收到示例项目简报，谢谢。")
                    Text("草稿进入菜单栏待处理，不自动打开或发送。")
                }.padding(8)
            }
        case 2:
            Picker("DeepSeek Harness", selection: $model.onboarding.executable) {
                Text("请选择工具").tag("")
                ForEach(model.installations) { Text($0.executable.path).tag($0.executable.path) }
            }.disabled(model.onboardingBusy)
            Text("未找到工具时，可先保留草案。工具诊断中可查看版本；不读取登录凭据。")
            Text("数据去向：DeepSeek 官方 / deepseek-flash。仅支持通过受限能力检查的 0.2.2-rc.1；运行前再次核查。")
            Text("点击测试表示同意发送固定合成内容。最多两次调用：先分拣，再生成草稿；消耗自己的额度，不自动重试。")
            if model.onboarding.testID == nil {
                Button("确认去向，测试分拣与备稿", action: model.testOnboarding)
                    .disabled(model.onboarding.executable.isEmpty || model.onboardingBusy)
            } else if model.onboardingBusy {
                ProgressView("正在测试")
                Button("取消测试", action: model.cancelOnboardingTest)
            } else {
                Text(model.onboardingResult?.state == .draftReady ? "备稿测试通过" : "备稿未验证；中断或未知结果不会自动重放")
                if let result = model.onboardingResult {
                    if let draft = result.draft { Text(draft.body).textSelection(.enabled) }
                    ForEach(result.runs, id: \.destination.runID) { run in
                        Text("\(run.destination.taskKind.rawValue)：输入 \(run.inputTokens.map(String.init) ?? "未知") token，输出 \(run.outputTokens.map(String.init) ?? "未知") token；字符 \(run.inputCharacters.map(String.init) ?? "未知") / \(run.outputCharacters.map(String.init) ?? "未知")；实付未知")
                            .font(.caption)
                    }
                }
                Button("清除测试确认，准备重新测试（另计额度）", action: model.resetOnboardingTest)
            }
        case 3:
            Text("扩展已随 App 提供，无需另外下载。")
            Text("1. 打开 Apple Mail\n2. 进入“邮件 → 设置 → 扩展”\n3. 勾选 Mailpipe，并确认系统显示的权限。")
            Button("打开 Apple Mail") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app")) }
            Text("扩展可接触新邮件；账户未解析时可能先在本机暂存。若不接受，可保留离线体验，或在 Mail 中关闭扩展。")
            Toggle("我已手动启用扩展（运行状态仍待验证）", isOn: $model.onboarding.extensionAcknowledged)
            Text("没有新邮件不等于扩展失效。找不到扩展时，核对 App 安装位置与签名；必要时保存 Mail 草稿后手动重启 Mail。")
        case 4:
            Text("选择邮箱账户，可多选。选中后自动处理对应收件箱的新邮件。")
            Text("只读发现账户与对应收件箱，不读取邮件内容、不授权外发。系统可能请求 Mail 自动化权限。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("已选择 \(model.onboarding.selections.count) 个账户")
                Spacer()
                Button("刷新账户", action: model.loadMailboxes).disabled(model.mailboxLoading)
            }
            if model.mailboxLoading { ProgressView("正在读取 Apple Mail 账户…") }
            if let issue = model.mailboxIssue { Text(issue).foregroundStyle(.secondary) }
            ForEach(model.mailboxChoices) { account in
                Toggle(isOn: Binding(
                    get: { model.onboarding.selections.contains { $0.accountID == account.accountID && $0.id == account.id } },
                    set: { model.selectMailbox(account, selected: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.accountName).font(.headline)
                        Text("自动处理收件箱").font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.checkbox).padding(.vertical, 5)
            }
            ForEach(model.onboarding.selections.filter { !model.mailboxChoices.contains($0) }) { box in
                HStack {
                    Text("旧选择不在账户收件箱范围内，请移除：\(box.accountName) / \(box.displayMailbox)")
                    Button("移除") { model.selectMailbox(box, selected: false) }
                }
            }
            TextField("精确主题限制（可选）", text: $model.onboarding.exactSubject)
            Picker("服务级别", selection: $model.onboarding.level) {
                Text("L2 · 备好草稿（默认）").tag(ServiceLevel.l2)
                Text("L1 · 只提示需要回复").tag(ServiceLevel.l1)
                Text("L0 · 不准备回复；整理尚未接入").tag(ServiceLevel.l0)
            }
            Text("最终确认前会再次核验所选账户的收件箱。读取列表与勾选只保存草案；最终确认才授权未来新邮件处理，不授权移动、标记或发送。")
            Text("Mail 整理单独授权，目前不可用。逐封建议替代路径尚未实现。")
        default:
            Text("已选择 \(model.onboarding.selections.count) 个账户 · \(model.onboarding.level.rawValue)")
            ForEach(model.onboarding.selections) { box in
                Text("\(box.accountName) · 收件箱")
            }
            Text("主题范围：\(model.onboarding.exactSubject.isEmpty ? "所选账户收件箱的未来新邮件" : model.onboarding.exactSubject)")
            Text("发送字段：主题和有界单段纯文本正文（最多 16 KiB）；复杂 MIME 与附件不处理。交给所选 DeepSeek Harness，再到 DeepSeek 官方模型。")
            Text("备稿测试：\(model.onboardingResult?.state == .draftReady ? "通过" : "未通过")；扩展收信链路待新邮件验证。")
            Text("不移动、不标记、不发送。确认只作用于未来新邮件，不补处理未授权积压。已有暂停保持有效。")
            if !model.hasSharedInbox { Text("当前为隔离诊断或共享容器不可用，只能保存草案。") }
            if model.onboarding.completed { Text("已保存配置；请从菜单栏查看待处理。没有新邮件时继续等待。") }
        }
    }
}

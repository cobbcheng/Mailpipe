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
                    Button("继续") { model.onboarding.step += 1 }.buttonStyle(.borderedProminent).disabled(model.onboardingBusy || (model.onboarding.step == 4 && !model.onboarding.isSuggestionsOnly && !model.mailboxSelectionValid))
                } else if model.onboarding.completed {
                    Button("打开工作台") { openWindow(id: "workbench"); dismiss() }
                } else {
                    Button(confirmationTitle) { model.finishOnboarding() }
                        .buttonStyle(.borderedProminent).disabled(!canConfirm)
                }
            }
        }.padding(28).frame(minWidth: 660, minHeight: 560)
            .onAppear { model.offeredOnboarding = true }
            .task(id: model.onboarding.step) {
                if model.onboarding.step >= 4 && !model.onboarding.isSuggestionsOnly && !model.attemptedMailboxDiscovery { model.loadMailboxes() }
            }
            .onChange(of: model.onboarding) { _ in model.saveOnboarding() }
    }
    private var confirmationTitle: String {
        if model.onboarding.isSuggestionsOnly { return "确认，使用逐封建议" }
        switch model.onboarding.level {
        case .l2: return "确认范围，开始为新邮件备稿"
        case .l1: return "确认范围，提示需要回复的邮件"
        case .l0: return "确认范围，仅分拣摘要"
        }
    }
    private var canConfirm: Bool {
        !model.onboardingBusy && model.onboardingTestPassed &&
        (model.onboarding.isSuggestionsOnly || (model.onboarding.extensionAcknowledged &&
        !model.mailboxLoading && model.mailboxSelectionValid && model.hasSharedInbox))
    }
    private var levelPicker: some View {
        Picker("服务级别", selection: $model.onboarding.level) {
            Text("L2 · 备好草稿（默认）").tag(ServiceLevel.l2)
            Text("L1 · 只提示需要回复").tag(ServiceLevel.l1)
            Text("L0 · 不准备回复；整理尚未接入").tag(ServiceLevel.l0)
        }
    }
    @ViewBuilder private var extensionStatus: some View {
        if let observation = model.extensionObservation {
            Text(observation.event == .messageReceived ? "扩展回执：已收到邮件回调" : "扩展回执：已被 Mail 加载")
            Text("最近回执：\(observation.observedAt.formatted()) · build \(observation.build)").font(.caption)
            Text("这是历史运行证据，不代表当前仍已启用或完整处理链路已通过。")
        } else { Text("扩展运行待验证：尚无有效回执。用户勾选不能证明扩展正在运行。") }
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
            levelPicker.disabled(model.onboardingBusy)
            Picker("DeepSeek Harness", selection: $model.onboarding.executable) {
                Text("请选择工具").tag("")
                ForEach(model.installations) { Text($0.executable.path).tag($0.executable.path) }
            }.disabled(model.onboardingBusy)
            Text("未找到工具时，可先保留草案。工具诊断中可查看版本；不读取登录凭据。")
            Text("数据去向：DeepSeek 官方 / deepseek-flash。仅支持通过受限能力检查的 0.2.2-rc.1；运行前再次核查。")
            Text(model.onboarding.level == .l2 ? "只发送固定合成内容，最多两次调用：分拣与备稿。消耗额度，不自动重试。" : "只发送固定合成内容，调用一次分拣，不生成草稿。消耗额度，不自动重试。")
            if model.onboarding.testID == nil {
                Button(model.onboarding.level == .l2 ? "确认去向，测试分拣与备稿" : "确认去向，测试分拣", action: model.testOnboarding)
                    .disabled(model.onboarding.executable.isEmpty || model.onboardingBusy)
            } else if model.onboardingBusy {
                ProgressView("正在测试")
                Button("取消测试", action: model.cancelOnboardingTest)
            } else {
                Text(model.onboardingTestPassed ? "所选级别测试通过" : "所选级别未验证；中断或未知结果不会自动重放")
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
            Button("打开 Mail 扩展设置…", action: model.openExtensionSettings)
            Button("我已操作，检查状态") { model.onboarding.extensionAcknowledged = true; model.refresh() }
            extensionStatus
            Button("不启用扩展，使用逐封建议") { model.useSuggestions() }
            if model.onboarding.isSuggestionsOnly { Text("已选择逐封建议，可继续；无需启用扩展。") }
            Text("没有新邮件不等于扩展失效。找不到扩展时，核对 App 安装位置与签名；必要时保存 Mail 草稿后手动重启 Mail。")
        case 4:
            Picker("处理方式", selection: Binding(get: { model.onboarding.isSuggestionsOnly }, set: {
                model.onboarding.suggestionsOnly = $0; model.saveOnboarding()
            })) {
                Text("自动处理所选账户").tag(false)
                Text("逐封建议（无需 Mail 权限）").tag(true)
            }
            if model.onboarding.isSuggestionsOnly {
                Text("手动粘贴一封邮件的主题和正文。每次先核对内容与目标 AI 工具，再明确提交。")
                Text("不自动读取账户或邮件，不授权后台采集。完成设置将撤销原自动处理范围，保留暂停和已有结果。")
            } else {
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
                Text("最终确认前会再次核验所选账户的收件箱。读取列表与勾选只保存草案；最终确认才授权未来新邮件处理，不授权移动、标记或发送。")
                Button("拒绝或暂不授权，改用逐封建议", action: model.useSuggestions)
            }
            Text("Mail 整理单独授权，目前不可用。")
        default:
            Text("服务级别：\(model.onboarding.level.rawValue)")
            Text("目标：DeepSeek Harness → DeepSeek 官方 / deepseek-flash")
            Text(model.onboarding.executable).font(.caption).textSelection(.enabled)
            if model.onboarding.isSuggestionsOnly {
                Text("逐封建议：不读取 Mail，不自动外发。每封确认内容和目标工具后才调用。")
            } else {
                Text("已选择 \(model.onboarding.selections.count) 个账户")
                ForEach(model.onboarding.selections) { box in
                    Text("\(box.accountName) · 收件箱")
                }
                Text("主题范围：\(model.onboarding.exactSubject.isEmpty ? "所选账户收件箱的未来新邮件" : model.onboarding.exactSubject)")
                Text("发送字段：主题和有界单段纯文本正文（最多 16 KiB）；复杂 MIME 与附件不处理。交给所选 DeepSeek Harness，再到 DeepSeek 官方模型。")
                extensionStatus
            }
            Text("所选级别测试：\(model.onboardingTestPassed ? "通过" : "未通过")")
            Text(model.onboarding.isSuggestionsOnly ? "不移动、不标记、不发送。只处理逐封确认的内容，已有暂停保持有效。" : "不移动、不标记、不发送。确认只作用于未来新邮件，不补处理未授权积压。已有暂停保持有效。")
            if !model.hasSharedInbox && !model.onboarding.isSuggestionsOnly { Text("当前为隔离诊断或共享容器不可用，只能保存草案。") }
            if model.onboarding.completed { Text("已保存配置；请打开工作台。逐封建议需主动提交，自动处理等待新邮件。") }
        }
    }
}

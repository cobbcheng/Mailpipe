import SwiftUI
import AppKit
import MailpipeCore
import MailpipeRuntime

struct OnboardingView: View {
    @ObservedObject var model: PendingModel
    @Environment(\.dismiss) private var dismiss
    private let titles = ["让回复准备得更轻松", "连接 AI 工具", "启用 Mail 扩展", "处理方式", "准备就绪"]
    private var toolName: String { model.installations.first { $0.executable.path == model.onboarding.executable }?.kind.displayName ?? "AI 工具" }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Mailpipe", systemImage: "envelope").font(.headline)
                Spacer()
                Text("\(model.onboarding.step) / 5").foregroundStyle(.secondary)
            }
            Text(titles[model.onboarding.step - 1]).font(.largeTitle.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    page.disabled(model.onboardingBusy && model.onboarding.step != 2)
                    if let issue = model.onboardingIssue { Text(issue).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            Divider()
            HStack {
                Button("返回") { model.onboarding.step -= 1 }.disabled(model.onboarding.step == 1 || model.onboardingBusy || model.onboarding.completed)
                Button("稍后继续") { model.saveOnboarding(); dismiss() }.disabled(model.onboardingBusy)
                Spacer()
                if model.onboarding.completed {
                    Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
                } else if model.onboarding.step < 5 {
                    Button("继续") { model.onboarding.step += 1 }
                        .buttonStyle(.borderedProminent).disabled(!canContinue)
                } else {
                    Button("保存并开始", action: model.finishOnboarding)
                        .buttonStyle(.borderedProminent).disabled(!canConfirm)
                }
            }
        }.padding(28).frame(minWidth: 640, minHeight: 560)
            .onAppear { model.offeredOnboarding = true }
            .onChange(of: model.onboarding) { _ in model.saveOnboarding() }
    }
    private var canContinue: Bool {
        guard !model.onboardingBusy else { return false }
        switch model.onboarding.step {
        case 2: return model.onboardingTestPassed
        case 3: return model.onboarding.extensionAcknowledged || model.onboarding.isSuggestionsOnly
        default: return true
        }
    }
    private var canConfirm: Bool {
        !model.onboardingBusy && model.onboardingTestPassed &&
        (model.onboarding.isSuggestionsOnly || (model.onboarding.extensionAcknowledged &&
        model.hasSharedInbox))
    }
    @ViewBuilder private var page: some View {
        switch model.onboarding.step {
        case 1:
            Text("继续使用 Apple Mail。Mailpipe 为需要回复的来信准备草稿，由你审阅、编辑，再复制到 Mail 发送。")
            GroupBox("合成示例") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("请确认收到项目简报").font(.headline)
                    Text("colleague@example.com").foregroundStyle(.secondary)
                    Text("来信：请回复确认收到这份示例项目简报。")
                    Divider()
                    Text("回复草稿").font(.headline)
                    Text("已收到示例项目简报，谢谢。")
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("示例未读取邮件或调用模型。Mailpipe 不设邮件中转服务器；你选择的工具可能使用云端模型。")
                .font(.callout).foregroundStyle(.secondary)
        case 2:
            Picker("AI 工具", selection: $model.onboarding.executable) {
                Text("请选择工具").tag("")
                ForEach(Array(model.installations.enumerated()), id: \.element.id) { index, tool in
                    Text(tool.kind.displayName + (model.installations.count > 1 ? " \(index + 1)" : "")).tag(tool.executable.path)
                }
            }.disabled(model.onboardingBusy)
            Text("连接测试会将固定合成邮件交给所选工具配置的模型。最多两次调用，会消耗额度；不自动重试。")
                .foregroundStyle(.secondary)
            if model.installations.isEmpty { Text("未找到兼容工具。安装并登录工具后，在设置中重新查找。") }
            if model.onboardingBusy {
                ProgressView("正在连接…")
                Button("取消测试", action: model.cancelOnboardingTest)
            } else if model.onboardingTestPassed {
                Label("已连接到 \(toolName)", systemImage: "checkmark.circle")
                Button("重新测试") { model.resetOnboardingTest(); model.testOnboarding() }
            } else {
                Button("确认并测试连接") { model.resetOnboardingTest(); model.testOnboarding() }
                    .disabled(model.onboarding.executable.isEmpty)
                if model.onboardingResult != nil { Text("连接未成功。请检查工具登录和网络，再主动重试。") }
            }
        case 3:
            Text("在 Mail → 设置 → 扩展中启用 Mailpipe，并核对系统显示的权限。")
            Button("打开 Mail 扩展设置", action: model.openMailAndExtensionSettings).buttonStyle(.borderedProminent)
            Toggle("我已启用 Mailpipe 扩展", isOn: $model.onboarding.extensionAcknowledged)
            Text("确认处理方式后，扩展会采集新邮件。你可以随时在 Mail 中关闭扩展。")
                .foregroundStyle(.secondary)
            if model.extensionObservation != nil { Label("已收到扩展运行回执", systemImage: "checkmark.circle") }
            else { Text("尚未收到扩展运行回执。启用状态仍需收到新邮件后核对。") .foregroundStyle(.secondary) }
            Button("使用逐封建议，无需启用扩展", action: model.useSuggestions)
            if model.onboarding.isSuggestionsOnly { Text("已选择逐封建议，可继续。") }
        case 4:
            Picker("处理方式", selection: Binding(get: { model.onboarding.isSuggestionsOnly }, set: { model.onboarding.suggestionsOnly = $0; model.saveOnboarding() })) {
                Text("处理 MailKit 收到的新邮件").tag(false)
                Text("逐封建议").tag(true)
            }
            if model.onboarding.isSuggestionsOnly {
                Text("由你粘贴来信。每封先确认内容和工具，再提交处理。无需 Mail 自动化权限。")
            } else {
                Text("所有账户的新邮件均可交给所选 AI 工具分拣并准备草稿。")
                TextField("精确主题限制（可选）", text: $model.onboarding.exactSubject)
                Button("暂不授权，使用逐封建议", action: model.useSuggestions)
            }
        default:
            Label("已连接到 \(toolName)", systemImage: "checkmark.circle")
            if model.onboarding.isSuggestionsOnly { Text("逐封建议：只处理你确认提交的内容。") }
            else {
                Text("从所有账户的 MailKit 来信中准备回复。").font(.headline)
                if !model.onboarding.exactSubject.isEmpty { Text("仅处理主题：\(model.onboarding.exactSubject)") }
                Text("只交付主题与提取后的正文，不向模型交付附件内容。确认只授权未来的新邮件。")
            }
            Text("不移动、标记或发送邮件。已有暂停状态保持有效。草稿备好后，从菜单栏打开工作台审阅。")
                .foregroundStyle(.secondary)
            if !model.hasSharedInbox && !model.onboarding.isSuggestionsOnly { Text("共享容器不可用。可先使用逐封建议。") }
            if model.onboarding.completed { Label("配置已保存。可关闭窗口，在菜单栏查看草稿。", systemImage: "checkmark.circle") }
        }
    }
}

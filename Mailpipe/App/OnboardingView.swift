import SwiftUI
import HarnessAdapters

struct OnboardingView: View {
    @ObservedObject var model: PendingModel
    let onOpenWorkbench: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var titleFocused: Bool

    private var step: Int { model.onboarding.completed ? 5 : model.onboarding.step }
    private var manual: Bool { model.onboarding.isSuggestionsOnly }
    private var selectedTool: HarnessInstallation? {
        model.installations.first { $0.executable.path == model.onboarding.executable }
    }
    private var toolName: String { selectedTool?.kind.displayName ?? "已选 AI 工具" }
    private func displayPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
    private var tested: Bool {
        model.onboardingTestPassed && model.onboarding.testedExecutable == model.onboarding.executable
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        OnboardingArtwork(step: step)
                            .frame(width: 168, height: 100)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.title.bold())
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($titleFocused)
                        Text(introduction)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    page
                    if !model.onboarding.completed, let issue = model.onboardingIssue {
                        Label(issue, systemImage: "exclamationmark.circle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 390)
                .padding(.horizontal, 26)
                .padding(.top, model.onboarding.completed ? 48 : 12)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
            }
            .id(step)
            Divider()
            footer
        }
        .frame(minWidth: 450, idealWidth: 480, maxWidth: 480,
               minHeight: 410, idealHeight: 440, maxHeight: 440)
        .onChange(of: model.onboarding) { _ in model.saveOnboarding() }
        .onChange(of: title) { _ in titleFocused = true }
    }

    private var title: String {
        if model.onboarding.completed { return "设置已保存" }
        switch step {
        case 1: return "让来信变成回复草稿"
        case 2: return "连接你的 AI 工具"
        case 3: return manual ? "使用逐封建议" : "在 Mail 中启用扩展"
        case 4: return "选择处理哪些来信"
        default: return manual ? "确认逐封建议设置" : "确认来信授权"
        }
    }

    private var introduction: String {
        if model.onboarding.completed {
            if model.settings.paused { return "邮件处理仍已暂停。你可以先打开工作台查看草稿，准备好后再到设置中恢复处理。" }
            return manual
                ? "在工作台点“添加来信”，粘贴第一封想回复的邮件。提交前，你可以核对内容和工具。"
                : "Mailpipe 正在等待符合条件的新邮件。草稿准备好后，点菜单栏中的 Mailpipe 即可审阅。"
        }
        switch step {
        case 1:
            return "继续用 Apple Mail 收信。Mailpipe 帮你准备回复，由你审阅、修改和发送。下面是一封离线示例。"
        case 2:
            return "选择本机已安装的工具。测试会把一封合成邮件交给它配置的模型，调用一次并消耗额度。模型可能在云端运行。"
        case 3:
            return manual
                ? "你已选择逐封提交来信，无需启用 Mail 扩展。想让 Mailpipe 接收新邮件，也可以在这里更改选择。"
                : "要自动接收新邮件，请在“邮件”的“设置 › 扩展”中勾选 Mailpipe，核对权限后回到这里。"
        case 4:
            return manual
                ? "自己挑选想回复的来信。每次粘贴主题和正文，再确认内容及接收它的 AI 工具。"
                : "扩展可处理所有账户的新邮件。想先试用一类来信，可以限定一个完整的邮件主题。"
        default:
            return manual
                ? "保存后，只有你逐封确认提交的内容才会交给所选工具。"
                : "授权后，Mailpipe 会把符合条件的新邮件主题和正文交给所选工具配置的模型。附件内容不会交给模型。"
        }
    }

    @ViewBuilder private var page: some View {
        if !model.onboarding.completed {
            switch step {
            case 1:
                VStack(alignment: .leading, spacing: 10) {
                    sampleLine("合成来信", text: "请确认收到这份项目简报。", icon: "envelope")
                    Divider()
                    sampleLine("回复草稿", text: "简报已收到，谢谢！", icon: "arrowshape.turn.up.left")
                }
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
            case 2:
                connection
            case 3:
                mailExtension
            case 4:
                scope
            default:
                review
            }
        }
    }

    private func sampleLine(_ label: String, text: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(label, systemImage: icon).foregroundStyle(.secondary)
            Text(text)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var connection: some View {
        if model.installations.isEmpty {
            Text("未找到 DeepSeek Harness。安装并登录后，点“重新查找工具”。")
        } else {
            Picker(model.installations.count > 1 ? "DeepSeek Harness" : "AI 工具", selection: $model.onboarding.executable) {
                Text("请选择工具").tag("")
                ForEach(model.installations) { tool in
                    Text(model.installations.count > 1 ? displayPath(tool.executable.path) : tool.kind.displayName)
                        .tag(tool.executable.path)
                        .help(tool.executable.path)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .help(selectedTool?.executable.path ?? "选择要接收邮件内容的工具")
            .disabled(model.onboardingBusy)
        }
        if model.onboardingBusy {
            HStack {
                ProgressView().controlSize(.small)
                Text("正在用合成邮件测试连接…")
                Button("取消测试", action: model.cancelOnboardingTest)
            }
        } else if tested {
            HStack {
                Label("连接测试通过", systemImage: "checkmark.circle.fill")
                Spacer()
                Button("重新测试", action: testConnection)
            }
        } else if model.onboardingResult != nil {
            Text("测试未通过。请检查工具的登录状态与网络，再重新测试。")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var mailExtension: some View {
        if manual {
            Button("改为自动处理新邮件") { model.onboarding.suggestionsOnly = false }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("我已在 Mail 中启用 Mailpipe", isOn: $model.onboarding.extensionAcknowledged)
                    .toggleStyle(.checkbox)
                if model.extensionObservation != nil {
                    Label("近期已收到扩展运行回执", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if model.onboarding.extensionAcknowledged {
                    Text("已记录你的确认。扩展运行情况有待新邮件验证。")
                        .foregroundStyle(.secondary)
                }
                if model.onboarding.extensionAcknowledged {
                    Button("打开 Mail 扩展设置", action: model.openMailAndExtensionSettings)
                }
                Button("改用逐封建议") {
                    model.useSuggestions()
                    go(to: 4)
                }
                .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("处理方式", selection: Binding(
                get: { manual }, set: { model.onboarding.suggestionsOnly = $0 }
            )) {
                Text("自动处理新邮件").tag(false)
                Text("逐封建议").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if manual {
                Label("无需启用 Mail 扩展或授予 Mail 自动化权限。", systemImage: "hand.raised")
                    .foregroundStyle(.secondary)
            } else {
                TextField("精确主题（可选）", text: $model.onboarding.exactSubject)
                    .textFieldStyle(.roundedBorder)
                Text("留空表示所有主题。填写后，只处理主题完全相同的来信。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent("AI 工具", value: toolName)
            if !model.onboarding.executable.isEmpty {
                LabeledContent("安装位置") {
                    Text(displayPath(model.onboarding.executable))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.onboarding.executable)
                }
            }
            LabeledContent("来信范围", value: manual ? "逐封确认" : "所有账户的未来新邮件")
            if !manual, !model.onboarding.exactSubject.isEmpty {
                LabeledContent("精确主题", value: model.onboarding.exactSubject)
            }
            Divider()
            Text("Mailpipe 不会移动、标记或发送邮件。你可以随时在设置中暂停处理。")
                .foregroundStyle(.secondary)
            if !manual && !model.hasSharedInbox {
                Text("共享容器不可用。返回上一步可选择逐封建议。")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("第 \(step) 步，共 5 步")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if !model.onboarding.completed {
                Button("稍后继续") {
                    if model.saveOnboarding() { dismiss() }
                }
                    .buttonStyle(.link)
                    .padding(.trailing, 4)
                if step > 1 { Button("返回") { go(to: step - 1) } }
            }
            primaryButton
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .disabled(model.onboardingBusy)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var primaryButton: some View {
        if model.onboarding.completed {
            Button("打开工作台", action: onOpenWorkbench)
        } else {
            switch step {
            case 1:
                Button("开始设置") { go(to: 2) }
            case 2 where model.installations.isEmpty:
                Button("重新查找工具", action: model.rediscoverTools)
            case 2 where !tested:
                Button("确认并测试连接", action: testConnection).disabled(selectedTool == nil)
            case 3 where !model.onboarding.extensionAcknowledged && !manual:
                Button("打开 Mail 扩展设置", action: model.openMailAndExtensionSettings)
            case 4 where !manual && !model.onboarding.extensionAcknowledged:
                Button("前往启用扩展") { go(to: 3) }
            case 5:
                Button(manual ? "启用逐封建议" : "授权处理新邮件", action: model.finishOnboarding)
                    .disabled(!tested || (!manual && !(model.onboarding.extensionAcknowledged && model.hasSharedInbox)))
            default:
                Button("继续") { go(to: step + 1) }
            }
        }
    }

    private func go(to nextStep: Int) {
        model.onboardingIssue = nil
        model.onboarding.step = nextStep
    }

    private func testConnection() {
        model.resetOnboardingTest()
        model.testOnboarding()
    }
}

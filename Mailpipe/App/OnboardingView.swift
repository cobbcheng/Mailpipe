import SwiftUI
import HarnessAdapters

struct OnboardingView: View {
    @ObservedObject var model: PendingModel
    @AccessibilityFocusState private var titleFocused: Bool

    private var step: Int { model.onboarding.step }
    private var tool: HarnessInstallation? { model.installations.first }
    private var toolName: String { tool?.kind.displayName ?? "DeepSeek Harness" }
    private var tested: Bool {
        guard let tool else { return false }
        return model.onboardingTestPassed
            && model.onboarding.testedExecutable == tool.executable.path
            && model.onboarding.executable == tool.executable.path
    }
    private var manual: Bool { model.onboarding.isSuggestionsOnly }
    private var sourceSelection: Binding<Bool?> {
        Binding(
            get: { model.onboarding.suggestionsOnly ?? (model.onboarding.extensionAcknowledged ? false : nil) },
            set: { model.onboarding.suggestionsOnly = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        OnboardingArtwork(step: step)
                            .frame(width: 168, height: 100)
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
                    if let issue = model.onboardingIssue {
                        Label(issue, systemImage: "exclamationmark.circle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 390)
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .id(step)
            footer
        }
        .frame(minWidth: 450, idealWidth: 480, maxWidth: 480,
               minHeight: 410, idealHeight: 440, maxHeight: 440)
        .onChange(of: model.onboarding) { _ in model.saveOnboarding() }
        .onChange(of: title) { _ in titleFocused = true }
    }

    private var title: String {
        switch step {
        case 1: return "让来信变成回复草稿"
        case 2: return "连接你的 AI 工具"
        case 3: return "在 Mail 中启用扩展"
        case 4: return "怎样把来信交给 Mailpipe？"
        default: return manual ? "确认逐封建议设置" : "确认来信授权"
        }
    }

    private var introduction: String {
        switch step {
        case 1:
            return "继续用 Apple Mail 收信。Mailpipe 帮你准备回复，由你审阅、修改和发送。"
        case 2:
            return "点击连接后，Mailpipe 会用一封合成邮件测试一次。所选工具可能调用云端模型并消耗额度。"
        case 3:
            return "要自动接收来信，请在「邮件 → 设置 → 扩展」中勾选 Mailpipe，再回来确认。手动粘贴来信可以跳过这一步。"
        case 4:
            return "选择来信来源。Mailpipe 会把这个范围内的主题和正文交给 \(toolName) 准备回复草稿。"
        default:
            return manual
                ? "点击「开始使用」后，你可以在工作台添加来信。每封邮件都会在你确认后才交给所选工具。"
                : "点击「开始使用」即授权所选工具处理以下范围内的新邮件主题和正文。附件内容不会交给模型。"
        }
    }

    @ViewBuilder private var page: some View {
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
        case 2: connection
        case 3: mailExtension
        case 4: scope
        default: review
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
        if model.onboardingBusy {
            ProgressView("正在测试连接…").controlSize(.small)
            Button("取消测试", action: model.cancelOnboardingTest)
                .modifier(WorkbenchActionStyle())
        } else if let tool {
            if tested {
                Label("已连接到 \(toolName)", systemImage: "checkmark.circle")
            } else if model.onboardingResult != nil {
                Text("测试未通过。请检查工具的登录状态与网络，再重新连接。")
                    .foregroundStyle(.secondary)
            }
            Button(tested ? "重新测试连接" : "连接 \(toolName)") {
                if model.onboarding.testedExecutable == tool.executable.path {
                    model.resetOnboardingTest()
                }
                model.onboarding.executable = tool.executable.path
                model.testOnboarding()
            }
            .modifier(WorkbenchActionStyle())
            .help(tool.executable.path)
        } else {
            Text("未找到 DeepSeek Harness。安装并登录后，可重新查找。")
            Button("重新查找工具", action: model.rediscoverTools)
                .modifier(WorkbenchActionStyle())
        }
    }

    private var mailExtension: some View {
        VStack(spacing: 12) {
            Button("打开 Mail 扩展设置", action: model.openMailAndExtensionSettings)
                .modifier(WorkbenchActionStyle())
            Toggle("我已在 Mail 中启用 Mailpipe", isOn: $model.onboarding.extensionAcknowledged)
                .toggleStyle(.checkbox)
            if model.extensionObservation != nil {
                Label("近期已收到扩展运行回执", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else if model.onboarding.extensionAcknowledged {
                Text("已记录你的确认，等待新邮件验证扩展。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("来信来源", selection: sourceSelection) {
                Text("自动接收所有账户的新邮件").tag(Optional(false))
                Text("只处理我手动粘贴的邮件").tag(Optional(true))
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let manual = sourceSelection.wrappedValue {
                if manual {
                    Text("在工作台点「添加来信」，粘贴主题和正文，每封单独确认。")
                        .foregroundStyle(.secondary)
                } else {
                    TextField("限定邮件主题（可选，留空表示全部）", text: $model.onboarding.exactSubject)
                        .textFieldStyle(.roundedBorder)
                        .help("填写后，只处理主题完全相同的新邮件。")
                    if !model.onboarding.extensionAcknowledged {
                        Text("自动接收需要先在 Mail 中启用扩展。").foregroundStyle(.secondary)
                    } else if !model.hasSharedInbox {
                        Text("当前无法访问 Mail 扩展的共享容器。请检查安装，或选择手动粘贴。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent("AI 工具", value: toolName)
            if !model.onboarding.executable.isEmpty {
                LabeledContent("安装位置") {
                    Text((model.onboarding.executable as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.onboarding.executable)
                }
            }
            LabeledContent("来信范围", value: manual ? "仅手动粘贴的邮件" : "所有账户的未来新邮件")
            if !manual, !model.onboarding.exactSubject.isEmpty {
                LabeledContent("精确主题", value: model.onboarding.exactSubject)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("第 \(step) 步，共 5 步")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if step > 1 {
                Button("返回") { go(to: step - 1) }
                    .modifier(WorkbenchActionStyle())
            }
            primaryButton
                .modifier(WorkbenchActionStyle())
                .keyboardShortcut(.defaultAction)
        }
        .disabled(model.onboardingBusy)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case 1:
            Button("开始设置") { go(to: 2) }
        case 2:
            Button("继续") { go(to: 3) }.disabled(!tested)
        case 3:
            Button("继续") { go(to: 4) }
        case 4 where sourceSelection.wrappedValue == false && !model.onboarding.extensionAcknowledged:
            Button("前往启用扩展") { go(to: 3) }
        case 4:
            Button("继续") { go(to: 5) }
                .disabled(sourceSelection.wrappedValue == nil || (!manual && !model.hasSharedInbox))
        default:
            Button("开始使用", action: model.finishOnboarding)
                .disabled(!tested || (!manual && !(model.onboarding.extensionAcknowledged && model.hasSharedInbox)))
        }
    }

    private func go(to nextStep: Int) {
        model.onboardingIssue = nil
        model.onboarding.step = nextStep
    }
}

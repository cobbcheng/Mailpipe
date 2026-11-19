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
        case 1: return "让你的 Agent，帮你回邮件"
        case 2: return "连接你的 Agent"
        case 3: return "从 Apple Mail 接收新邮件"
        case 4: return "哪些来信交给 Agent？"
        default: return manual ? "确认逐封起草" : "授权 Agent 为新邮件起草回复"
        }
    }

    private var introduction: String {
        switch step {
        case 1:
            return "Mailpipe 在你的 Mac 上保存来信和草稿，只把你授权的内容交给所选 Agent 写回复。你审阅草稿，再决定是否发送。"
        case 2:
            return "点击连接，Agent 会用一封示例邮件试写回复。起草时，它会把邮件主题和正文发给 DeepSeek 云端模型，使用你的额度。"
        case 3:
            return "在 Apple Mail 的「邮件」→「设置」→「扩展」中勾选 Mailpipe，再回来确认。如果你想逐封粘贴来信，可以直接继续。"
        case 4:
            return "选好来信范围后，在下一步确认。\(toolName) 会用你授权的主题和正文起草回复。"
        default:
            return manual
                ? "点击「开始使用」后，你可以在工作台粘贴来信。每次先核对主题、正文和接收它们的 Agent，再提交这一封。"
                : "点击「开始使用」，即授权 Mailpipe 将以下范围内的新邮件主题和正文交给 Agent 写草稿。授权不含附件内容。"
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 1:
            VStack(alignment: .leading, spacing: 10) {
                sampleLine("示例来信", text: "简报已更新，收到请回信。", icon: "envelope")
                Divider()
                sampleLine("Agent 草稿", text: "收到更新的简报了，谢谢！", icon: "arrowshape.turn.up.left")
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
            ProgressView("正在用示例邮件测试连接…").controlSize(.small)
            Button("取消测试", action: model.cancelOnboardingTest)
                .modifier(WorkbenchActionStyle())
        } else if let tool {
            if tested {
                Label("已连接到 \(toolName)", systemImage: "checkmark.circle")
            } else if model.onboardingResult != nil {
                Text("连接失败。请检查 \(toolName) 的登录状态和网络，再试一次。")
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
            Text("这台 Mac 上还没找到 DeepSeek Harness。请先安装并登录。")
            Button("重新查找 Agent", action: model.rediscoverTools)
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
                Label("已检测到 Mail 扩展近期运行过", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else if model.onboarding.extensionAcknowledged {
                Text("已记录你的确认。收到新邮件后可验证扩展是否运行。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("来信来源", selection: sourceSelection) {
                Text("自动接收 Apple Mail 所有账户的新来信").tag(Optional(false))
                Text("由我手动粘贴来信").tag(Optional(true))
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let manual = sourceSelection.wrappedValue {
                if manual {
                    Text("在工作台粘贴主题和正文，确认后再交给 Agent。")
                        .foregroundStyle(.secondary)
                } else {
                    TextField("仅接收这个主题（留空表示所有主题）", text: $model.onboarding.exactSubject)
                        .textFieldStyle(.roundedBorder)
                        .help("填写后，只处理主题完全相同的新邮件。")
                    if !model.onboarding.extensionAcknowledged {
                        Text("自动接收需要先在 Mail 中启用扩展。").foregroundStyle(.secondary)
                    } else if !model.hasSharedInbox {
                        Text("Mailpipe 无法读取扩展的共享目录。请检查安装，或改为手动粘贴。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent("起草回复的 Agent", value: toolName)
            if !model.onboarding.executable.isEmpty {
                LabeledContent("安装位置") {
                    Text((model.onboarding.executable as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.onboarding.executable)
                }
            }
            LabeledContent("来信范围", value: manual ? "仅我粘贴并确认的邮件" : "Apple Mail 所有账户今后的新来信")
            if !manual, !model.onboarding.exactSubject.isEmpty {
                LabeledContent("主题完全匹配", value: model.onboarding.exactSubject)
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

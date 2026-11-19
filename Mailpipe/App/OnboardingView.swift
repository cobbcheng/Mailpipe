import AppKit
import SwiftUI
import HarnessAdapters
import MailpipeCore

extension HarnessKind {
    var modelServiceDescription: String {
        switch self {
        case .deepseek: "DeepSeek 云端模型"
        case .claude, .opencode: "\(displayName) 配置的模型服务"
        case .codex: "Codex CLI 配置的模型服务"
        }
    }
}

struct ReplyToolPicker: View {
    @ObservedObject var model: PendingModel

    var body: some View {
        LabeledContent("起草回复的 Agent") {
            AgentPopUpButton(tools: model.installations, selectedID: model.selectedTool?.id,
                             isEnabled: !model.onboardingBusy, select: model.selectTool)
                .modifier(AgentMenuSurface())
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AgentMenuSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.frame(height: 30).glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
        }
    }
}

private struct AgentPopUpButton: NSViewRepresentable {
    let tools: [HarnessInstallation]
    let selectedID: String?
    let isEnabled: Bool
    let select: (HarnessInstallation) -> Void

    final class Coordinator: NSObject {
        var parent: AgentPopUpButton
        init(_ parent: AgentPopUpButton) { self.parent = parent }

        @objc func choose(_ sender: NSPopUpButton) {
            if let id = sender.selectedItem?.representedObject as? String,
               let tool = parent.tools.first(where: { $0.id == id }) {
                parent.select(tool)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        if #available(macOS 26, *) { button.isBordered = false }
        button.controlSize = .large
        button.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("起草回复的 Agent")
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let ids = tools.map(\.id)
        if button.itemArray.compactMap({ $0.representedObject as? String }) != ids ||
            (button.itemArray.first?.tag == -1) != (selectedID == nil) {
            button.removeAllItems()
            if selectedID == nil {
                button.addItem(withTitle: "选择 Agent")
                button.lastItem?.tag = -1
            }
            for tool in tools {
                let name = tool.kind.displayName
                let duplicated = tools.filter { $0.kind == tool.kind }.count > 1
                let path = (tool.executable.path as NSString).abbreviatingWithTildeInPath
                button.addItem(withTitle: duplicated ? "\(name) · \(path)" : name)
                button.lastItem?.representedObject = tool.id
            }
        }
        if let selectedID {
            button.selectItem(at: button.indexOfItem(withRepresentedObject: selectedID))
        } else {
            button.selectItem(withTag: -1)
        }
        button.isEnabled = isEnabled
    }
}

struct OpenCodeModelField: View {
    @ObservedObject var model: PendingModel

    var body: some View {
        if model.onboarding.harnessKind == .opencode {
            TextField("供应方/模型（可选）", text: Binding(get: { model.onboarding.openCodeModel ?? "" },
                                                    set: { model.onboarding.openCodeModel = $0 }))
                .textFieldStyle(.roundedBorder)
                .disabled(model.onboardingBusy)
            Text("可从 opencode models 选择。留空时，示例邮件使用隔离环境的默认模型。授权后，新来信固定使用试写成功的模型。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: PendingModel
    @AccessibilityFocusState private var titleFocused: Bool

    private var step: Int { model.onboarding.step }
    private var tool: HarnessInstallation? { model.selectedTool }
    private var toolName: String { tool?.kind.displayName ?? "所选 Agent" }
    private var tested: Bool { model.onboardingTestPassed }

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
        default: return "授权 Agent 为新邮件起草回复"
        }
    }

    private var introduction: String {
        switch step {
        case 1:
            return "Mailpipe 在你的 Mac 上保存来信和草稿，只把你授权的内容交给所选 Agent 写回复。你审阅草稿，再决定是否发送。"
        case 2:
            return "连接时，Mailpipe 会用一封示例邮件试写回复。示例主题和正文将发给\(model.onboarding.harnessKind.modelServiceDescription)，会消耗你的额度。"
        case 3:
            return "在 Apple Mail 的「邮件」→「设置」→「扩展」中勾选 Mailpipe，再回来确认。"
        case 4:
            return "来信来自 Apple Mail 的所有账户。你可以限定邮件主题，在下一步确认交给 \(toolName) 的范围。"
        default:
            return "点击「开始使用」，即授权 Mailpipe 将以下范围内的新邮件主题和正文交给 Agent 写草稿。授权不含附件内容。"
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
        if model.installations.count > 1 || (tool == nil && !model.installations.isEmpty) {
            ReplyToolPicker(model: model)
        }
        if model.onboardingBusy {
            ProgressView("正在用示例邮件测试连接…").controlSize(.small)
            Button("取消测试", action: model.cancelOnboardingTest)
                .modifier(WorkbenchActionStyle())
        } else if let tool {
            if tested {
                Label(model.connectionLabel, systemImage: "checkmark.circle")
            }
            Button(tested ? "重新测试连接" : "连接 \(toolName)", action: model.testOnboarding)
            .modifier(WorkbenchActionStyle())
            .help(tool.executable.path)
        } else if model.installations.isEmpty {
            Text("未找到可用的 Agent。请先安装并配置 OpenCode、Claude Code 或 DeepSeek Harness。")
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
            if !model.hasSharedInbox {
                Text("Mailpipe 无法读取扩展的共享目录。请检查安装。")
                    .foregroundStyle(.secondary)
            } else if model.extensionObservation != nil {
                Label("已检测到 Mail 扩展近期运行过", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else if model.onboarding.extensionAcknowledged {
                Text("已记录你的确认。收到新邮件后可验证扩展是否运行。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scope: some View {
        TextField("仅接收这个主题（留空表示所有主题）", text: $model.onboarding.exactSubject)
            .textFieldStyle(.roundedBorder)
            .help("填写后，只处理主题完全相同的新邮件。")
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent("起草回复的 Agent", value: toolName)
            if let modelName = model.onboardingResult?.runs.last?.destination.model {
                LabeledContent("试写使用的模型", value: modelName)
            }
            if !model.onboarding.executable.isEmpty {
                LabeledContent("安装位置") {
                    Text((model.onboarding.executable as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.onboarding.executable)
                }
            }
            LabeledContent("来信范围", value: "Apple Mail 所有账户今后的新来信")
            if !model.onboarding.exactSubject.isEmpty {
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
                .disabled(!model.onboarding.extensionAcknowledged || !model.hasSharedInbox)
        case 4:
            Button("继续") { go(to: 5) }
        default:
            Button("开始使用", action: model.finishOnboarding)
                .disabled(!tested || !model.onboarding.extensionAcknowledged || !model.hasSharedInbox)
        }
    }

    private func go(to nextStep: Int) {
        model.onboardingIssue = nil
        model.onboarding.step = nextStep
    }
}

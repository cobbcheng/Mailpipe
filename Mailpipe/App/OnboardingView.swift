import AppKit
import SwiftUI
import HarnessAdapters
import MailpipeCore

extension HarnessKind {
    var modelServiceDescription: String {
        switch self {
        case .deepseek, .openclaw, .hermes: L("the DeepSeek cloud model")
        case .claude, .opencode: L("the model service configured in %1$@", String(describing: displayName))
        case .codex: L("OpenAI (GPT-6.2 Sol via Codex CLI)")
        }
    }
}

struct ReplyToolPicker: View {
    @ObservedObject var model: PendingModel

    var body: some View {
        LabeledContent(L("Drafting agent")) {
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
        button.setAccessibilityLabel(L("Drafting agent"))
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
                button.addItem(withTitle: L("Choose agent"))
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

struct OnboardingView: View {
    @ObservedObject var model: PendingModel
    @AccessibilityFocusState private var titleFocused: Bool

    private var step: Int { model.onboarding.step }
    private var tool: HarnessInstallation? { model.selectedTool }
    private var toolName: String { tool?.kind.displayName ?? L("Selected agent") }
    private var tested: Bool { model.onboardingTestPassed }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        OnboardingArtwork(step: step)
                            .frame(width: step == 4 ? 320 : 168, height: step == 4 ? 192 : 100)
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
        case 1: return L("Let your agent draft your replies")
        case 2: return L("Connect your agent")
        case 3: return L("Receive new messages from Apple Mail")
        case 4: return L("Use Mailpipe while you write")
        default: return L("Authorize replies to new messages")
        }
    }

    private var introduction: String {
        switch step {
        case 1:
            return L("Mailpipe stores messages and drafts on your Mac. Your chosen agent receives only authorized content. Review each draft and decide whether to send it.")
        case 2:
            return L("Mailpipe will test drafting with a sample subject and body sent to %1$@. This uses your quota.", String(describing: model.onboarding.harnessKind.modelServiceDescription))
        case 3:
            return L("In Apple Mail, open Mail → Settings → Extensions, enable Mailpipe, then return here.")
        case 4:
            return L("When replying or forwarding, click Mailpipe in the compose toolbar to review or generate a draft.")
        default:
            return L("Choose Get started to allow Mailpipe to share the subjects and bodies of new messages in the scope below with your agent for drafting. Attachment contents are excluded.")
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 1:
            VStack(alignment: .leading, spacing: 10) {
                sampleLine(L("Sample message"), text: L("The brief has been updated. Please confirm receipt."), icon: "envelope")
                Divider()
                sampleLine(L("Agent draft"), text: L("Thanks, I received the updated brief!"), icon: "arrowshape.turn.up.left")
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
        case 2: connection
        case 3: mailExtension
        case 4: EmptyView()
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
            ProgressView(L("Testing with a sample message…")).controlSize(.small)
            Button(L("Cancel test"), action: model.cancelOnboardingTest)
                .modifier(WorkbenchActionStyle())
        } else if let tool {
            if tested {
                Label(model.connectionLabel, systemImage: "checkmark.circle")
            }
            Button(tested ? L("Retest connection") : L("Connect %1$@", String(describing: toolName)), action: model.testOnboarding)
            .modifier(WorkbenchActionStyle())
            .help(tool.executable.path)
        } else if model.installations.isEmpty {
            Text(L("No available agent found. Install and configure a supported agent first."))
            Button(L("Find agents again"), action: model.rediscoverTools)
                .modifier(WorkbenchActionStyle())
        }
    }

    private var mailExtension: some View {
        VStack(spacing: 12) {
            Button(L("Open Mail extension settings"), action: model.openMailAndExtensionSettings)
                .modifier(WorkbenchActionStyle())
            Toggle(L("I enabled Mailpipe in Mail"), isOn: $model.onboarding.extensionAcknowledged)
                .toggleStyle(.checkbox)
            if !model.hasSharedInbox {
                Text(L("Mailpipe cannot read the extension’s shared folder. Check the installation."))
                    .foregroundStyle(.secondary)
            } else if model.extensionObservation != nil {
                Label(L("Recent Mail extension activity detected"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else if model.onboarding.extensionAcknowledged {
                Text(L("Confirmation saved. The next message can verify extension activity."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var scope: some View {
        TextField(L("Exact subject (leave blank for all)"), text: $model.onboarding.exactSubject)
            .textFieldStyle(.roundedBorder)
            .help(L("Only new messages with this exact subject will be processed."))
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent(L("Drafting agent"), value: toolName)
            if let modelName = model.onboardingResult?.runs.last?.destination.model {
                LabeledContent(L("Model used for test"), value: modelName)
            }
            if !model.onboarding.executable.isEmpty {
                LabeledContent(L("Installation location")) {
                    Text((model.onboarding.executable as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.onboarding.executable)
                }
            }
            scope
            LabeledContent(L("Message scope"), value: model.onboarding.exactSubject.isEmpty
                ? L("Future messages in all Apple Mail accounts")
                : L("Only new messages with the subject “%1$@”", model.onboarding.exactSubject))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(L("Step %1$@ of 5", String(describing: step)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if step > 1 {
                Button(L("Back")) { go(to: step - 1) }
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
            Button(L("Start setup")) { go(to: 2) }
        case 2:
            Button(L("Continue")) { go(to: 3) }.disabled(!tested)
        case 3:
            Button(L("Continue")) { go(to: 4) }
                .disabled(!model.onboarding.extensionAcknowledged || !model.hasSharedInbox)
        case 4:
            Button(L("Continue")) { go(to: 5) }
        default:
            Button(L("Get started"), action: model.finishOnboarding)
                .disabled(!tested || !model.onboarding.extensionAcknowledged || !model.hasSharedInbox)
        }
    }

    private func go(to nextStep: Int) {
        model.onboardingIssue = nil
        model.onboarding.step = nextStep
    }
}

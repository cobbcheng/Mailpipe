import SwiftUI
import AppKit
import HarnessAdapters
import MailBridge
import MailpipeCore

@MainActor
final class WorkbenchModel: ObservableObject {
    @Published var installations: [HarnessInstallation] = []
    @Published var reports: [String: String] = [:]
    @Published var busyIDs: Set<String> = []

    func discover() { installations = HarnessDiscovery.find() }
    func inspect(_ installation: HarnessInstallation) {
        guard busyIDs.insert(installation.id).inserted else { return }
        Task {
            defer { busyIDs.remove(installation.id) }
            do {
                let report = try await installation.inspect()
                reports[installation.id] = "\(report.version) · \(report.supportsHeadlessRun ? L("All required arguments available") : L("Required arguments missing"))"
            } catch {
                reports[installation.id] = L("Check failed: %1$@", String(describing: (error as? MailpipeError)?.rawValue ?? "operationFailed"))
            }
        }
    }
}

@main
enum MailpipeEntryPoint {
    @MainActor static func main() {
        if MailReadBridge.runHelperIfRequested() { return }
        // LSUIElement keeps every read helper out of the Dock from launch.
        // Only the interactive host presents a regular application.
        NSApplication.shared.setActivationPolicy(.regular)
        MailpipeApp.main()
    }
}

@MainActor
private final class MailpipeAppDelegate: NSObject, NSApplicationDelegate {
    private var present: (() -> Void)?
    private var awaitingWindow = false

    func connect(_ action: OpenWindowAction) {
        present = { action.openMailpipe() }
        if awaitingWindow {
            awaitingWindow = false
            present?()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        guard event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) == nil,
              event?.paramDescriptor(forKeyword: keyAELaunchedAsServiceItem) == nil else { return }
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    private func showMainWindow() {
        // AppKit can deliver the event before the menu bar label supplies SwiftUI's window action.
        if let present { present() }
        else { awaitingWindow = true }
    }
}

extension OpenWindowAction {
    @MainActor func openMailpipe() {
        self(id: "workbench")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MailpipeApp: App {
    @NSApplicationDelegateAdaptor(MailpipeAppDelegate.self) private var appDelegate
    @StateObject private var model = WorkbenchModel()
    @StateObject private var pending = PendingModel()
    @AppStorage(AppLanguage.key) private var language = AppLanguage.english.rawValue
    var body: some Scene {
        MenuBarExtra {
            PendingMenu(model: pending).environment(\.locale, Locale(identifier: language)).id(language)
        } label: {
            LaunchStatusIcon(appDelegate: appDelegate)
        }.menuBarExtraStyle(.menu)
        Window("Mailpipe", id: "workbench") {
            if pending.onboarding.completed {
                PendingWorkbench(model: pending).environment(\.locale, Locale(identifier: language)).id(language).frame(minWidth: 660, minHeight: 380)
            } else {
                OnboardingView(model: pending).environment(\.locale, Locale(identifier: language)).id(language)
                    .navigationTitle(L("Get started with Mailpipe"))
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: pending.onboarding.completed ? 900 : 480,
                     height: pending.onboarding.completed ? 580 : 440)
        .commands {
            CommandGroup(after: .newItem) {
                WorkbenchCommand(model: pending).environment(\.locale, Locale(identifier: language)).id(language)
            }
        }
        Settings {
            if pending.onboarding.completed {
                MailpipeSettings(model: pending, diagnostics: model).environment(\.locale, Locale(identifier: language)).id(language)
            } else {
                InitialSetupSettings(model: pending).environment(\.locale, Locale(identifier: language)).id(language)
            }
        }
    }
}

private struct LaunchStatusIcon: View {
    let appDelegate: MailpipeAppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image("MenuBarIcon").accessibilityLabel("Mailpipe")
            .onAppear { appDelegate.connect(openWindow) }
    }
}

private struct WorkbenchCommand: View {
    @ObservedObject var model: PendingModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(model.onboarding.completed ? L("Open workbench") : L("Continue Mailpipe setup")) { openWindow.openMailpipe() }
            .keyboardShortcut("1", modifiers: .command)
    }
}

private struct InitialSetupSettings: View {
    @ObservedObject var model: PendingModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            LanguagePicker()
            Text(L("Connect your agent, then choose which messages it can draft replies for."))
            if model.settings.permission != nil {
                // Older versions could leave an active grant alongside an unfinished setup draft.
                if !model.settings.paused { Button(L("Pause processing"), action: model.togglePause) }
                Button(L("Revoke existing mail authorization"), role: .destructive, action: model.revoke)
            }
            Button(L("Continue Mailpipe setup")) {
                dismiss()
                openWindow.openMailpipe()
            }.keyboardShortcut(.defaultAction)
        }.padding(32)
    }
}

struct MailpipeSettings: View {
    @ObservedObject var model: PendingModel
    @ObservedObject var diagnostics: WorkbenchModel
    @State private var selectedTab = Tab.general
    private enum Tab { case general, scope, agent, privacy }
    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                LanguagePicker()
                Section(L("Reply drafts")) {
                    Text(model.settings.paused ? L("Sending messages to the agent is paused.") : L("Your agent can draft replies only for authorized messages."))
                    Button(model.settings.paused ? L("Resume processing") : L("Pause processing"), action: model.togglePause)
                    Text(L("Drafts stay on this Mac. Review them from the menu bar and send from Apple Mail."))
                        .foregroundStyle(.secondary)
                }
                configurationFooter()
            }.formStyle(.grouped).tabItem { Label(L("General"), systemImage: "gearshape") }.tag(Tab.general)
            Form {
                Section(L("Incoming mail")) {
                    Text(L("Once authorized, Mailpipe gives %1$@ the subject and body of new messages from all Apple Mail accounts to send to %2$@. Enter a subject to require an exact match.", String(describing: model.onboarding.harnessKind.displayName), String(describing: model.onboarding.harnessKind.modelServiceDescription))).foregroundStyle(.secondary)
                    if model.onboarding.harnessKind == .opencode, let modelID = model.onboardingResult?.runs.last?.destination.model {
                        LabeledContent(L("Authorized model"), value: modelID)
                    }
                    TextField(L("Limit by subject (optional)"), text: $model.onboarding.exactSubject)
                    Button(L("Open Mail extension settings"), action: model.openMailAndExtensionSettings)
                    Toggle(L("I enabled the extension in Mail"), isOn: $model.onboarding.extensionAcknowledged)
                }
                configurationFooter(confirmsScope: true)
            }.formStyle(.grouped).tabItem { Label(L("Incoming mail"), systemImage: "envelope") }.tag(Tab.scope)
            Form {
                Section(L("Drafting agent")) {
                    ReplyToolPicker(model: model)
                    Text(L("Testing sends a sample message to %1$@ for drafting and uses your quota.", String(describing: model.onboarding.harnessKind.modelServiceDescription))).foregroundStyle(.secondary)
                    if model.onboardingBusy {
                        ProgressView(L("Connecting…"))
                        Button(L("Cancel test"), action: model.cancelOnboardingTest)
                    } else if model.onboardingTestPassed {
                        Label(model.connectionLabel, systemImage: "checkmark.circle")
                        Button(L("Test again"), action: model.testOnboarding)
                    } else {
                        Button(L("Confirm and test connection"), action: model.testOnboarding).disabled(model.selectedTool == nil)
                    }
                }
                configurationFooter()
                Section {
                    DisclosureGroup(L("Advanced diagnostics")) {
                        Button(L("Find agents again"), action: model.rediscoverTools)
                        ForEach(model.installations) { tool in
                            Text(tool.executable.path).textSelection(.enabled)
                            Button(L("Check version and arguments")) { diagnostics.inspect(tool) }.disabled(diagnostics.busyIDs.contains(tool.id))
                            if let report = diagnostics.reports[tool.id] { Text(report) }
                        }
                        if let issue = model.issue { Text(issue).textSelection(.enabled) }
                        if let result = model.onboardingResult {
                            ForEach(result.runs, id: \.destination.runID) { run in
                                Text(L("Input tokens: %1$@ · Output tokens: %2$@", String(describing: run.inputTokens.map(String.init) ?? L("unknown")), String(describing: run.outputTokens.map(String.init) ?? L("unknown"))))
                                Text(L("Input characters: %1$@ · Output: %2$@ · Actual cost unknown", String(describing: run.inputCharacters.map(String.init) ?? L("unknown")), String(describing: run.outputCharacters.map(String.init) ?? L("unknown"))))
                            }
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Agent", systemImage: "sparkles") }.tag(Tab.agent)
            Form {
                Section(L("Privacy and data")) {
                    Text(L("Mailpipe stores mail, drafts and settings on this Mac. Only authorized subjects and message bodies go to your agent."))
                    Text(L("%1$@ sends this content to %2$@. Mailpipe excludes attachment contents.", String(describing: model.settings.harnessKind.displayName), String(describing: model.settings.harnessKind.modelServiceDescription)))
                    if model.settings.harnessKind == .deepseek {
                        Text(L("For GitHub PR links, the agent can check public changes. Access through your GitHub account requires separate confirmation."))
                    }
                    Button(L("Revoke mail authorization"), role: .destructive, action: model.revoke)
                    Text(L("After revocation, the agent stops processing new mail. Existing drafts stay on this Mac.")).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label(L("Privacy and data"), systemImage: "hand.raised") }.tag(Tab.privacy)
        }.frame(width: 660, height: 520)
            .onChange(of: model.onboarding) { _ in model.saveOnboarding() }
    }
    private func configurationFooter(confirmsScope: Bool = false) -> some View {
        Section {
            if let issue = model.onboardingIssue { Text(issue).foregroundStyle(.secondary) }
            if !confirmsScope && (model.requiresToolConsent || model.needsPermissionRecovery) {
                Button(L("Confirm mail scope and authorization")) { selectedTab = .scope }
            } else {
                Button(model.requiresToolConsent || model.needsPermissionRecovery ? L("Allow %1$@ to process new messages", String(describing: model.onboarding.harnessKind.displayName)) : L("Save settings"), action: model.applyConfiguration)
                    .disabled(model.onboardingBusy || !model.onboardingTestPassed || !model.onboarding.extensionAcknowledged || !model.hasSharedInbox)
            }
        }
    }
}

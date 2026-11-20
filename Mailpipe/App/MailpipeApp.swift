import SwiftUI
import AppKit
import UserNotifications
import HarnessAdapters
import MailBridge
import MailpipeCore
import MailpipeRuntime

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
        AppAppearance.saved.apply()
        MailpipeApp.main()
    }
}

@MainActor
private final class MailpipeAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private enum Destination { case workbench, readyReply }
    private var present: ((Destination) -> Void)?
    private var awaitingWindow: Destination?
    lazy var pending = PendingModel()
    let updates = AppUpdates()

    func connect(_ action: OpenWindowAction, model: PendingModel) {
        present = { destination in
            if destination == .readyReply { model.selectLatestReadyReply() }
            action.openMailpipe()
        }
        if let destination = awaitingWindow {
            awaitingWindow = nil
            present?(destination)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !ProcessInfo.processInfo.arguments.contains("--pipeline-directory") {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier == ReadyReplyReminders.identifier ? [.banner, .list] : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.identifier == ReadyReplyReminders.identifier else { return }
        await showMainWindow(.readyReply)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updates.start()
        let event = NSAppleEventManager.shared().currentAppleEvent
        guard event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) == nil,
              event?.paramDescriptor(forKeyword: keyAELaunchedAsServiceItem) == nil else { return }
        showMainWindow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard updates.installationPending else { return .terminateNow }
        if let blocker = pending.terminationBlocker() {
            switch blocker {
            case .workInProgress:
                return postponeInstallation(L("Let the current Mailpipe task finish, then try installing again."))
            case .unsavedDraft:
                return postponeInstallation(L("A draft could not be saved. Review your edits before installing the update."))
            }
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").isEmpty {
            return postponeInstallation(L("Quit Apple Mail, then try installing again. You can reopen Mail after the update to load the new extension."))
        }
        return .terminateNow
    }

    private func postponeInstallation(_ reason: String) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = L("Mailpipe update is waiting")
        alert.informativeText = reason
        alert.runModal()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    private func showMainWindow(_ destination: Destination = .workbench) {
        // AppKit can deliver the event before the menu bar label supplies SwiftUI's window action.
        if let present { present(destination) }
        else if awaitingWindow != .readyReply { awaitingWindow = destination }
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
    @StateObject private var pending: PendingModel
    init() {
        let delegate = _appDelegate.wrappedValue
        _pending = StateObject(wrappedValue: delegate.pending)
    }
    @AppStorage(AppLanguage.key) private var language = AppLanguage.english.rawValue
    var body: some Scene {
        MenuBarExtra {
            PendingMenu(model: pending, updates: appDelegate.updates).environment(\.locale, Locale(identifier: language)).id(language)
        } label: {
            LaunchStatusIcon(appDelegate: appDelegate, model: pending)
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
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updates: appDelegate.updates).id(language)
            }
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
    let model: PendingModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image("MenuBarIcon").accessibilityLabel("Mailpipe")
            .onAppear { appDelegate.connect(openWindow, model: model) }
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
            AppearancePicker()
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
    private enum Tab { case general, replies, scope, agent, privacy }
    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                LanguagePicker()
                AppearancePicker()
                Section(L("Reply drafts")) {
                    Text(model.settings.paused ? L("Sending messages to the agent is paused.") : L("Your agent can draft replies only for authorized messages."))
                    Button(model.settings.paused ? L("Resume processing") : L("Pause processing"), action: model.togglePause)
                    Text(L("Drafts stay on this Mac. Review them from the menu bar and send from Apple Mail."))
                        .foregroundStyle(.secondary)
                }
                if let reminders = model.reminders {
                    ReplyReminderSettings(reminders: reminders)
                }
                configurationFooter()
            }.formStyle(.grouped).tabItem { Label(L("General"), systemImage: "gearshape") }.tag(Tab.general)
            ReplyPromptSettings(model: model)
                .tabItem { Label(L("Replies"), systemImage: "arrowshape.turn.up.left") }.tag(Tab.replies)
            Form {
                Section(L("Incoming mail")) {
                    Text(L("Once authorized, %1$@ sends %2$@ the subject and body of new messages from all Apple Mail accounts, along with any saved reply prompt. Enter a subject to require an exact match.", String(describing: model.onboarding.harnessKind.displayName), String(describing: model.onboarding.harnessKind.modelServiceDescription))).foregroundStyle(.secondary)
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
                    Text(L("Mailpipe stores mail, drafts and settings on this Mac. Your agent receives the subject and body of authorized messages along with any reply prompt you save."))
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

private struct ReplyPromptSettings: View {
    @ObservedObject var model: PendingModel
    @State private var edit: String?
    @State private var feedback: String?

    private var savedPrompt: String { model.settings.replyInstructions ?? "" }
    private var prompt: Binding<String> {
        Binding(get: { edit ?? savedPrompt }, set: {
            edit = $0
            feedback = nil
        })
    }

    var body: some View {
        let trimmed = prompt.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = ReplyDraftRequest.maxReplyInstructionLength
        let exceedsLimit = trimmed.unicodeScalars.count > limit
        Form {
            Section(L("Reply prompt")) {
                Text(L("Mailpipe sends these instructions to %1$@ for new drafts and when you regenerate a reply. Clear the prompt and save to use the default.", model.settings.harnessKind.displayName))
                    .foregroundStyle(.secondary)
                TextEditor(text: prompt)
                    .font(.body)
                    .frame(height: 160)
                    .accessibilityLabel(L("Reply prompt"))
                    .overlay(alignment: .topLeading) {
                        if prompt.wrappedValue.isEmpty {
                            Text(L("For example, reply in the sender’s language and use at most two paragraphs."))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                HStack {
                    Button(L("Clear prompt")) { prompt.wrappedValue = "" }
                        .disabled(prompt.wrappedValue.isEmpty)
                    Spacer()
                    Button(L("Save prompt")) {
                        do {
                            try model.saveReplyInstructions(trimmed)
                            edit = nil
                            feedback = L("Reply prompt saved.")
                        } catch {
                            feedback = L("Could not save the reply prompt. Try again.")
                        }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(exceedsLimit || trimmed == savedPrompt)
                }
                if exceedsLimit {
                    Text(L("Shorten your prompt to %1$@ characters or fewer.", String(limit)))
                } else if let feedback {
                    Text(feedback)
                }
            }
        }.formStyle(.grouped)
    }
}

private struct ReplyReminderSettings: View {
    @ObservedObject var reminders: ReadyReplyReminders
    @AppStorage(ReplyReminderSchedule.minuteKey) private var minuteOfDay = ReplyReminderSchedule.defaultMinuteOfDay

    // The picker edits a wall-clock time. A fixed zone lets people select even a skipped DST hour.
    private var time: Binding<Date> {
        Binding(get: {
            let minute = (0..<1440).contains(minuteOfDay) ? minuteOfDay : ReplyReminderSchedule.defaultMinuteOfDay
            return Date(timeIntervalSinceReferenceDate: TimeInterval(minute * 60))
        }, set: { date in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            minuteOfDay = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        })
    }

    var body: some View {
        Section {
            DatePicker(L("Remind me at"), selection: time, displayedComponents: .hourAndMinute)
                .environment(\.timeZone, .gmt)
            if reminders.authorization == .notDetermined {
                Button(L("Allow notifications…")) {
                    Task { await reminders.requestAuthorization() }
                }
            } else if reminders.authorization != nil {
                if reminders.authorization == .denied {
                    Text(L("To receive reminders, allow notifications for Mailpipe in System Settings."))
                        .foregroundStyle(.secondary)
                }
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    Link(L("Open notification settings"), destination: url)
                }
            }
            if let issue = reminders.deliveryIssue { Text(issue).foregroundStyle(.secondary) }
        } header: {
            Text(L("Daily reply reminder"))
        } footer: {
            Text(L("Mailpipe checks for ready replies once a day while running. If it misses the scheduled time, it checks when it next runs that day."))
        }
        .task { await reminders.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reminders.refreshAuthorization() }
        }
    }
}

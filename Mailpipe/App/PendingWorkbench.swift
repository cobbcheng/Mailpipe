import SwiftUI
import AppKit
import MailpipeCore
import MailpipeRuntime
import HarnessAdapters
import MailBridge

enum UpdateRestartBlocker {
    case workInProgress, unsavedDraft
}

@MainActor
final class PendingModel: ObservableObject {
    @Published var records: [StoredReply] = []
    @Published var settings = PipelineSettings()
    @Published var issue: String?
    @Published var selectedID: String?
    @Published var installations: [HarnessInstallation] = []
    @Published var onboarding = OnboardingDraft()
    @Published var onboardingResult: StoredReply?
    @Published var onboardingBusy = false
    @Published var onboardingIssue: String?
    @Published var extensionObservation: ExtensionObservation?
    private var onboardingSession: OnboardingSession?
    private var onboardingTask: Task<Void, Never>?
    private var configurationSave: Task<Void, Never>?
    private var pipeline: ReplyPipeline?
    private var worker: Task<Void, Never>?
    private var display: Task<Void, Never>?
    private var panelExchange: ComposePanelExchange?
    private var panelTasks: [UUID: (request: ComposePanelRequest, task: Task<Void, Never>)] = [:]
    let reminders: ReadyReplyReminders?
    private(set) var hasSharedInbox = false
    var needsPermissionRecovery: Bool { onboarding.completed && settings.permission?.delivery != .mailKit }
    var requiresToolConsent: Bool {
        onboarding.completed && (onboarding.harnessKind != settings.harnessKind || onboarding.executable != settings.executable ||
            (onboarding.harnessKind == .opencode && (onboardingResult?.runs.last?.destination.model ?? onboarding.requestedModel) != settings.openCodeModel))
    }
    var selectedTool: HarnessInstallation? {
        installations.first { $0.kind == onboarding.harnessKind && $0.executable.path == onboarding.executable }
    }
    var pending: [StoredReply] { records.filter { $0.discardedAt == nil && $0.canDisplayInWorkbench && ($0.state.isPending || $0.isPreparing || $0.state == .needsReview || $0.state == .awaitingBody) } }
    var workbenchRecords: [StoredReply] { records.filter { $0.discardedAt == nil && $0.canDisplayInWorkbench } }
    var readyReplyCount: Int {
        let now = Date()
        return records.lazy.filter { $0.isReadyForReplyReminder(settings: self.settings, now: now) }.count
    }
    var unreadCount: Int { workbenchRecords.lazy.filter { self.isUnread($0) }.count }

    func isUnread(_ item: StoredReply) -> Bool {
        guard let version = item.draftVersion else { return false }
        return UserDefaults.standard.string(forKey: item.lastOpenedVersionKey) != version
    }

    func markOpened(_ item: StoredReply) {
        guard let version = item.draftVersion,
              UserDefaults.standard.string(forKey: item.lastOpenedVersionKey) != version else { return }
        objectWillChange.send()
        UserDefaults.standard.set(version, forKey: item.lastOpenedVersionKey)
    }

    @Published var notice: String?
    @Published var undoDiscardID: String?
    private var noticeTask: Task<Void, Never>?
    func notify(_ text: String) { notice = text }
    @Published private(set) var editorBuffers: [String: DraftEditBuffer] = [:]
    private var editTasks: [String: Task<Void, Never>] = [:]
    private var addressLoads: Set<String> = []
    func loadCorrespondents(_ item: StoredReply, includeBody: Bool = false) async {
        let key = item.id + settings.revision.uuidString + (includeBody ? ".detail" : "")
        guard !Task.isCancelled, (item.correspondents == nil || (includeBody && item.displayBody == nil)), let pipeline, addressLoads.insert(key).inserted else { return }
        // One attempt per visible row/session, not a background mailbox scan.
        try? await pipeline.loadCorrespondents(item.id, includeBody: includeBody)
        if Task.isCancelled {
            addressLoads.remove(key)
            return
        }
        if let updated = try? pipeline.store.record(item.id), let index = records.firstIndex(where: { $0.id == item.id }) {
            records[index] = updated
        }
    }
    func openEditor(_ item: StoredReply) {
        if editorBuffers[item.id] == nil { editorBuffers[item.id] = DraftEditBuffer(body: item.displayedBody) }
    }
    func editorBody(_ item: StoredReply) -> String { editorBuffers[item.id]?.body ?? item.displayedBody }
    func saveState(_ item: StoredReply) -> DraftSaveState { editorBuffers[item.id]?.state ?? .saved }
    func editBody(_ item: StoredReply, body: String) {
        openEditor(item)
        editorBuffers[item.id]?.edit(body)
        guard editTasks[item.id] == nil else { return }
        // Yield once to expose saving feedback; the host owns this write even if
        // the user switches messages or closes the workbench before it resumes.
        editTasks[item.id] = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.editTasks[item.id] = nil
            _ = self.flushEditor(item.id)
        }
    }
    @discardableResult func flushEditor(_ id: String) -> Bool {
        editTasks.removeValue(forKey: id)?.cancel()
        guard var buffer = editorBuffers[id] else { return true }
        let saved = buffer.persist { body in
            guard let pipeline, let item = try pipeline.store.record(id) else { throw PipelineError.storage }
            try pipeline.store.saveEdits(id, subject: item.displayedSubject, body: body)
        }
        editorBuffers[id] = buffer
        if saved { refresh() }
        return saved
    }
    func discard(_ id: String) {
        guard flushEditor(id) else { return }
        do {
            try pipeline?.store.discard(id); undoDiscardID = id; notice = L("Discarded")
            refresh(); noticeTask?.cancel()
            noticeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.undoDiscardID = nil; self?.notice = nil
            }
        } catch { issue = L("Could not discard the draft. Try again.") }
    }
    func undoDiscard() {
        guard let id = undoDiscardID else { return }
        do { try pipeline?.store.restoreDiscard(id); selectedID = id; undoDiscardID = nil; notice = L("Draft restored"); refresh() }
        catch { issue = L("Undo expired. The draft record remains on this Mac.") }
    }
    func regenerate(_ id: String) {
        do {
            guard let pipeline, let item = try pipeline.store.record(id) else { throw PipelineError.storage }
            guard item.canRequestRegeneration(settings: try pipeline.store.settings()) else {
                issue = item.state == .awaitingBody ? L("Waiting for the message body from Mail before drafting.") : L("Check mail authorization, pause status and message expiry.")
                return
            }
            guard flushEditor(id) else { return }
            let approved = settings.harnessKind == .deepseek ? ReplyDraftRequest.linkedPullRequest(in: item.input.body) : nil
            try pipeline.regenerate(id, approvedPullRequest: approved); refresh()
        }
        catch { issue = L("Could not regenerate. Check pause status, authorization, agent connection and message expiry. Each message allows three retries.") }
    }
    @Published var composeBusy = false
    func prepareCompose(_ item: StoredReply) async -> MailComposeRequest? {
        guard !composeBusy, flushEditor(item.id), let pipeline else { return nil }
        composeBusy = true; defer { composeBusy = false }
        do {
            return try await pipeline.prepareMailCompose(id: item.id, subject: item.displayedSubject, body: editorBody(item),
                senderAddress: { try AppleMailComposer.senderAddress(accountID: $0, preferredRecipients: $1) })
        } catch {
            notify(L("Could not prepare a Mail compose window. Check the original message, addresses and automation permission. Your edits were kept."))
            return nil
        }
    }
    func openCompose(_ request: MailComposeRequest) async -> Bool {
        guard !composeBusy, let pipeline else { return false }
        composeBusy = true; defer { composeBusy = false }
        do {
            _ = try await pipeline.openMailCompose(confirmedRequest: request,
                senderAddress: { try AppleMailComposer.senderAddress(accountID: $0, preferredRecipients: $1) },
                open: { try AppleMailComposer.open($0) })
            refresh(); return true
        } catch {
            notify(L("Check Mail before trying again to avoid opening a duplicate compose window. Changes to the original or authorization require confirmation. Your edits were kept."))
            refresh(); return false
        }
    }
    func applyConfiguration() {
        guard onboarding.completed, !onboardingBusy else { return }
        saveConfiguration(updating: true)
    }
    func saveReplyInstructions(_ value: String) throws {
        guard let pipeline else { throw PipelineError.storage }
        try pipeline.store.saveReplyInstructions(value)
        settings = try pipeline.store.settings()
    }
    var selected: StoredReply? { records.first { $0.id == selectedID } }

    init() {
        let args = ProcessInfo.processInfo.arguments
        let diagnosticIndex = args.firstIndex(of: "--pipeline-directory")
        reminders = diagnosticIndex == nil ? ReadyReplyReminders() : nil
        do {
            let root: URL, inboxURL: URL
            if let index = diagnosticIndex, index + 1 < args.count, args[index + 1].hasPrefix("/") {
                // Isolated visual acceptance only; never changes the system appearance.
                if args.contains("--ui-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
                inboxURL = root.appendingPathComponent("inbox")
            } else {
                root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Mailpipe/pipeline")
                if let group = Bundle.main.object(forInfoDictionaryKey: "MailpipeAppGroup") as? String,
                   !group.hasPrefix("."), let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                    inboxURL = shared.appendingPathComponent("inbox"); hasSharedInbox = true
                } else { inboxURL = root.appendingPathComponent("inbox") }
            }
            let store = try PipelineStore(directory: root)
            if diagnosticIndex != nil || hasSharedInbox {
                let panel = inboxURL.deletingLastPathComponent().appendingPathComponent("compose-panel")
                panelExchange = try? ComposePanelExchange(directory: panel)
            }
            pipeline = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: inboxURL), resolve: { item, scope in
                let expected = try store.settings()
                guard let messageID = item.messageID, expected.permission?.id == item.permissionID,
                      (item.mailKitBody == true ? expected.permission?.delivery == .mailKit : expected.authorizedScopes.contains(scope)) else { return nil }
                let match = try await MailReadBridge.shared.resolve(accountID: scope.accountID, mailboxName: scope.mailboxName,
                    messageID: messageID, subject: item.input.subject, mailboxPath: scope.mailboxPath, firstMatch: item.mailKitBody == true) {
                    guard try store.hasCurrentMailReadAuthorization(expected) else { throw PipelineError.revoked }
                }
                guard let match else { return nil }
                let source = Data(match.source.utf8)
                if item.mailKitBody != true && item.sourceEvidence == nil {
                    guard let expected = item.sourceDigest, mailSourceDigest(source) == expected else { return nil }
                }
                return VerifiedMail(accountID: match.accountID, localID: match.localID, source: source)
            }, composeInboxes: {
                try await MailReadBridge.shared.inboxes().map {
                    try AccountScope(accountID: $0.accountID, accountName: $0.accountName,
                                     mailboxName: $0.path.last!, mailboxPath: $0.path)
                }
            })
            onboardingSession = try OnboardingSession(store: store)
            onboarding = try store.onboarding()
            onboardingResult = try onboardingSession?.testResult()
            settings = try store.settings()
            // Reconcile a crash between authoritative policy and extension snapshot updates.
            try pipeline?.inbox.setPermission(settings.paused || settings.permission?.delivery != .mailKit ? nil : settings.permission)
            rediscoverTools()
            refresh(); start()
            display = Task { [weak self] in
                while !Task.isCancelled {
                    self?.serviceComposePanels()
                    self?.refresh()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } catch { issue = L("Could not open the local reply queue (%1$@).", String(describing: Self.code(error))) }
    }
    @discardableResult func saveOnboarding() -> Bool {
        do {
            guard let session = onboardingSession else { throw PipelineError.storage }
            try session.save(onboarding)
            onboarding = try session.store.onboarding()
            onboardingResult = try session.testResult()
            return true
        } catch {
            onboardingIssue = L("Could not save settings: %1$@", String(describing: Self.code(error)))
            return false
        }
    }
    func rediscoverTools() {
        let preferred = onboarding.executable.isEmpty ? settings.executable : onboarding.executable
        let kind = onboarding.executable.isEmpty ? settings.harnessKind : onboarding.harnessKind
        installations = HarnessDiscovery.replyLaunchers(in: HarnessDiscovery.find(), keeping: preferred, kind: kind)
        if onboarding.executable.isEmpty, let first = installations.first {
            selectTool(first)
        }
    }
    func selectTool(_ tool: HarnessInstallation) {
        guard !onboardingBusy else { return }
        var draft = onboarding
        draft.harnessKind = tool.kind
        draft.executable = tool.executable.path
        guard onboarding != draft else { return }
        onboardingIssue = nil
        onboardingResult = nil
        onboarding = draft
    }
    func testOnboarding() {
        guard !onboardingBusy, let session = onboardingSession,
              selectedTool != nil else { return }
        guard saveOnboarding() else { return }
        onboardingBusy = true; onboardingIssue = nil
        onboardingTask = Task {
            defer {
                onboardingBusy = false
                onboarding = (try? session.store.onboarding()) ?? onboarding
                onboardingResult = try? session.testResult()
            }
            do {
                if onboarding.testID != nil { try session.resetTest() }
                _ = try session.beginTest()
                onboarding = try session.store.onboarding()
                try await session.testPipeline.pump()
                if let code = try session.testResult()?.error {
                    let agent = onboarding.harnessKind.displayName
                    switch MailpipeError(rawValue: code) {
                    case .unsupportedVersion:
                        onboardingIssue = L("Mailpipe could not verify the version or required arguments for %1$@. Check the installation in Settings → Agent → Advanced diagnostics.", agent)
                    case .quotaExhausted:
                        onboardingIssue = L("The model service used by %1$@ reported that its quota is exhausted. Check your available quota before testing again.", agent)
                    default:
                        onboardingIssue = L("Sample draft test incomplete (%1$@).", code)
                    }
                }
            } catch { onboardingIssue = L("Test incomplete: %1$@", String(describing: Self.code(error))) }
        }
    }
    func cancelOnboardingTest() {
        onboardingTask?.cancel()
        if let id = onboarding.testID { try? onboardingSession?.testPipeline.cancel(id) }
    }
    func finishOnboarding() {
        guard !onboarding.completed else { return }
        saveConfiguration(updating: false)
    }
    private func saveConfiguration(updating: Bool) {
        guard !onboardingBusy, let session = onboardingSession, let tool = selectedTool, let pipeline else { return }
        guard hasSharedInbox else {
            onboardingIssue = L("Cannot access the Mail extension’s shared folder. Check your installation."); return
        }
        guard onboarding.extensionAcknowledged else { return }
        guard saveOnboarding() else { return }
        onboardingIssue = nil; onboardingBusy = true
        let snapshot = onboarding
        configurationSave = Task {
            defer { onboardingBusy = false; configurationSave = nil }
            do {
                let report = try await tool.inspect()
                try Task.checkCancellation()
                guard report.supportsHeadlessRun, onboarding == snapshot else { throw MailpipeError.unsupportedVersion }
                try Task.checkCancellation()
                worker?.cancel()
                defer { start() }
                try session.activate(updatingConfiguration: updating)
                let active = try session.store.settings()
                try pipeline.inbox.setPermission(active.paused ? nil : active.permission)
                onboarding = try session.store.onboarding()
                refresh()
                onboardingIssue = active.paused ? L("Settings saved. Processing remains paused.") : L("Drafting authorized. Waiting for the first matching message.")
            } catch is CancellationError {
                return
            } catch { onboardingIssue = L("Authorization incomplete. Previous settings retained or pending sync: %1$@", String(describing: Self.code(error))) }
        }
    }

    var onboardingTestPassed: Bool {
        selectedTool != nil && OnboardingSession.testPassed(onboardingResult, for: onboarding)
    }
    var connectionLabel: String {
        let tool = onboarding.harnessKind.displayName
        if let model = onboardingResult?.runs.last?.destination.model { return L("Connected to %1$@ · %2$@", String(describing: tool), String(describing: model)) }
        return L("Connected to %1$@", String(describing: tool))
    }
    func openExtensionSettings() {
        guard let url = URL(string: "mail-pref-pane://extensionspref") else { return }
        if !NSWorkspace.shared.open(url) {
            onboardingIssue = L("Open Mail and go to Mail → Settings → Extensions.")
        }
    }
    func openMailAndExtensionSettings() {
        if let mail = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first {
            mail.activate(options: [])
            openExtensionSettings()
            return
        }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Mail.app"),
            configuration: NSWorkspace.OpenConfiguration()
        ) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil else {
                    self.onboardingIssue = L("Could not open Apple Mail. Open it manually and go to Mail → Settings → Extensions.")
                    return
                }
                app?.activate(options: [])
                try? await Task.sleep(for: .seconds(1))
                self.openExtensionSettings()
            }
        }
    }
    func selectLatestReadyReply() {
        guard refresh() else { return }
        let now = Date()
        selectedID = records.last { $0.isReadyForReplyReminder(settings: settings, now: now) }?.id
    }

    @discardableResult func refresh() -> Bool {
        guard let pipeline else { return false }
        do {
            extensionObservation = try? ExtensionObservation.read(from: pipeline.inbox)
            records = try pipeline.store.records(); settings = try pipeline.store.settings()
            for item in records where item.draft != nil && item.editedBody == nil {
                if let buffer = editorBuffers[item.id], buffer.body != item.displayedBody && buffer.state == .saved {
                    editorBuffers[item.id] = DraftEditBuffer(body: item.displayedBody)
                }
            }
            if let problem = try pipeline.store.issue() { issue = L("Capture notice: %1$@", String(describing: problem)) }
            if onboarding.completed { reminders?.check(records: records, settings: settings) }
            return true
        } catch {
            issue = Self.code(error)
            return false
        }
    }
    func terminationBlocker() -> UpdateRestartBlocker? {
        guard pipeline?.pumping != true, !onboardingBusy, !composeBusy, panelTasks.isEmpty else { return .workInProgress }
        for (id, buffer) in editorBuffers where buffer.state != .saved {
            guard flushEditor(id) else { return .unsavedDraft }
        }
        return nil
    }

    private func serviceComposePanels() {
        guard let exchange = panelExchange, let pipeline else { return }
        for entry in panelTasks.values where !exchange.isActive(entry.request) {
            entry.task.cancel()
        }
        guard let requests = try? exchange.claimRequests() else { return }
        for request in requests {
            let task = Task { [weak self] in
                guard let self else { return }
                defer { panelTasks[request.id] = nil }
                guard onboarding.completed else {
                    try? exchange.respond(.unavailable, to: request)
                    return
                }
                let response = await pipeline.handleComposePanelRequest(request, prepareRecord: { [weak self] id in
                    guard let self else { return false }
                    guard let buffer = editorBuffers[id], buffer.state != .saved else { return true }
                    return flushEditor(id)
                }) {
                    !Task.isCancelled && exchange.isActive(request)
                }
                try? exchange.respond(response, to: request)
            }
            panelTasks[request.id] = (request, task)
        }
    }

    private func start() {
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let pipeline = self?.pipeline else { return }
                do { try await pipeline.pump() }
                catch is CancellationError { return }
                catch { self?.issue = Self.code(error) }
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func change(_ edit: (inout PipelineSettings) -> Void) throws {
        guard let pipeline else { throw PipelineError.storage }
        configurationSave?.cancel()
        worker?.cancel()
        defer { start(); refresh() }
        try pipeline.updateSettings(edit)
    }
    func togglePause() {
        do { try change { $0.paused.toggle() } }
        catch { issue = Self.code(error) }
    }
    func revoke() {
        do { try change { $0.permission = nil; $0.scope = nil; $0.scopes = nil } }
        catch { issue = Self.code(error) }
    }
    func recheck(_ id: String) {
        do { try pipeline?.recheckIdentity(id); refresh() }
        catch { issue = Self.code(error) }
    }
    func cancel(_ id: String) {
        do { try pipeline?.cancel(id); refresh() }
        catch { issue = Self.code(error) }
    }
    static func code(_ error: Error) -> String {
        (error as? MailpipeError)?.rawValue ?? (error as? PipelineError)?.rawValue ?? "operationFailed"
    }
}

struct PendingMenu: View {
    @ObservedObject var model: PendingModel
    let updates: AppUpdates
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.onboarding.completed {
            ForEach(model.pending.suffix(3).reversed()) { item in
                Button {
                    model.selectedID = item.id
                    openWindow.openMailpipe()
                } label: {
                    Text(item.input.subject.isEmpty ? L("(No subject)") : item.input.subject)
                }
            }
            Text(L("Unread drafts: %1$@", String(describing: model.unreadCount)))
            let readyCount = model.readyReplyCount
            Button(L("Ready to reply: %1$@", String(readyCount))) {
                model.selectLatestReadyReply()
                openWindow.openMailpipe()
            }
            .disabled(readyCount == 0)
            Divider()
            Button(L("Open workbench")) { openWindow.openMailpipe() }
        } else {
            Button(L("Continue Mailpipe setup")) { openWindow.openMailpipe() }
        }
        Divider()
        CheckForUpdatesButton(updates: updates)
        Button(L("Quit Mailpipe")) { NSApp.terminate(nil) }
    }
}

struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text(L("Settings…")) }
        } else {
            Button(L("Settings…")) { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
    }
}

// Keep banners and the scrollable message on the same reading column.
private struct WorkbenchColumn: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
    }
}

struct PendingWorkbench: View {
    @ObservedObject var model: PendingModel
    private var visible: [StoredReply] { model.workbenchRecords.reversed() }
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(visible) { item in
                    WorkbenchMessageRow(item: item, unread: model.isUnread(item))
                        .tag(item.id)
                        .task(id: item.id + model.settings.revision.uuidString) { await model.loadCorrespondents(item) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 244, max: 380)
            .overlay {
                if visible.isEmpty { Text(L("No drafts yet")).foregroundStyle(.secondary).padding() }
            }
        } detail: {
            VStack(spacing: 0) {
                if model.needsPermissionRecovery {
                    HStack {
                        Label(L("Confirm the mail scope and agent in Settings. Existing drafts remain on this Mac."), systemImage: "exclamationmark.shield")
                        Spacer(); SettingsButton()
                    }
                    .modifier(WorkbenchColumn())
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))
                }
                if let issue = model.issue {
                    HStack {
                        Label(issue, systemImage: "exclamationmark.triangle")
                        Spacer(); SettingsButton()
                        Button { model.issue = nil } label: { Image(systemName: "xmark") }.accessibilityLabel(L("Dismiss notice"))
                    }
                    .font(.callout)
                    .modifier(WorkbenchColumn())
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))
                }
                if let item = visible.first(where: { $0.id == model.selectedID }) {
                    DraftDetail(model: model, item: item).id(item.id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text(visible.isEmpty ? L("No drafts yet") : L("Select a message")).font(.title2)
                        Text(L("Review your agent’s drafts here, then send them in Apple Mail.")).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let notice = model.notice {
                    HStack {
                        Text(notice)
                        if model.undoDiscardID != nil { Button(L("Undo"), action: model.undoDiscard) }
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel(L("Dismiss feedback"))
                    }
                    .modifier(WorkbenchColumn())
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .accessibilityElement(children: .contain)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle("Mailpipe")
    }
}

private extension StoredReply {
    var lastOpenedVersionKey: String { "workbench.lastOpenedDraft." + id }
}

private struct WorkbenchMessageRow: View {
    let item: StoredReply
    let unread: Bool

    var body: some View {
        let subject = item.input.subject
        let sender = item.displayCorrespondents?.sender ?? (item.state == .awaitingBody
            ? L("Waiting for message body") : L("Sender address unavailable"))
        let date = item.capturedAt
        VStack(alignment: .leading, spacing: 3) {
            Text(subject.isEmpty ? L("(No subject)") : subject).lineLimit(1).truncationMode(.tail)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    if unread {
                        Circle().fill(Color(nsColor: .systemBlue))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sender).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(date, format: Calendar.autoupdatingCurrent.isDateInToday(date)
                     ? .dateTime.hour().minute()
                     : .dateTime.month(.twoDigits).day(.twoDigits))
                    .font(.caption2).monospacedDigit().fixedSize()
            }
            .padding(.leading, 14)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityValue(unread ? L("Unread") : "")
    }
}

struct WorkbenchActionStyle: ViewModifier {
    var circular = false

    @ViewBuilder func body(content: Content) -> some View {
        let button = content.controlSize(.large)
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass).buttonBorderShape(circular ? .circle : .capsule)
        } else if #available(macOS 14.0, *) {
            button.buttonStyle(.bordered).buttonBorderShape(circular ? .circle : .capsule)
        } else {
            button.buttonStyle(.bordered).clipShape(Capsule())
        }
    }
}

private struct DraftDetail: View {
    @ObservedObject var model: PendingModel
    let item: StoredReply
    @State private var originalExpanded = false
    @State private var fullBodyHeight: CGFloat = 0
    @State private var previewHeight: CGFloat = 0
    @State private var showExplanation = false
    @State private var confirmRegeneration = false
    private var bodyText: String { model.editorBody(item) }
    private var incoming: String { item.displayBody ?? item.input.body }
    private var contentExpired: Bool { item.capturedAt < Date().addingTimeInterval(-7 * 86_400) || item.error == "contentExpired" }
    private var isExpired: Bool { contentExpired || ["policyChanged", "identityUnresolved", "identitySourceMismatch"].contains(item.error ?? "") }
    private var recipientAddresses: String {
        guard let recipients = item.displayCorrespondents?.recipients, !recipients.isEmpty else { return L("Recipient address unavailable") }
        return recipients.joined(separator: "、")
    }
    private var canRegenerate: Bool {
        item.canRequestRegeneration(settings: model.settings)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(item.input.subject.isEmpty ? L("(No subject)") : item.input.subject)
                            .font(.title.weight(.semibold)).textSelection(.enabled).lineLimit(3)
                        Spacer(minLength: 0)
                        Button(action: openOriginalMessage) {
                            actionIcon(L("Open original"), "envelope.open")
                        }
                            .help(L("Open original in Apple Mail"))
                            .modifier(WorkbenchActionStyle(circular: true))
                            .fixedSize()
                            .disabled(originalMessageURL == nil)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                        addressRow(L("From:"), item.displayCorrespondents?.sender ?? L("Sender address unavailable"))
                        addressRow(L("To:"), recipientAddresses)
                        if let cc = item.displayCorrespondents?.cc, !cc.isEmpty {
                            addressRow(L("Cc:"), cc.joined(separator: "、"))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(item.capturedAt.formatted(.dateTime.month().day().hour().minute()))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                originalCard
                draftCard
            }
            .modifier(WorkbenchColumn())
            .padding(.top, 7)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
                .modifier(WorkbenchColumn())
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
        }
        .onAppear { model.openEditor(item) }
        .task(id: item.draftVersion) {
            model.markOpened(item)
        }
        .task(id: item.id + model.settings.revision.uuidString) { await model.loadCorrespondents(item, includeBody: true) }
        .alert(L("Regenerate reply?"), isPresented: $confirmRegeneration) {
            Button(L("Cancel"), role: .cancel) { }
            Button(L("Regenerate")) { model.regenerate(item.id) }
        } message: {
            if model.settings.harnessKind == .deepseek, let link = ReplyDraftRequest.linkedPullRequest(in: item.input.body) {
                Text(L("Continuing lets Mailpipe use your GitHub account to read changes at %1$@ and share them with DeepSeek Harness for review and drafting. The new draft replaces your reply.", String(describing: link)))
            } else if ReplyDraftRequest.linkedPullRequest(in: item.input.body) != nil {
                Text(L("%1$@ cannot verify PR changes. The new draft will replace your reply.", String(describing: model.settings.harnessKind.displayName)))
            } else {
                Text(L("The agent will use your model quota again and replace the current reply."))
            }
        }
    }
    private func addressRow(_ label: String, _ addresses: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).fixedSize()
            Text(addresses)
        }
    }
    private var originalMessageURL: URL? {
        guard !item.syntheticAuthorized, item.manualExecutable == nil,
              let id = item.messageID, !id.isEmpty,
              id.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let encoded = "<\(id)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string: "message://" + encoded)
    }
    private func openOriginalMessage() {
        guard let url = originalMessageURL,
              let mail = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else {
            model.notify(L("Could not open Apple Mail."))
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: mail, configuration: .init()) { _, error in
            if error != nil { Task { @MainActor in model.notify(L("Apple Mail could not open the original message.")) } }
        }
    }
    private var unreadableMIME: Bool {
        incoming.isEmpty && item.error == MailBodyRejection.malformedMIME.rawValue
    }
    private var originalMessageText: String {
        if !incoming.isEmpty { return incoming }
        if unreadableMIME { return L("Message received. Mailpipe could not read its MIME structure.") }
        if item.state == .awaitingBody { return L("Waiting for Apple Mail to provide the message body before drafting.") }
        return L("No readable message body available.")
    }
    private var originalText: some View {
        Text(verbatim: originalMessageText)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var originalCard: some View {
        let truncated = fullBodyHeight > previewHeight + 0.5
        let expanded = truncated && originalExpanded
        return VStack(alignment: .leading, spacing: 6) {
            if !truncated || expanded { originalText.textSelection(.enabled) }
            if truncated {
                Button {
                    originalExpanded.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !expanded { originalText.lineLimit(3) }
                        HStack {
                            Text(L("Message body"))
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? L("Collapse message") : L("Expand message"))
            }
            if item.displayBody == nil, !incoming.isEmpty, item.manualExecutable == nil {
                Text(L("The full source is unavailable. Showing the saved body."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                originalText.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { fullBodyHeight = $0 }
                originalText.lineLimit(3).onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { previewHeight = $0 }
            }
            .hidden().accessibilityHidden(true).allowsHitTesting(false)
        }
    }
    private var draftCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if !unreadableMIME, let error = item.error, let description = errorDescription(error) {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                if item.isPreparing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(L("Generating…")).font(.callout)
                        Spacer()
                        Button(L("Cancel"), action: { model.cancel(item.id) })
                    }
                }
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.secondary)
                    .help(L("Reply drafts"))
                    .accessibilityLabel(L("Reply drafts"))
                replyEditor
                if model.saveState(item) == .failed {
                    Button(L("Save failed. Click to retry.")) { model.flushEditor(item.id) }
                        .font(.caption).buttonStyle(.link)
                }
            }
        }
    }
    private var replyEditor: some View {
        ZStack(alignment: .topLeading) {
            ReplyTextView(
                text: Binding(get: { bodyText }, set: { model.editBody(item, body: $0) }),
                enabled: !item.isPreparing)
            if bodyText.isEmpty {
                Text(item.isPreparing ? L("Preparing a reply. Your edits will be kept.") : L("Write your reply here…"))
                    .font(.system(size: ReplyTextView.bodyFont.pointSize)).foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func actionIcon(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .frame(minWidth: 20, minHeight: 20)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    if let request = await model.prepareCompose(item) { _ = await model.openCompose(request) }
                }
            } label: { actionIcon(L("Compose reply in Apple Mail"), "arrowshape.turn.up.left") }
            .help(L("Compose reply in Apple Mail"))
            .disabled(item.manualExecutable != nil || model.composeBusy || item.isPreparing || isExpired || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(action: copyReply) { actionIcon(L("Copy reply"), "doc.on.doc") }
                .help(L("Copy reply"))
                .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button { confirmRegeneration = true } label: { actionIcon(L("Regenerate"), "arrow.clockwise") }
                .help(L("Regenerate"))
                .disabled(!canRegenerate)
            Button(role: .destructive) {
                model.discard(item.id)
            } label: { actionIcon(L("Delete from workbench"), "trash") }
                .help(L("Delete from workbench"))
                .disabled(item.isPreparing)
            Spacer(minLength: 0)
            Button { showExplanation = true } label: { actionIcon(L("View data usage"), "info") }
                .help(L("View data usage")).accessibilityLabel(L("View data usage"))
                .popover(isPresented: $showExplanation) { explanation }
        }
        .modifier(WorkbenchActionStyle(circular: true))
    }
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Where this message’s data went")).font(.headline)
            if let run = item.runs.last {
                Text(L("Agent used: %1$@.", String(describing: run.destination.harness.displayName)))
                if let vendor = run.destination.vendor { Text(L("Model service: %1$@", String(describing: vendor))) }
                if let model = run.destination.model { Text(L("Model: %1$@", String(describing: model))) }
                else { Text(L("The specific model was not confirmed for this run.")) }
            } else { Text(L("No agent runs recorded for this message.")) }
            Text(L("Mailpipe saves messages and drafts on this Mac. Use the reply arrow to review and send in Apple Mail."))
            if item.regenerationLimitReached { Text(L("Regeneration limit reached. You can still edit the reply.")) }
            if let readDiff = item.runs.last?.readPullRequestDiff {
                Text(readDiff ? L("The review tool read the PR diff.") : L("The review tool could not read the PR diff."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding().frame(width: 340)
    }
    private func copyReply() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(bodyText, forType: .string) {
            model.notify(L("Reply copied. Paste it in Mail to send."))
        } else { model.notify(L("Could not copy. Try again.")) }
    }
    private func errorDescription(_ code: String) -> String? {
        if let rejection = MailBodyRejection(rawValue: code) { return rejection.reviewLabel }
        switch code {
        case "contentExpired": return L("This message has expired.")
        case "policyChanged", "revoked": return L("Authorization changed. Check Settings.")
        case "identitySourceMismatch": return L("Message found, but the captured content differs from the original in Mail. Open it to check.")
        case "identityUnresolved", "identityUnavailable", "identityAmbiguous": return nil
        case "invalidOutput": return L("The agent response failed validation. No further details were recorded.")
        case "outputJSON": return L("The agent did not return a valid JSON object.")
        case "outputFields": return L("The response contains invalid fields, types or values.")
        case "outputReference": return L("The response version or identifiers do not match the request.")
        case "outputSummary": return L("The summary count or length is invalid.")
        case "outputEvidence": return L("Quoted evidence does not match the message or exceeds the limit.")
        case "cancelled": return L("Task canceled. Your edits were kept.")
        default: return L("Could not generate a reply. Your edits were kept. Check the agent connection.")
        }
    }
}

private final class DraftTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let container = textContainer, let layoutManager else { return }
        let width = bounds.width - 2 * textContainerInset.width
        guard width > 0, container.containerSize.width != width else { return }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: .iBeam)
    }
}

private struct ReplyTextView: NSViewRepresentable {
    static var bodyFont: NSFont {
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize + 1)
    }

    @Binding var text: String
    var enabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = DraftTextView()
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isEditable = enabled
        view.isSelectable = true
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.enabledTextCheckingTypes = 0
        view.focusRingType = .default
        view.alignment = .left
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainer?.widthTracksTextView = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.textStorage?.addLayoutManager(context.coordinator.measuringLayout)
        view.string = text
        applyTypingStyle(view)
        view.setAccessibilityLabel(L("Editable reply draft"))
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.text = $text
        view.isEditable = enabled
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            applyTypingStyle(view)
            let limit = (text as NSString).length
            if selection.location <= limit {
                view.setSelectedRange(NSRange(location: selection.location, length: min(selection.length, limit - selection.location)))
            }
        }
    }

    private func applyTypingStyle(_ view: NSTextView) {
        let font = Self.bodyFont
        view.font = font
        view.textColor = .labelColor
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = context.coordinator.measuringLayout.textContainers.first else { return nil }
        let layout = context.coordinator.measuringLayout
        let insets = view.textContainerInset
        container.containerSize = NSSize(width: max(1, width - 2 * insets.width), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let textHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let minimumHeight = 3 * layout.defaultLineHeight(for: Self.bodyFont)
        return CGSize(width: width, height: ceil(max(minimumHeight, textHeight) + 2 * insets.height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        // SwiftUI probes several widths. Measure the same text without reflowing the editor onscreen.
        let measuringLayout = NSLayoutManager()

        init(text: Binding<String>) {
            self.text = text
            super.init()
            let container = NSTextContainer(size: .zero)
            container.lineFragmentPadding = 0
            measuringLayout.addTextContainer(container)
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if text.wrappedValue != view.string { text.wrappedValue = view.string }
        }
    }
}

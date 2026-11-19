import SwiftUI
import AppKit
import MailpipeCore
import MailpipeRuntime
import HarnessAdapters
import MailBridge

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
    private(set) var hasSharedInbox = false
    var needsPermissionRecovery: Bool { onboarding.completed && settings.permission?.delivery != .mailKit }
    var pending: [StoredReply] { records.filter { $0.discardedAt == nil && $0.canDisplayInWorkbench && ($0.state.isPending || $0.isPreparing || $0.state == .needsReview || $0.state == .awaitingBody) } }
    var workbenchRecords: [StoredReply] { records.filter { $0.discardedAt == nil && $0.canDisplayInWorkbench } }
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
            try pipeline?.store.discard(id); undoDiscardID = id; notice = "已丢弃"
            refresh(); noticeTask?.cancel()
            noticeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.undoDiscardID = nil; self?.notice = nil
            }
        } catch { issue = "无法丢弃草稿，请重试。" }
    }
    func undoDiscard() {
        guard let id = undoDiscardID else { return }
        do { try pipeline?.store.restoreDiscard(id); selectedID = id; undoDiscardID = nil; notice = "已恢复草稿"; refresh() }
        catch { issue = "撤销时间已过，草稿记录仍保留在本机。" }
    }
    func regenerate(_ id: String) {
        do {
            guard let pipeline, let item = try pipeline.store.record(id) else { throw PipelineError.storage }
            guard item.canRequestRegeneration(settings: try pipeline.store.settings()) else {
                issue = item.state == .awaitingBody ? "尚未收到 Mail 提供的正文，暂时无法生成回复。" : "请先核对来信处理授权、暂停状态和邮件有效期。"
                return
            }
            guard flushEditor(id) else { return }
            try pipeline.regenerate(id, approvedPullRequest: ReplyDraftRequest.linkedPullRequest(in: item.input.body)); refresh()
        }
        catch { issue = "无法重新生成。请检查暂停状态、来信授权、Agent 连接和邮件有效期。每封最多重新生成三次。" }
    }
    @Published var composeBusy = false
    func prepareCompose(_ item: StoredReply) async -> MailComposeRequest? {
        guard !composeBusy, flushEditor(item.id), let pipeline else { return nil }
        composeBusy = true; defer { composeBusy = false }
        do {
            return try await pipeline.prepareMailCompose(id: item.id, subject: item.displayedSubject, body: editorBody(item),
                senderAddress: { try AppleMailComposer.senderAddress(accountID: $0, preferredRecipients: $1) })
        } catch {
            notify("无法准备 Mail 撰写窗口。请核对原邮件位置、地址和 Mail 自动化权限；当前编辑已保留。")
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
            notify("未能确认撰写窗口。请先查看 Mail，避免重复创建；原邮件或授权变化时需重新确认。当前编辑已保留。")
            refresh(); return false
        }
    }
    func applyConfiguration() {
        guard onboarding.completed, !onboardingBusy else { return }
        saveConfiguration(updating: true)
    }
    var selected: StoredReply? { records.first { $0.id == selectedID } }

    init() {
        do {
            let args = ProcessInfo.processInfo.arguments
            let diagnosticIndex = args.firstIndex(of: "--pipeline-directory")
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
                    self?.refresh()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } catch { issue = "无法打开本机的回复队列（\(Self.code(error))）。" }
    }
    @discardableResult func saveOnboarding() -> Bool {
        do {
            guard let session = onboardingSession else { throw PipelineError.storage }
            try session.save(onboarding)
            onboarding = try session.store.onboarding()
            onboardingResult = try session.testResult()
            return true
        } catch {
            onboardingIssue = "无法保存当前设置：\(Self.code(error))"
            return false
        }
    }
    func rediscoverTools() {
        let preferred = onboarding.executable.isEmpty ? settings.executable : onboarding.executable
        installations = HarnessDiscovery.deepSeekLaunchers(in: HarnessDiscovery.find(), keeping: preferred)
    }
    func testOnboarding() {
        guard !onboardingBusy, let session = onboardingSession,
              installations.contains(where: { $0.executable.path == onboarding.executable }) else { return }
        guard saveOnboarding() else { return }
        onboardingBusy = true; onboardingIssue = nil
        onboardingTask = Task {
            defer {
                onboardingBusy = false
                onboarding = (try? session.store.onboarding()) ?? onboarding
                onboardingResult = try? session.testResult()
            }
            do {
                _ = try session.beginTest()
                onboarding = try session.store.onboarding()
                try await session.testPipeline.pump()
            } catch { onboardingIssue = "测试未完成：\(Self.code(error))" }
        }
    }
    func cancelOnboardingTest() {
        onboardingTask?.cancel()
        if let id = onboarding.testID { try? onboardingSession?.testPipeline.cancel(id) }
    }
    func resetOnboardingTest() {
        guard let session = onboardingSession else { return }
        do { try session.resetTest(); onboarding = try session.store.onboarding(); onboardingResult = nil }
        catch { onboardingIssue = Self.code(error) }
    }
    func finishOnboarding() {
        guard !onboarding.completed else { return }
        saveConfiguration(updating: false)
    }
    private func saveConfiguration(updating: Bool) {
        guard !onboardingBusy, let session = onboardingSession, let pipeline else { return }
        guard hasSharedInbox else {
            onboardingIssue = "无法访问 Mail 扩展的共享目录。请检查 Mailpipe 的安装。"; return
        }
        guard onboarding.extensionAcknowledged else { return }
        guard saveOnboarding() else { return }
        onboardingIssue = nil; onboardingBusy = true
        let snapshot = onboarding
        configurationSave = Task {
            defer { onboardingBusy = false; configurationSave = nil }
            do {
                let report = try await DeepSeekHarnessAdapter(executable: URL(fileURLWithPath: snapshot.executable), dialect: DeepSeekHarnessDialect()).inspect()
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
                onboardingIssue = active.paused ? "配置已保存，来信处理仍处于暂停状态。" : "已授权 Agent 为新来信起草回复，等待首封符合条件的来信。"
            } catch is CancellationError {
                return
            } catch { onboardingIssue = "授权未完成，原设置保留或等待同步：\(Self.code(error))" }
        }
    }

    var onboardingTestPassed: Bool { OnboardingSession.testPassed(onboardingResult, level: onboarding.level) }
    func openExtensionSettings() {
        guard let url = URL(string: "mail-pref-pane://extensionspref") else { return }
        if !NSWorkspace.shared.open(url) {
            onboardingIssue = "无法打开设置页。请打开 Mail，进入邮件 → 设置 → 扩展。"
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
                    self.onboardingIssue = "无法打开 Apple Mail。请手动打开，再进入邮件 → 设置 → 扩展。"
                    return
                }
                app?.activate(options: [])
                try? await Task.sleep(for: .seconds(1))
                self.openExtensionSettings()
            }
        }
    }
    func refresh() {
        guard let pipeline else { return }
        do {
            extensionObservation = try? ExtensionObservation.read(from: pipeline.inbox)
            records = try pipeline.store.records(); settings = try pipeline.store.settings()
            for item in records where item.draft != nil && item.editedBody == nil {
                if let buffer = editorBuffers[item.id], buffer.body != item.displayedBody && buffer.state == .saved {
                    editorBuffers[item.id] = DraftEditBuffer(body: item.displayedBody)
                }
            }
            if let problem = try pipeline.store.issue() { issue = "采集提示：\(problem)" }
        } catch { issue = Self.code(error) }
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.onboarding.completed {
            ForEach(model.pending.suffix(3).reversed()) { item in
                Button {
                    model.selectedID = item.id
                    openWindow.openMailpipe()
                } label: {
                    Text(item.input.subject.isEmpty ? "（无主题）" : item.input.subject)
                }
            }
            Text("未读草稿 \(model.unreadCount)")
            Divider()
            Button("打开工作台") { openWindow.openMailpipe() }
        } else {
            Button("继续设置 Mailpipe") { openWindow.openMailpipe() }
        }
        Divider()
        Button("退出 Mailpipe") { NSApp.terminate(nil) }
    }
}

struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text("设置…") }
        } else {
            Button("设置…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
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
                if visible.isEmpty { Text("暂时没有草稿").foregroundStyle(.secondary).padding() }
            }
        } detail: {
            VStack(spacing: 0) {
                if model.needsPermissionRecovery {
                    HStack {
                        Label("请在设置中确认来信范围和 Agent。已有草稿仍保存在本机。", systemImage: "exclamationmark.shield")
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
                        Button { model.issue = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭提示")
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
                        Text(visible.isEmpty ? "暂时没有草稿" : "选择一封来信").font(.title2)
                        Text("在这里审阅 Agent 起草的回复，再到 Apple Mail 发送。").foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let notice = model.notice {
                    HStack {
                        Text(notice)
                        if model.undoDiscardID != nil { Button("撤销", action: model.undoDiscard) }
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭反馈")
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
        let sender = item.correspondents?.sender ?? "发件地址未采集"
        let date = item.capturedAt
        VStack(alignment: .leading, spacing: 3) {
            Text(subject.isEmpty ? "（无主题）" : subject).lineLimit(1).truncationMode(.tail)
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
        .accessibilityValue(unread ? "未读" : "")
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
        guard let recipients = item.correspondents?.recipients, !recipients.isEmpty else { return "收件地址未采集" }
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
                        Text(item.input.subject.isEmpty ? "（无主题）" : item.input.subject)
                            .font(.title.weight(.semibold)).textSelection(.enabled).lineLimit(3)
                        Spacer(minLength: 0)
                        Button(action: openOriginalMessage) {
                            actionIcon("打开原邮件", "envelope.open")
                        }
                            .help("在 Apple Mail 中打开原邮件")
                            .modifier(WorkbenchActionStyle(circular: true))
                            .fixedSize()
                            .disabled(originalMessageURL == nil)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                        addressRow("发件人：", item.correspondents?.sender ?? "发件地址未采集")
                        addressRow("收件人（To）：", recipientAddresses)
                        if let cc = item.correspondents?.cc, !cc.isEmpty {
                            addressRow("抄送（Cc）：", cc.joined(separator: "、"))
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
        .onAppear { model.openEditor(item) }
        .task(id: item.draftVersion) {
            model.markOpened(item)
        }
        .task(id: item.id + model.settings.revision.uuidString) { await model.loadCorrespondents(item, includeBody: true) }
        .alert("重新生成回复？", isPresented: $confirmRegeneration) {
            Button("取消", role: .cancel) { }
            Button("重新生成") { model.regenerate(item.id) }
        } message: {
            if let link = ReplyDraftRequest.linkedPullRequest(in: item.input.body) {
                Text("继续即允许 Mailpipe 使用你的 GitHub 账户读取 \(link) 的变更，交给 DeepSeek Harness 核对并起草。新草稿会替换当前回复。")
            } else {
                Text("Agent 会再次调用模型，消耗你的额度。新草稿生成后会替换当前回复。")
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
            model.notify("无法打开 Apple Mail。")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: mail, configuration: .init()) { _, error in
            if error != nil { Task { @MainActor in model.notify("Apple Mail 未能打开原邮件。") } }
        }
    }
    private var originalText: some View {
        Text(verbatim: incoming.isEmpty ? (item.state == .awaitingBody ? "正在等待 Apple Mail 提供正文。收到后才能交给 Agent 起草回复。" : "尚未取得可阅读的正文，请核对 Mail 权限和邮件格式。") : incoming)
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
                            Text("来信正文")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "收起来信正文" : "展开来信正文")
            }
            if item.displayBody == nil, !incoming.isEmpty, item.manualExecutable == nil {
                Text("完整原文尚未取得，以下为已保存的正文。")
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
                if let error = item.error, let description = errorDescription(error) {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                if item.isPreparing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在生成…").font(.callout)
                        Spacer()
                        Button("取消", action: { model.cancel(item.id) })
                    }
                }
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.secondary)
                    .help("回复草稿")
                    .accessibilityLabel("回复草稿")
                replyEditor
                if model.saveState(item) == .failed {
                    Button("未能保存，点此重试") { model.flushEditor(item.id) }
                        .font(.caption).buttonStyle(.link)
                }
            }
            actions
        }
    }
    private var replyEditor: some View {
        ZStack(alignment: .topLeading) {
            ReplyTextView(
                text: Binding(get: { bodyText }, set: { model.editBody(item, body: $0) }),
                enabled: !item.isPreparing)
            if bodyText.isEmpty {
                Text(item.isPreparing ? "正在准备回复，现有编辑会保留。" : "点击此处输入回复正文…")
                    .font(.system(size: ReplyTextView.bodyFont.pointSize)).foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func actionIcon(_ title: LocalizedStringKey, _ symbol: String) -> some View {
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
            } label: { actionIcon("在 Apple Mail 中撰写回复", "arrowshape.turn.up.left") }
            .help("在 Apple Mail 中撰写回复")
            .disabled(item.manualExecutable != nil || model.composeBusy || item.isPreparing || isExpired || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(action: copyReply) { actionIcon("复制回复", "doc.on.doc") }
                .help("复制回复")
                .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button { confirmRegeneration = true } label: { actionIcon("重新生成", "arrow.clockwise") }
                .help("重新生成")
                .disabled(!canRegenerate)
            Menu {
                Button("查看数据去向") { showExplanation = true }
                Divider()
                Button("丢弃草稿", role: .destructive) { model.discard(item.id) }.disabled(item.isPreparing)
            } label: { actionIcon("更多草稿操作", "ellipsis") }
                .help("更多草稿操作").menuIndicator(.hidden).menuStyle(.button).fixedSize().accessibilityLabel("更多草稿操作")
            Spacer(minLength: 0)
            Button { showExplanation = true } label: { actionIcon("查看数据去向", "info") }
                .help("查看数据去向").accessibilityLabel("查看数据去向")
                .popover(isPresented: $showExplanation) { explanation }
        }
        .modifier(WorkbenchActionStyle(circular: true))
    }
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("这封来信的数据去向").font(.headline)
            if let run = item.runs.last {
                Text("本次选择的 Agent 是 \(run.destination.harness.displayName)。")
                if let model = run.destination.model, let vendor = run.destination.vendor {
                    Text("模型服务：\(vendor) · \(model)")
                } else { Text("本次记录未确认具体模型。") }
            } else { Text("这封来信尚无 Agent 调用记录。") }
            Text("来信和草稿由 Mailpipe 保存在这台 Mac 上。点回复箭头可在 Apple Mail 打开撰写窗口，由你检查并发送。")
            if (item.regenerationCount ?? 0) >= 3 { Text("已达到本封重新生成次数上限，当前回复仍可编辑。") }
            if let readDiff = item.runs.last?.readPullRequestDiff {
                Text(readDiff ? "核查工具已读取 PR 代码差异。" : "核查工具未取得可读的 PR 代码差异。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding().frame(width: 340)
    }
    private func copyReply() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(bodyText, forType: .string) {
            model.notify("已复制回复正文。请到 Mail 中粘贴发送。")
        } else { model.notify("复制未成功，请重试。") }
    }
    private func errorDescription(_ code: String) -> String? {
        if let rejection = MailBodyRejection(rawValue: code) { return rejection.reviewLabel }
        switch code {
        case "contentExpired": return "来信已超过处理有效期。"
        case "policyChanged", "revoked": return "处理授权已变更，请在设置中核对。"
        case "identitySourceMismatch": return "已找到原邮件，但采集内容与 Mail 原文不一致。请打开原邮件核对。"
        case "identityUnresolved", "identityUnavailable", "identityAmbiguous": return nil
        case "invalidOutput": return "Agent 返回的内容未通过校验。这条记录没有具体原因。"
        case "outputJSON": return "Agent 返回的内容无法解析为 JSON 对象。"
        case "outputFields": return "Agent 返回的字段、类型或枚举值不符合要求。"
        case "outputReference": return "Agent 返回的版本、邮件标识或请求标识与本次请求不符。"
        case "outputSummary": return "Agent 返回的摘要条数或长度不符合要求。"
        case "outputEvidence": return "Agent 返回的引文无法与原文对应，或超出了引文限制。"
        case "cancelled": return "任务已取消，当前编辑保留。"
        default: return "回复未能生成。你的编辑已保留，请检查 Agent 连接。"
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
        view.setAccessibilityLabel("回复草稿，可编辑")
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

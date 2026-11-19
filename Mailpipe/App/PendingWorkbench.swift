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
    var offeredOnboarding = false
    private var onboardingSession: OnboardingSession?
    private var onboardingTask: Task<Void, Never>?
    private var configurationSave: Task<Void, Never>?
    private var pipeline: ReplyPipeline?
    private var worker: Task<Void, Never>?
    private var display: Task<Void, Never>?
    private(set) var hasSharedInbox = false
    var needsPermissionRecovery: Bool { onboarding.completed && settings.suggestionsOnly != true && settings.permission?.delivery != .mailKit }
    var pending: [StoredReply] { records.filter { $0.discardedAt == nil && $0.canDisplayInWorkbench && ($0.state.isPending || $0.isPreparing || $0.state == .needsReview || $0.state == .awaitingBody) } }
    @Published var notice: String?
    @Published var undoDiscardID: String?
    private var noticeTask: Task<Void, Never>?
    var toolName: String { installations.first { $0.executable.path == settings.executable }?.kind.displayName ?? "AI 工具" }
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
    @discardableResult func resolveCandidate(_ item: StoredReply, adopt: Bool) -> Bool {
        guard flushEditor(item.id), let version = item.draftVersion else { return false }
        do {
            guard let pipeline else { throw PipelineError.storage }
            try pipeline.store.resolveDraftCandidate(item.id, expected: version, adopt: adopt)
            if adopt, let updated = try pipeline.store.record(item.id) {
                editorBuffers[item.id] = DraftEditBuffer(body: updated.displayedBody)
            }
            refresh(); return true
        } catch { notify("未能保存选择，当前编辑和候选稿仍保留。"); return false }
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
            // Freeze the current reply even when it has not been edited, so the
            // next generated version can only appear as a candidate.
            try pipeline.store.saveEdits(id, subject: item.displayedSubject, body: editorBody(item))
            try pipeline.regenerate(id); refresh()
        }
        catch { issue = "无法重新生成。请核对暂停、来信处理授权、工具和邮件有效期；每封最多重新生成三次。" }
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
            notify("撰写窗口已交给 Mail，尚未发送。请在 Mail 中核对收件人和内容，再决定是否发送。")
            refresh(); return true
        } catch {
            notify("未能确认撰写窗口。请先查看 Mail，避免重复创建；原邮件或授权变化时需重新确认。当前编辑已保留。")
            refresh(); return false
        }
    }
    func applyConfiguration() {
        guard !onboardingBusy else { return }
        onboarding.completed = false; saveOnboarding(); finishOnboarding()
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
            installations = HarnessDiscovery.find().filter { $0.kind == .deepseek }
            refresh(); start()
            display = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } catch { issue = "无法打开持久化队列：\(Self.code(error))" }
    }
    func saveOnboarding() {
        do {
            try onboardingSession?.save(onboarding)
            if let session = onboardingSession {
                onboarding = try session.store.onboarding()
                onboardingResult = try session.testResult()
            }
        } catch { onboardingIssue = Self.code(error) }
    }
    func editOnboarding() {
        onboardingIssue = nil
        if onboarding.completed {
            onboarding.id = UUID(); onboarding.completed = false; onboarding.step = 1
            saveOnboarding()
        }
    }
    func testOnboarding() {
        guard !onboardingBusy, let session = onboardingSession,
              installations.contains(where: { $0.executable.path == onboarding.executable }) else { return }
        onboardingBusy = true; onboardingIssue = nil
        saveOnboarding()
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
        guard !onboardingBusy, (onboarding.isSuggestionsOnly || hasSharedInbox), let session = onboardingSession, let pipeline else {
            onboardingIssue = "共享容器不可用；可保存草案，不能授权采集。"; return
        }
        guard !onboarding.completed else { return }
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
                try session.activate()
                let active = try session.store.settings()
                try pipeline.inbox.setPermission(active.paused ? nil : active.permission)
                onboarding = try session.store.onboarding(); refresh()
                onboardingIssue = active.suggestionsOnly == true ? "逐封建议已就绪；每封提交前需确认内容和工具。" : active.paused ? "配置已保存；仍保持暂停。" : "已授权，等待新邮件验证。"
            } catch is CancellationError {
                return
            } catch { onboardingIssue = "授权未完成，原设置保留或等待同步：\(Self.code(error))" }
        }
    }

    var onboardingTestPassed: Bool { OnboardingSession.testPassed(onboardingResult, level: onboarding.level) }
    func useSuggestions() {
        onboarding.suggestionsOnly = true
        saveOnboarding()
    }
    func confirmManual(id: UUID, subject: String, body: String, executable: String) -> Bool {
        do {
            guard let pipeline else { return false }
            selectedID = try pipeline.enqueueManual(id: id, subject: subject, body: body, executable: executable)
            refresh(); return true
        } catch { issue = "逐封确认未完成：\(Self.code(error))"; return false }
    }
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
                if let buffer = editorBuffers[item.id], buffer.body.isEmpty && buffer.state == .saved {
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
        do { try change { $0.permission = nil; $0.scope = nil; $0.scopes = nil; $0.suggestionsOnly = false } }
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

enum WorkbenchFilter: String, CaseIterable, Identifiable {
    case pending = "待处理", all = "全部", review = "需确认", failed = "失败"
    var id: Self { self }
    func includes(_ item: StoredReply) -> Bool {
        guard item.discardedAt == nil, item.canDisplayInWorkbench else { return false }
        switch self {
        case .pending: return item.state.isPending || item.isPreparing || item.state == .awaitingBody || item.state == .needsReview
        case .all: return true
        case .review: return [.needsReview, .awaitingAccount, .awaitingBody, .needsReply].contains(item.state) && item.error == nil || item.canRecheckIdentity
        case .failed: return item.error != nil && item.state != .cancelled
        }
    }
}

struct PendingMenu: View {
    @ObservedObject var model: PendingModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private func showWindow(_ id: String) {
        dismiss()
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Mailpipe", systemImage: "envelope").font(.headline)
                Spacer()
                Text(!model.onboarding.completed ? "未配置" : model.needsPermissionRecovery ? "需要授权" : model.settings.paused ? "已暂停" : "运行中").foregroundStyle(.secondary)
            }
            Text("待处理 \(model.pending.count)").font(.subheadline)
            if model.pending.isEmpty { Text("暂时没有待处理的草稿").foregroundStyle(.secondary) }
            ForEach(model.pending.suffix(4).reversed()) { item in
                Button {
                    model.selectedID = item.id
                    showWindow("workbench")
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.input.subject).lineLimit(1)
                            Text(item.state.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, 3)
            }
            Divider()
            Button("打开工作台") { showWindow("workbench") }
            if !model.onboarding.completed {
                Button("开始使用") { showWindow("onboarding") }
            }
            Button(model.settings.paused ? "恢复处理" : "暂停处理", action: model.togglePause)
            SettingsButton()
            Divider()
            Button("退出 Mailpipe") { NSApp.terminate(nil) }
        }.padding().frame(width: 320)
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

struct PendingWorkbench: View {
    @ObservedObject var model: PendingModel
    @State private var filter = WorkbenchFilter.pending
    @State private var showManual = false
    @Environment(\.openWindow) private var openWindow
    private var visible: [StoredReply] { model.records.filter(filter.includes).reversed() }
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(visible) { item in
                    WorkbenchMessageRow(subject: item.input.subject, sender: item.correspondents?.sender ?? "发件地址未采集", date: item.capturedAt)
                        .tag(item.id)
                        .task(id: item.id + model.settings.revision.uuidString) { await model.loadCorrespondents(item) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
            .overlay {
                if visible.isEmpty { Text("暂时没有\(filter == .failed ? "失败的任务" : "待处理的草稿")").foregroundStyle(.secondary).padding() }
            }
        } detail: {
            VStack(spacing: 0) {
                if !model.onboarding.completed {
                    HStack {
                        Label("连接工具并确认处理方式后，为新邮件备好草稿。", systemImage: "info.circle")
                        Spacer()
                        Button("开始使用") { openWindow(id: "onboarding") }
                    }.padding().background(Color(nsColor: .controlBackgroundColor))
                } else if model.needsPermissionRecovery {
                    HStack {
                        Label("请在设置中确认来信处理范围和 AI 工具。已有草稿保留。", systemImage: "exclamationmark.shield")
                        Spacer(); SettingsButton()
                    }.padding().background(Color(nsColor: .controlBackgroundColor))
                } else if model.settings.suggestionsOnly == true {
                    HStack {
                        Text("逐封建议：提交前由你确认内容与工具。").foregroundStyle(.secondary)
                        Spacer()
                        Button("添加来信…") { showManual = true }.disabled(model.settings.paused)
                    }.padding()
                }
                if let issue = model.issue {
                    HStack {
                        Label(issue, systemImage: "exclamationmark.triangle")
                        Spacer(); SettingsButton()
                        Button { model.issue = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭提示")
                    }.font(.callout).padding().background(Color(nsColor: .controlBackgroundColor))
                }
                if let item = model.selected, filter.includes(item) {
                    DraftDetail(model: model, item: item).id(item.id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.bubble").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text(visible.isEmpty ? "暂时没有待处理的草稿" : "选择一封来信").font(.title2)
                        Text("审阅来信，编辑回复，再复制到 Mail。") .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let notice = model.notice {
                    HStack {
                        Text(notice)
                        if model.undoDiscardID != nil { Button("撤销", action: model.undoDiscard) }
                        Spacer()
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭反馈")
                    }.padding().background(Color(nsColor: .controlBackgroundColor)).accessibilityElement(children: .contain)
                }
            }.frame(minWidth: 440).background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle("Mailpipe")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("视图", selection: $filter) {
                    ForEach(WorkbenchFilter.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).fixedSize()
            }
        }
        .sheet(isPresented: $showManual) { ManualSuggestionView(model: model) }
    }
}

private struct WorkbenchMessageRow: View {
    let subject: String
    let sender: String
    let date: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(subject.isEmpty ? "（无主题）" : subject).lineLimit(1).truncationMode(.tail)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sender).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text(date, format: Calendar.autoupdatingCurrent.isDateInToday(date)
                     ? .dateTime.hour().minute()
                     : .dateTime.month(.twoDigits).day(.twoDigits))
                    .font(.caption).monospacedDigit().fixedSize()
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DraftDetail: View {
    @ObservedObject var model: PendingModel
    let item: StoredReply
    @State private var showExplanation = false
    @State private var confirmRegeneration = false
    @State private var confirmCopy = false
    @State private var showCompose = false
    @State private var composeRequest: MailComposeRequest?
    @State private var showCandidate = false
    @State private var editorHeight: CGFloat = 96
    @State private var locateRequest = 0
    @State private var focusRequest = 0
    @State private var locateRange: NSRange?
    private var bodyText: String { model.editorBody(item) }
    private var warnings: DraftContentWarnings { DraftContentWarnings(body: bodyText) }
    private var attention: DraftAttention { DraftAttention.resolve(in: bodyText) }
    private var incoming: String { item.displayBody ?? item.input.body }
    private var contentExpired: Bool { item.capturedAt < Date().addingTimeInterval(-7 * 86_400) || item.error == "contentExpired" }
    private var isExpired: Bool { contentExpired || ["policyChanged", "identityUnresolved", "identitySourceMismatch"].contains(item.error ?? "") }
    private var hasDraft: Bool { item.draft != nil || item.editedBody != nil || !bodyText.isEmpty }
    private var recipientAddresses: String {
        guard let recipients = item.correspondents?.recipients, !recipients.isEmpty else { return "收件地址未采集" }
        return recipients.joined(separator: "、")
    }
    private var canRegenerate: Bool {
        item.canRequestRegeneration(settings: model.settings)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(item.input.subject.isEmpty ? "（无主题）" : item.input.subject)
                            .font(.title2.weight(.semibold)).textSelection(.enabled).lineLimit(3)
                        Spacer(minLength: 0)
                        if let status = WorkbenchRowPresentation(
                            reply: bodyText, incoming: item.input.body,
                            preparing: item.isPreparing, failed: item.error != nil && item.state != .cancelled
                        ).status {
                            Text(status).font(.caption).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("发件人：\(item.correspondents?.sender ?? "发件地址未采集")")
                        Text("收件人（To）：\(recipientAddresses)")
                        if let cc = item.correspondents?.cc, !cc.isEmpty {
                            Text("抄送（Cc）：\(cc.joined(separator: "、"))")
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
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear { model.openEditor(item) }
        .task(id: item.id + model.settings.revision.uuidString) { await model.loadCorrespondents(item, includeBody: true) }
        .alert("草稿含未确认内容。仍要复制吗？", isPresented: $confirmCopy) {
            Button("返回编辑", role: .cancel) { focusRequest += 1 }
            Button("仍要复制") { copyReply() }
        } message: { Text("请先核对待补充、待确认的占位或表述。复制不会发送邮件。") }
        .alert("重新生成回复？", isPresented: $confirmRegeneration) {
            Button("取消", role: .cancel) { }
            Button("重新生成") { model.regenerate(item.id) }
        } message: {
            Text("当前编辑会保留。新结果进入候选预览，由你选择采用新稿或保留现稿。最多两次模型调用，会消耗工具额度。")
        }
        .sheet(isPresented: $showCandidate) { candidatePreview }
        .sheet(isPresented: $showCompose) {
            if let request = composeRequest { composePreview(request) }
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
    private var originalCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("原邮件", systemImage: "envelope")
                    .font(.headline)
                Spacer()
                Button("打开原邮件") { openOriginalMessage() }
                    .controlSize(.small)
                    .disabled(originalMessageURL == nil)
            }.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if item.displayBody == nil, !incoming.isEmpty, item.manualExecutable == nil {
                    Text("完整原文尚未取得，以下为已保存的正文。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(incoming.isEmpty ? (item.state == .awaitingBody ? "等待 Mail 提供邮件正文。收到正文前不会调用 AI，也无法重新生成。" : "尚未取得可阅读的正文，请核对 Mail 权限和邮件格式。") : incoming)
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1).allowsHitTesting(false) }
    }
    private var draftCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("回复草稿", systemImage: "square.and.pencil")
                    .font(.headline)
                Spacer()
                saveStatus
            }.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                attentionLine
                if let handoff = item.composeHandoff {
                    Text(handoff.receipt == nil ? "已尝试打开 Mail，但结果待核对。请先检查 Mail，避免重复创建。" : "已创建 Mail 撰写窗口，后续请在 Mail 中核对和编辑；尚未发送。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isExpired {
                    Text("原信或授权需要重新核对。当前编辑保留。")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
                if let error = item.error {
                    Text(errorDescription(error)).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
                if item.isPreparing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在生成…").font(.callout)
                        Spacer()
                        Button("取消", action: { model.cancel(item.id) })
                    }.padding(.top, 8)
                }
                replyEditor.padding(.top, 12)
                if item.hasDraftCandidate {
                    HStack {
                        Label("新稿待选择，当前编辑未替换", systemImage: "doc.badge.clock").font(.caption)
                        Spacer()
                        Button("候选预览") { showCandidate = true }
                    }.padding(.top, 12)
                }
            }.padding(16)
            Divider()
            actions.padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1).allowsHitTesting(false) }
    }
    @ViewBuilder private var attentionLine: some View {
        switch attention {
        case .none:
            EmptyView()
        case .generic:
            Text(attention.message ?? "这份草稿需要你核对")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
        case .located:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(attention.message ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if attention.canLocate {
                    Button("定位") {
                        if case .located(_, _, let location, let length) = attention {
                            locateRange = NSRange(location: location, length: length)
                            locateRequest += 1
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("定位")
                }
            }.padding(.top, 6)
        }
    }
    private var replyEditor: some View {
        ZStack(alignment: .topLeading) {
            ReplyTextView(
                text: Binding(get: { bodyText }, set: { model.editBody(item, body: $0) }),
                enabled: !(item.isPreparing && !hasDraft),
                locateRequest: locateRequest,
                locateRange: locateRange,
                focusRequest: focusRequest,
                measuredHeight: $editorHeight)
            if bodyText.isEmpty {
                Text(item.isPreparing ? "正在准备回复，现有编辑会保留。" : "点击此处输入回复正文…")
                    .font(.body).foregroundStyle(.secondary)
                    .padding(.top, 2).padding(.leading, 4)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: max(160, editorHeight), maxHeight: max(160, editorHeight), alignment: .topLeading)
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
    @ViewBuilder private var saveStatus: some View {
        switch model.saveState(item) {
        case .failed:
            Button("未能保存，点此重试") { model.flushEditor(item.id) }
                .font(.caption).buttonStyle(.link)
        case .saving:
            Text("保存中…").font(.caption).foregroundStyle(.secondary).accessibilityLabel("保存状态：保存中")
        case .saved:
            if hasDraft {
                Text("已保存").font(.caption).foregroundStyle(.secondary).accessibilityLabel("保存状态：已保存")
            } else {
                EmptyView()
            }
        }
    }
    private func composePreview(_ request: MailComposeRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("在 Mail 中打开撰写窗口").font(.title2.weight(.semibold))
            Text("发件账户：\(request.accountName)")
            Text("发件人：\(request.sender)")
            Text("收件人：\(request.recipients.joined(separator: "、"))")
                .textSelection(.enabled)
            Text("主题：\(request.subject)").textSelection(.enabled)
            ScrollView { Text(request.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(minHeight: 140, maxHeight: 260).padding(12)
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)) }
            if DraftContentWarnings(body: request.body).requiresCopyConfirmation {
                Text("草稿含待补充或待核实内容，请在发送前检查。").font(.callout).foregroundStyle(.orange)
            }
            Text("只新建撰写窗口，不会发送。使用原邮件 Reply-To（如有）或 From；不会自动添加其他收件人。请在 Mail 中最终核对并自行发送。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("取消") { showCompose = false }.disabled(model.composeBusy)
                Spacer()
                if model.composeBusy { ProgressView().controlSize(.small) }
                Button("打开撰写窗口") {
                    Task { _ = await model.openCompose(request); showCompose = false }
                }.buttonStyle(.borderedProminent).disabled(model.composeBusy)
            }
        }.padding(24).frame(width: 560).interactiveDismissDisabled(model.composeBusy)
    }
    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    if let request = await model.prepareCompose(item) { composeRequest = request; showCompose = true }
                }
            } label: { Label(model.composeBusy ? "正在核对…" : (item.composeHandoff == nil ? "在 Mail 中打开" : "已尝试交给 Mail"), systemImage: "envelope") }
                .buttonStyle(.borderedProminent)
                .disabled(model.composeBusy || item.composeHandoff != nil || item.isPreparing || isExpired || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button {
                if warnings.requiresCopyConfirmation { confirmCopy = true }
                else { copyReply() }
            } label: { Label("复制回复", systemImage: "doc.on.doc") }
                .buttonStyle(.bordered)
                .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("重新生成") { confirmRegeneration = true }.disabled(!canRegenerate)
            Menu {
                Button("查看处理说明 / 数据去向") { showExplanation = true }
                Divider()
                Button("丢弃草稿", role: .destructive) { model.discard(item.id) }.disabled(item.isPreparing)
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多草稿操作")
            Spacer(minLength: 0)
            Button { showExplanation = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).accessibilityLabel("查看处理说明与数据去向")
                .popover(isPresented: $showExplanation) { explanation }
        }.controlSize(.regular)
    }
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("处理说明").font(.headline)
            if let run = item.runs.last {
                Text("本次经 \(run.destination.harness.displayName) 处理。邮件会到达该工具配置的模型。Mailpipe 不设服务器。")
            } else { Text("尚未调用 AI 工具。") }
            Text("在 Mail 中打开会先核对原邮件及收件地址，再由你确认创建撰写窗口；不会发送。复制回复仅复制当前正文。")
            if (item.regenerationCount ?? 0) >= 3 { Text("已达到本封重新生成次数上限，当前回复仍可编辑。") }
            Text("状态提示按占位符和少量待核实表述识别，不代表事实核验。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding().frame(width: 340)
    }
    private var candidatePreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("候选预览").font(.title2.weight(.semibold))
            Text("当前编辑保持不变。采用新稿会替换回复正文。") .foregroundStyle(.secondary)
            ScrollView {
                Text(item.draft?.body ?? "候选稿暂不可用。")
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("稍后决定") { showCandidate = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保留现稿") { if model.resolveCandidate(item, adopt: false) { showCandidate = false } }
                Button("采用新稿") { if model.resolveCandidate(item, adopt: true) { showCandidate = false } }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 560, height: 440)
    }
    private func copyReply() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(bodyText, forType: .string) {
            model.notify("已复制回复正文。请到 Mail 中粘贴发送。")
        } else { model.notify("复制未成功，请重试。") }
    }
    private func errorDescription(_ code: String) -> String {
        if let rejection = MailBodyRejection(rawValue: code) { return rejection.reviewLabel }
        switch code {
        case "contentExpired": return "来信已超过处理有效期，请重新确认内容后使用逐封建议。"
        case "policyChanged", "revoked": return "处理授权已变更，请在设置中核对。"
        case "identitySourceMismatch": return "已找到原邮件，但采集内容与 Mail 原文不一致。请打开原邮件核对。"
        case "identityUnresolved", "identityUnavailable", "identityAmbiguous": return "无法唯一核对原邮件，请检查 Mail 权限和账户。"
        case "invalidOutput": return "AI 输出未通过校验。此记录没有保存具体原因。"
        case "outputJSON": return "AI 返回的内容无法解析为 JSON 对象。"
        case "outputFields": return "AI 返回的字段、类型或枚举值不符合要求。"
        case "outputReference": return "AI 返回的版本或邮件、请求标识与本次请求不符。"
        case "outputSummary": return "AI 返回的摘要条数或长度不符合要求。"
        case "outputEvidence": return "AI 返回的引文无法与原文对应，或超出了引文限制。"
        case "cancelled": return "任务已取消，当前编辑保留。"
        default: return "处理未成功，当前编辑保留。请检查 AI 工具连接。"
        }
    }
}

private struct ReplyTextView: NSViewRepresentable {
    @Binding var text: String
    var enabled: Bool
    var locateRequest: Int
    var locateRange: NSRange?
    var focusRequest: Int
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, measuredHeight: $measuredHeight)
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
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
        view.textContainerInset = NSSize(width: 2, height: 2)
        view.textContainer?.lineFragmentPadding = 2
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.string = text
        applyTypingStyle(view)
        view.setAccessibilityLabel("回复草稿，可编辑")
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.measuredHeight = $measuredHeight
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
        if context.coordinator.appliedLocate != locateRequest, let range = locateRange {
            context.coordinator.appliedLocate = locateRequest
            select(range, in: view)
        }
        if context.coordinator.appliedFocus != focusRequest {
            context.coordinator.appliedFocus = focusRequest
            view.window?.makeFirstResponder(view)
        }
        publishHeight(of: view)
    }

    private func applyTypingStyle(_ view: NSTextView) {
        let font = NSFont.preferredFont(forTextStyle: .body)
        view.font = font
        view.textColor = .labelColor
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
    }

    private func select(_ range: NSRange, in view: NSTextView) {
        let limit = (view.string as NSString).length
        guard range.location != NSNotFound, range.location + range.length <= limit else { return }
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        view.window?.makeFirstResponder(view)
    }

    private func publishHeight(of view: NSTextView) {
        guard let container = view.textContainer, let layout = view.layoutManager else { return }
        let width = max(view.bounds.width, 240)
        container.containerSize = NSSize(width: max(40, width - view.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let height = max(88, ceil(used.height + view.textContainerInset.height * 2 + 12))
        let binding = $measuredHeight
        guard abs(height - binding.wrappedValue) > 1 else { return }
        DispatchQueue.main.async {
            if abs(height - binding.wrappedValue) > 1 { binding.wrappedValue = height }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var measuredHeight: Binding<CGFloat>
        var appliedLocate = 0
        var appliedFocus = 0
        init(text: Binding<String>, measuredHeight: Binding<CGFloat>) {
            self.text = text
            self.measuredHeight = measuredHeight
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if text.wrappedValue != view.string { text.wrappedValue = view.string }
        }
    }
}

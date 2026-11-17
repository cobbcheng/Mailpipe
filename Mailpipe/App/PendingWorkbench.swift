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
    @Published var mailboxChoices: [AccountScope] = []
    @Published var mailboxLoading = false
    @Published var mailboxIssue: String?
    var attemptedMailboxDiscovery = false
    @Published var onboarding = OnboardingDraft()
    @Published var onboardingResult: StoredReply?
    @Published var onboardingBusy = false
    @Published var onboardingIssue: String?
    @Published var extensionObservation: ExtensionObservation?
    var offeredOnboarding = false
    private var onboardingSession: OnboardingSession?
    private var onboardingTask: Task<Void, Never>?
    private var pipeline: ReplyPipeline?
    private var worker: Task<Void, Never>?
    private var display: Task<Void, Never>?
    private(set) var hasSharedInbox = false
    var needsPermissionRecovery: Bool { onboarding.completed && settings.suggestionsOnly != true && (settings.permission == nil || settings.authorizedScopes.isEmpty) }
    var pending: [StoredReply] { records.filter { $0.discardedAt == nil && ($0.state.isPending || $0.isPreparing || $0.state == .needsReview || $0.state == .awaitingBody) } }
    @Published var notice: String?
    @Published var undoDiscardID: String?
    private var noticeTask: Task<Void, Never>?
    var toolName: String { installations.first { $0.executable.path == settings.executable }?.kind.displayName ?? "AI 工具" }
    func notify(_ text: String) { notice = text }
    func saveEdits(_ id: String, subject: String, body: String) {
        do { try pipeline?.store.saveEdits(id, subject: subject, body: body); refresh() }
        catch { issue = "无法保存编辑，请保留当前窗口后重试。" }
    }
    func discard(_ id: String) {
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
        do { try pipeline?.regenerate(id); refresh() }
        catch { issue = "无法重新生成。请核对暂停、账户授权、工具和邮件有效期；每封最多重新生成三次。" }
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
                guard let messageID = item.messageID,
                      let match = try AppleMailReplyIdentity.resolve(accountID: scope.accountID, mailboxName: scope.mailboxName,
                          messageID: messageID, subject: item.input.subject, mailboxPath: scope.mailboxPath) else { return nil }
                let source = Data(match.source.utf8)
                if let evidence = item.sourceEvidence {
                    guard evidence.matches(source) else { return nil }
                } else {
                    guard let expected = item.sourceDigest, mailSourceDigest(source) == expected else { return nil }
                }
                return VerifiedMail(accountID: match.accountID, localID: match.localID, source: source)
            })
            onboardingSession = try OnboardingSession(store: store)
            onboarding = try store.onboarding()
            attemptedMailboxDiscovery = onboarding.automationDenied == true
            onboardingResult = try onboardingSession?.testResult()
            settings = try store.settings()
            // Reconcile a crash between authoritative policy and extension snapshot updates.
            try pipeline?.inbox.setPermission(settings.paused ? nil : settings.permission)
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
    private func discoverMailboxChoices() throws -> [AccountScope] {
        let choices = try AppleMailReplyIdentity.inboxes().map {
            try AccountScope(accountID: $0.accountID, accountName: $0.accountName,
                             mailboxName: $0.path.last!, mailboxPath: $0.path)
        }
        // One selectable account maps to exactly one system-designated inbox.
        guard Set(choices.map(\.accountID)).count == choices.count else { throw IdentityQueryError.invalidResult }
        return choices.sorted { ($0.accountName, $0.accountID) < ($1.accountName, $1.accountID) }
    }

    func loadMailboxes() {
        guard !mailboxLoading, !onboarding.isSuggestionsOnly else { return }
        attemptedMailboxDiscovery = true; mailboxLoading = true; mailboxIssue = nil
        Task { @MainActor in
            await Task.yield()
            defer { mailboxLoading = false }
            do {
                mailboxChoices = try discoverMailboxChoices()
                onboarding.automationDenied = false; saveOnboarding()
                if mailboxChoices.isEmpty { mailboxIssue = "Apple Mail 尚未发现可用账户的收件箱。请先在 Mail 添加账户，再刷新。" }
            } catch {
                mailboxChoices = []
                if case IdentityQueryError.automation(-1743) = error {
                    onboarding.automationDenied = true; saveOnboarding()
                    mailboxIssue = "Mail 自动化权限被拒绝。可以选择“逐封建议”，手动粘贴并确认一封内容；不会自动读取或外发。"
                } else if case IdentityQueryError.automation(let code) = error {
                    mailboxIssue = "无法读取账户列表（\(code)），请确认 Mail 可用后重新读取。"
                } else { mailboxIssue = "无法读取账户列表，请确认 Mail 可用后重新读取。" }
            }
        }
    }
    func selectMailbox(_ scope: AccountScope, selected: Bool) {
        var scopes = onboarding.selections.filter { $0.accountID != scope.accountID }
        if selected { scopes.append(scope) }
        onboarding.selectedScopes = scopes.sorted { $0.id < $1.id }
        saveOnboarding()
    }
    var mailboxSelectionValid: Bool {
        !onboarding.selections.isEmpty && onboarding.selections.allSatisfy { mailboxChoices.contains($0) }
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
        Task {
            defer { onboardingBusy = false }
            do {
                let report = try await DeepSeekHarnessAdapter(executable: URL(fileURLWithPath: snapshot.executable), dialect: DeepSeekHarnessDialect()).inspect()
                guard report.supportsHeadlessRun, onboarding == snapshot else { throw MailpipeError.unsupportedVersion }
                if !snapshot.isSuggestionsOnly {
                    let current = try discoverMailboxChoices()
                    mailboxChoices = current
                    guard !snapshot.selections.isEmpty, snapshot.selections.allSatisfy({ current.contains($0) }) else { throw IdentityQueryError.invalidScope }
                }
                try session.activate(scopes: snapshot.isSuggestionsOnly ? [] : snapshot.selections)
                let active = try session.store.settings()
                try pipeline.inbox.setPermission(active.paused ? nil : active.permission)
                onboarding = try session.store.onboarding(); refresh()
                onboardingIssue = active.suggestionsOnly == true ? "逐封建议已就绪；每封提交前需确认内容和工具。" : active.paused ? "配置已保存；仍保持暂停。" : "已授权，等待新邮件验证。"
            } catch let error as IdentityQueryError {
                switch error {
                case .automation(-1743):
                    onboarding.automationDenied = true; saveOnboarding()
                    onboardingIssue = "Mail 自动化权限被拒绝（-1743）。未保存新授权；草案和已有结果保留。可返回选择“逐封建议”，无需 Mail 自动化权限。"
                case .automation(let code):
                    onboardingIssue = "Mail 账户核验失败（\(code)）。未保存新授权；草案保留。"
                case .invalidScope:
                    onboardingIssue = "无法唯一识别所选账户或邮箱。请核对名称；未保存新授权。"
                case .invalidResult:
                    onboardingIssue = "Mail 返回的账户信息无法核验；未保存新授权。"
                }
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
        guard item.discardedAt == nil else { return false }
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
                    model.selectedID = item.id; openWindow(id: "workbench"); NSApp.activate(ignoringOtherApps: true)
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
            Button("打开工作台") { openWindow(id: "workbench"); NSApp.activate(ignoringOtherApps: true) }
            if !model.onboarding.completed {
                Button("开始使用") { openWindow(id: "onboarding"); NSApp.activate(ignoringOtherApps: true) }
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
                Section("\(filter.rawValue) · \(visible.count)") {
                    ForEach(visible) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.input.subject).fontWeight(model.selectedID == item.id ? .semibold : .medium).lineLimit(2)
                            Text(item.displayedBody.isEmpty ? "等待准备回复" : item.displayedBody)
                                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Text(item.state.label)
                                Spacer()
                                Text(item.capturedAt, format: .dateTime.month(.twoDigits).day(.twoDigits))
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).tag(item.id)
                    }
                }
            }.listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
                .overlay {
                    if visible.isEmpty { Text("暂时没有\(filter == .failed ? "失败的任务" : "待处理的草稿")").foregroundStyle(.secondary).padding() }
                }
        } detail: {
            VStack(spacing: 0) {
                if !model.onboarding.completed {
                    HStack {
                        Label("连接工具并选择邮箱后，为新邮件备好草稿。", systemImage: "info.circle")
                        Spacer()
                        Button("开始使用") { openWindow(id: "onboarding") }
                    }.padding().background(Color(nsColor: .controlBackgroundColor))
                } else if model.needsPermissionRecovery {
                    HStack {
                        Label("账户授权已撤销。已有草稿保留，请在设置中恢复。", systemImage: "exclamationmark.shield")
                        Spacer(); SettingsButton()
                    }.padding().background(Color(nsColor: .controlBackgroundColor))
                } else if model.settings.suggestionsOnly == true {
                    HStack {
                        Text("逐封建议：提交前由你确认内容与工具。").foregroundStyle(.secondary)
                        Spacer()
                        Button("添加来信…") { showManual = true }.disabled(model.settings.paused)
                    }.padding()
                }
                if model.issue != nil {
                    HStack {
                        Label("处理需要核对，已有草稿和编辑已保留。", systemImage: "exclamationmark.triangle")
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

private struct DraftDetail: View {
    @ObservedObject var model: PendingModel
    let item: StoredReply
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var showOriginal = false
    @State private var showExplanation = false
    @State private var confirmRegeneration = false
    @State private var confirmReplacement = false
    private var hasDraft: Bool { item.draft != nil || item.editedBody != nil }
    private var isExpired: Bool { item.capturedAt < Date().addingTimeInterval(-7 * 86_400) || ["contentExpired", "policyChanged", "identityUnresolved"].contains(item.error ?? "") }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.input.subject).font(.title2.weight(.semibold)).textSelection(.enabled)
                    HStack {
                        Text("发件人未采集")
                        Text("·")
                        Text(item.capturedAt, format: .dateTime.year().month().day().hour().minute())
                    }.font(.callout).foregroundStyle(.secondary)
                    Label(item.state.label, systemImage: item.isPreparing ? "hourglass" : item.error != nil ? "exclamationmark.circle" : "text.bubble")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if isExpired {
                    Label("原邮件或授权需要重新核对，当前编辑已保留。", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
                DisclosureGroup("来信原文", isExpanded: $showOriginal) {
                    Text(item.input.body.isEmpty ? "尚未取得可阅读的正文。请核对 Mail 权限和邮件格式。" : item.input.body)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                Divider()
                if hasDraft {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("回复草稿").font(.headline)
                            Spacer()
                            Text("编辑自动保存在本机").font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("回复主题", text: $subject).textFieldStyle(.roundedBorder).accessibilityLabel("回复主题")
                        TextEditor(text: $bodyText).font(.body).frame(minHeight: 240)
                            .accessibilityLabel("回复草稿正文")
                        HStack {
                            Button {
                                NSPasteboard.general.clearContents()
                                if NSPasteboard.general.setString(bodyText, forType: .string) {
                                    model.notify("已复制。请到 Mail 中粘贴发送。")
                                } else { model.notify("复制未成功，请重试。") }
                            } label: { Label("复制草稿", systemImage: "doc.on.doc") }
                                .buttonStyle(.borderedProminent).disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .keyboardShortcut("c", modifiers: [.command, .shift])
                            Button("重新生成") { confirmRegeneration = true }
                                .disabled(item.isPreparing || item.runs.contains { $0.finishedAt == nil } || model.settings.paused || (item.regenerationCount ?? 0) >= 3 || item.capturedAt < Date().addingTimeInterval(-7 * 86_400))
                            Spacer()
                            Menu {
                                Button("丢弃草稿", role: .destructive) { model.discard(item.id) }
                            } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多草稿操作").disabled(item.isPreparing)
                        }
                        Text("复制后，请到 Mail 中粘贴并发送。").font(.caption).foregroundStyle(.secondary)
                        if let draft = item.draft, draft.body != bodyText, (item.regenerationCount ?? 0) > 0, item.state == .draftReady, item.error == nil {
                            DisclosureGroup("查看生成的草稿") {
                                Text(draft.body).textSelection(.enabled).padding(.vertical, 8)
                                Button("使用这份草稿") { confirmReplacement = true }
                            }
                        }
                    }
                } else if item.isPreparing {
                    ProgressView("正在准备…")
                } else {
                    Text(item.error == nil ? "这封来信尚无回复草稿。" : "未能准备草稿，请展开处理说明核对。").foregroundStyle(.secondary)
                    if item.canRecheckIdentity {
                        Button("重新核对来信") { model.recheck(item.id) }.disabled(model.settings.paused)
                    } else if item.state == .needsReview || item.state == .needsReply {
                        Button("重新生成") { confirmRegeneration = true }.disabled(model.settings.paused || (item.regenerationCount ?? 0) >= 3)
                    }
                }
                if item.isPreparing { Button("取消此任务") { model.cancel(item.id) } }
                Divider()
                DisclosureGroup("处理说明", isExpanded: $showExplanation) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let run = item.runs.last {
                            Text("本次经 \(run.destination.harness.displayName) 处理。邮件会到达该工具配置的模型。Mailpipe 不设服务器。")
                        } else { Text("尚未调用 AI 工具。") }
                        if let decision = item.decision { ForEach(decision.summary, id: \.self) { Text($0) } }
                        if let error = item.error { Text(errorDescription(error)) }
                        if (item.regenerationCount ?? 0) >= 3 { Text("已达本封重新生成次数上限。当前草稿仍可编辑和复制。") }
                    }.foregroundStyle(.secondary).padding(.top, 8)
                }
            }.padding(28).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onAppear { subject = item.displayedSubject; bodyText = item.displayedBody }
        .onChange(of: item.draftData) { _ in
            if item.editedBody == nil, let draft = item.draft { subject = draft.subject; bodyText = draft.body }
        }
        .onChange(of: subject) { _ in persist() }
        .onChange(of: bodyText) { _ in persist() }
        .alert("重新生成回复？", isPresented: $confirmRegeneration) {
            Button("取消", role: .cancel) { }
            Button("重新生成") { persist(); model.regenerate(item.id) }
        } message: {
            Text("当前编辑会保留。新结果备好后，由你选择是否替换。最多两次模型调用，消耗所选工具额度。")
        }
        .alert("替换当前编辑？", isPresented: $confirmReplacement) {
            Button("保留编辑", role: .cancel) { }
            Button("使用新草稿") { if let draft = item.draft { subject = draft.subject; bodyText = draft.body; persist() } }
        } message: { Text("将用生成的内容替换当前主题和正文。") }
    }
    private func persist() {
        guard hasDraft, subject != item.displayedSubject || bodyText != item.displayedBody else { return }
        model.saveEdits(item.id, subject: subject, body: bodyText)
    }
    private func errorDescription(_ code: String) -> String {
        if let rejection = MailBodyRejection(rawValue: code) { return rejection.reviewLabel }
        switch code {
        case "contentExpired": return "来信已超过处理有效期。请重新确认内容后使用逐封建议。"
        case "policyChanged", "revoked": return "处理授权已变更，请在设置中核对。"
        case "identityUnresolved", "identityUnavailable", "identityAmbiguous": return "无法唯一核对原邮件，请检查 Mail 权限和账户。"
        case "cancelled": return "任务已取消，当前编辑保留。"
        default: return "处理未成功，当前编辑保留。请检查 AI 工具连接。"
        }
    }
}

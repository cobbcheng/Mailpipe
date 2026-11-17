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
    var pending: [StoredReply] { records.filter { $0.state.isPending } }
    var selected: StoredReply? { records.first { $0.id == selectedID } }

    init() {
        do {
            let args = ProcessInfo.processInfo.arguments
            let diagnosticIndex = args.firstIndex(of: "--pipeline-directory")
            let root: URL, inboxURL: URL
            if let index = diagnosticIndex, index + 1 < args.count, args[index + 1].hasPrefix("/") {
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
                guard let messageID = item.messageID, let expected = item.sourceDigest,
                      let match = try AppleMailReplyIdentity.resolve(accountID: scope.accountID, mailboxName: scope.mailboxName,
                          messageID: messageID, subject: item.input.subject, mailboxPath: scope.mailboxPath),
                      mailSourceDigest(Data(match.source.utf8)) == expected else { return nil }
                return VerifiedMail(accountID: match.accountID, localID: match.localID)
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

struct PendingMenu: View {
    @ObservedObject var model: PendingModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mailpipe · 待处理 \(model.pending.count)").font(.headline)
                Spacer()
                Text(model.settings.paused ? "已暂停" : "运行中").foregroundStyle(.secondary)
            }
            if model.pending.isEmpty { Text("还没有需要回复的邮件或草稿。").foregroundStyle(.secondary) }
            ForEach(model.pending.prefix(8)) { item in
                Button {
                    model.selectedID = item.id; openWindow(id: "workbench"); NSApp.activate(ignoringOtherApps: true)
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.input.subject).lineLimit(1)
                        Text(item.state.label).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            if let issue = model.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("打开工作台") { openWindow(id: "workbench"); NSApp.activate(ignoringOtherApps: true) }
                Button(model.settings.paused ? "恢复" : "暂停", action: model.togglePause)
                Button("新手引导") { openWindow(id: "onboarding"); NSApp.activate(ignoringOtherApps: true) }
                Button("退出") { NSApp.terminate(nil) }
            }
        }.padding(16).frame(width: 370)
    }
}

struct PendingWorkbench: View {
    @ObservedObject var model: PendingModel
    @State private var showSettings = false
    @State private var onlyPending = true
    @State private var showManual = false
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Mailpipe").font(.largeTitle.bold())
                    Text("Apple Mail 主动回复助手").foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.settings.paused ? "已暂停" : "运行中")
                Button(model.settings.paused ? "恢复处理" : "暂停处理", action: model.togglePause)
                Button("新手引导") { model.editOnboarding(); openWindow(id: "onboarding") }
                if model.settings.suggestionsOnly == true {
                    Button("逐封建议…") { showManual = true }.disabled(model.settings.paused)
                }
                Button("账户与设置") { showSettings.toggle() }
            }
            if let issue = model.issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            if !model.onboarding.completed {
                Button("继续设置 · 第 \(model.onboarding.step) 步，共 5 步") { openWindow(id: "onboarding") }
            }
            HStack {
                Picker("视图", selection: $onlyPending) {
                    Text("待处理 \(model.pending.count)").tag(true)
                    Text("全部采集 \(model.records.count)").tag(false)
                }.pickerStyle(.segmented).frame(maxWidth: 320)
                Spacer()
                Text("草稿留在本机待处理，不会自动打开 Mail").font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                List(selection: $model.selectedID) {
                    ForEach(onlyPending ? model.pending : model.records) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.input.subject).lineLimit(2)
                            Text(item.state.label).font(.caption).foregroundStyle(.secondary)
                            Text(item.capturedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).tag(item.id)
                    }
                }.frame(minWidth: 240, idealWidth: 280)
                ScrollView {
                    if let item = model.selected {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(item.input.subject).font(.title2)
                            Text(item.state.label).font(.headline)
                            if item.manualExecutable != nil { Text("用户逐封确认 · 未核验 Mail 账户 · 不修改邮件").font(.caption) }
                            if let error = item.error { Text("原因：\(error)").foregroundStyle(.secondary) }
                            if let decision = item.decision {
                                Text("要不要回复：\(decision.shouldReply.rawValue)")
                                ForEach(decision.summary, id: \.self) { Text($0) }
                            }
                            if let draft = item.draft {
                                Divider()
                                Text(draft.subject).font(.headline)
                                Text(draft.body).textSelection(.enabled)
                                Text("草稿已备好；尚未发送。Mail 草稿交接尚未验收。").font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                            Text("本封数据去向").font(.headline)
                            if item.runs.isEmpty { Text("尚未调用模型") }
                            ForEach(item.runs, id: \.destination.runID) { run in
                                VStack(alignment: .leading) {
                                    Text("\(run.destination.taskKind.rawValue) · DeepSeek Harness")
                                    Text("\(run.destination.vendor ?? "厂商未知") · \(run.destination.model ?? "模型未知")")
                                    Text("输入 token：\(run.inputTokens.map(String.init) ?? "未知")；输出：\(run.outputTokens.map(String.init) ?? "未知")")
                                    if let error = run.error { Text("结果：\(error)") }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            if item.state == .needsReview && item.runs.isEmpty && !item.input.body.isEmpty {
                                Button("重新核验账户（不重放模型调用）") { model.recheck(item.id) }
                            }
                            if [.queued, .triaging, .draftQueued, .drafting, .awaitingAccount, .awaitingBody].contains(item.state) {
                                Button("取消此任务") { model.cancel(item.id) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding()
                    } else { Text("选择一封邮件查看分拣、草稿和数据去向").foregroundStyle(.secondary).padding(32) }
                }.frame(minWidth: 420)
            }
        }.padding(20).onAppear {
            if !model.onboarding.completed && !model.offeredOnboarding {
                model.offeredOnboarding = true; openWindow(id: "onboarding")
            }
        }.sheet(isPresented: $showManual) { ManualSuggestionView(model: model) }
        .sheet(isPresented: $showSettings) {
            VStack(alignment: .leading, spacing: 14) {
                Text("账户与处理范围").font(.title2)
                Text("新邮件先在本机暂存；只有在所选账户与邮箱中唯一核验后，才交给 DeepSeek 官方模型。正文最长 16 KiB，仅支持单段纯文本；其他格式会显示待核对。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("处理范围请通过五步向导修改。保存草案不会改变当前授权。")
                Button("打开新手引导") { showSettings = false; model.editOnboarding(); openWindow(id: "onboarding") }
                Button("撤销采集和账户授权", action: model.revoke)
                HStack {
                    Button("工具诊断") { openWindow(id: "diagnostics") }
                    Button("M0 身份验证") { openWindow(id: "identity-probe") }
                    Spacer()
                    Button("完成") { showSettings = false }
                }
            }.padding(24).frame(width: 680)
        }
    }
}

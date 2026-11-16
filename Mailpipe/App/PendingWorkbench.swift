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
    @Published var accountName = ""
    @Published var mailboxName = "INBOX"
    @Published var executable = ""
    @Published var level: ServiceLevel = .default
    @Published var exactSubject = ""
    @Published var installations: [HarnessInstallation] = []
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
                          messageID: messageID, subject: item.input.subject),
                      mailSourceDigest(Data(match.source.utf8)) == expected else { return nil }
                return VerifiedMail(accountID: match.accountID, localID: match.localID)
            })
            settings = try store.settings()
            // Reconcile a crash between authoritative policy and extension snapshot updates.
            try pipeline?.inbox.setPermission(settings.paused ? nil : settings.permission)
            accountName = settings.scope?.accountName ?? ""; mailboxName = settings.scope?.mailboxName ?? "INBOX"
            installations = HarnessDiscovery.find().filter { $0.kind == .deepseek }
            executable = settings.executable ?? installations.first?.executable.path ?? ""
            level = settings.level
            exactSubject = settings.permission?.exactSubject ?? ""
            refresh(); start()
            display = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } catch { issue = "无法打开持久化队列：\(Self.code(error))" }
    }
    func refresh() {
        guard let pipeline else { return }
        do {
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
    func grantCapture() {
        guard hasSharedInbox else { issue = "共享容器不可用；请使用签名 App 启用 Mail 扩展。"; return }
        do {
            guard installations.contains(where: { $0.executable.path == executable }) else { throw MailpipeError.notInstalled }
            let id = try AppleMailReplyIdentity.accountID(named: accountName, mailbox: mailboxName)
            let scope = try AccountScope(accountID: id, accountName: accountName, mailboxName: mailboxName)
            let permission = CapturePermission(exactSubject: exactSubject.isEmpty ? nil : exactSubject)
            try change { $0.scope = scope; $0.permission = permission; $0.executable = executable; $0.level = level }
            issue = "已保存账户授权；只接收未来的新回调。"
        } catch { issue = "授权未完成：\(Self.code(error))" }
    }
    func revoke() {
        do { try change { $0.permission = nil; $0.scope = nil } }
        catch { issue = Self.code(error) }
    }
    func synthetic() {
        do {
            guard let pipeline, !settings.paused,
                  installations.contains(where: { $0.executable.path == executable }) else { throw MailpipeError.notInstalled }
            if settings.executable != executable { try change { $0.executable = executable } }
            selectedID = try pipeline.enqueueSynthetic(); refresh()
        } catch { issue = "合成验证未开始：\(Self.code(error))" }
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
                Button("退出") { NSApp.terminate(nil) }
            }
        }.padding(16).frame(width: 370)
    }
}

struct PendingWorkbench: View {
    @ObservedObject var model: PendingModel
    @State private var showSettings = false
    @State private var onlyPending = true
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
                Button("账户与设置") { showSettings.toggle() }
            }
            if let issue = model.issue { Text(issue).font(.callout).foregroundStyle(.secondary) }
            if model.settings.permission == nil { Text("尚未授权新邮件采集。可在账户与设置中配置，或运行合成验证。").font(.callout) }
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
        }.padding(20).sheet(isPresented: $showSettings) {
            VStack(alignment: .leading, spacing: 14) {
                Text("账户与处理范围").font(.title2)
                Text("新邮件先在本机暂存；只有在所选账户与邮箱中唯一核验后，才交给 DeepSeek 官方模型。正文最长 16 KiB，仅支持单段纯文本；其他格式会显示待核对。")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Apple Mail 账户名称", text: $model.accountName)
                TextField("邮箱名称", text: $model.mailboxName)
                TextField("仅采集此主题（可选，用于缩小范围）", text: $model.exactSubject)
                Picker("DeepSeek Harness", selection: $model.executable) {
                    Text("请选择").tag("")
                    ForEach(model.installations) { Text($0.executable.path).tag($0.executable.path) }
                }
                Picker("服务级别", selection: $model.level) {
                    Text("L0 · 不准备回复").tag(ServiceLevel.l0)
                    Text("L1 · 提示需要回复").tag(ServiceLevel.l1)
                    Text("L2 · 备好草稿（默认）").tag(ServiceLevel.l2)
                }
                Text("当前只提供回复链路。L0 的 Mail 整理动作尚未接入。内容会发给模型厂商，消耗自己的 Harness 额度；不经过 Mailpipe 服务器。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("授权范围并接收未来新邮件", action: model.grantCapture)
                    Button("撤销采集和账户授权", action: model.revoke)
                }
                Divider()
                Text("合成验证：最多两次模型调用，无邮箱访问或 Mail 动作。")
                Button("运行合成端到端验证", action: model.synthetic).disabled(model.settings.paused)
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

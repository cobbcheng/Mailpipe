import Foundation
import MailpipeCore
import HarnessAdapters

public struct VerifiedMail: Sendable {
    public let accountID: String
    public let localID: String
    public init(accountID: String, localID: String) { self.accountID = accountID; self.localID = localID }
}
public typealias MailIdentityResolver = @MainActor @Sendable (StoredReply, AccountScope) async throws -> VerifiedMail?

@MainActor
public final class ReplyPipeline {
    public let store: PipelineStore
    public let inbox: CaptureInbox
    private let resolve: MailIdentityResolver
    private let model: @Sendable (String) -> any ReplyModelRunning
    private var pumping = false
    public init(store: PipelineStore, inbox: CaptureInbox, resolve: @escaping MailIdentityResolver,
                model: @escaping @Sendable (String) -> any ReplyModelRunning = {
                    DeepSeekHarnessAdapter(executable: URL(fileURLWithPath: $0), dialect: DeepSeekHarnessDialect())
                }) {
        self.store = store; self.inbox = inbox; self.resolve = resolve; self.model = model
    }
    public func updateSettings(_ change: (inout PipelineSettings) -> Void) throws {
        let previous = try store.settings()
        var settings = previous; change(&settings)
        if settings.permission != previous.permission || settings.authorizedScopes != previous.authorizedScopes ||
            settings.executable != previous.executable || settings.level != previous.level { settings.revision = UUID() }
        // DB is authoritative. A crash before the extension snapshot changes cannot grant a model call.
        try store.saveSettings(settings)
        try inbox.setPermission(settings.paused ? nil : settings.permission)
    }
    public func importInbox() throws {
        try inbox.pruneClaims()
        if let issue = try inbox.issue() { try store.note(issue) }
        let files = try inbox.files().sorted {
            let a = (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? .distantPast
            let b = (try? FileManager.default.attributesOfItem(atPath: $1.path)[.modificationDate] as? Date) ?? .distantPast
            return a < b
        }
        for file in files {
            let capture: InboundCapture
            do {
                capture = try JSONDecoder().decode(InboundCapture.self, from: CaptureInbox.read(file, limit: 100_000))
                try capture.validate()
            } catch {
                try store.note("invalidCapture")
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory != true || values.isSymbolicLink == true { try FileManager.default.removeItem(at: file) }
                continue
            }
            do { try store.importCapture(capture) }
            catch PipelineError.quota { try store.note("quota"); break }
            catch PipelineError.revoked {
                try store.note("captureExpiredOrRevoked")
                try FileManager.default.removeItem(at: file); continue
            }
            // A database or decoding failure is not invalid input: retain the spool for recovery.
            try FileManager.default.removeItem(at: file)
        }
    }
    public func recheckIdentity(_ id: String) throws {
        guard var item = try store.record(id), item.runs.isEmpty, !item.input.body.isEmpty,
              item.state == .needsReview, item.permissionID == (try store.settings()).permission?.id else { throw MailpipeError.invalidInput }
        item.accountID = nil; item.localID = nil; item.revision = nil
        item.state = .awaitingAccount; item.error = nil; try store.save(item)
    }
    public func cancel(_ id: String) throws {
        guard var item = try store.record(id) else { return }
        item.state = .cancelled; item.error = "cancelled"; try store.save(item)
    }
    /// Process bounded batches; each timer tick is serial. No automatic retry of failed/unknown calls.
    public func pump() async throws {
        guard !pumping else { return }
        pumping = true; defer { pumping = false }
        try importInbox()
        for item in try store.records().prefix(1_000) {
            try Task.checkCancellation()
            if try store.settings().paused { return }
            if [.awaitingAccount, .queued, .draftQueued].contains(item.state) { try await process(item.id) }
        }
    }
    private func process(_ id: String) async throws {
        guard var item = try store.record(id) else { return }
        let settings = try store.settings()
        guard let executable = settings.executable, executable.hasPrefix("/"), !settings.paused else { return }
        guard item.capturedAt > Date().addingTimeInterval(-7 * 86_400) else {
            item.state = .needsReview; item.error = "contentExpired"; try store.save(item); return
        }
        if !item.syntheticAuthorized {
            guard settings.permission?.id == item.permissionID else {
                item.state = .cancelled; item.error = "revoked"; try store.save(item); return
            }
            let scopes = settings.authorizedScopes
            guard !scopes.isEmpty else { return }
            if item.accountID == nil {
                do {
                    var matches: [(AccountScope, VerifiedMail)] = []
                    for scope in scopes {
                        if let verified = try await resolve(item, scope), verified.accountID == scope.accountID {
                            matches.append((scope, verified))
                        }
                    }
                    guard matches.count == 1, let (scope, verified) = matches.first else {
                        item.error = matches.isEmpty ? "identityUnresolved" : "identityAmbiguous"
                        item.state = .needsReview; try store.save(item); return
                    }
                    item.accountID = verified.accountID; item.localID = verified.localID; item.scopeID = scope.id
                } catch {
                    item.error = "identityUnavailable"; item.state = .needsReview; try store.save(item); return
                }
                guard try store.settings().revision == settings.revision else { return }
                if let duplicate = try store.records().first(where: {
                    $0.id != item.id && $0.accountID == item.accountID && $0.localID == item.localID &&
                    $0.input.subject == item.input.subject && $0.input.body == item.input.body
                }) {
                    try store.removeDuplicate(item, keeping: duplicate); return
                }
                item.revision = settings.revision; item.level = settings.level; item.state = .queued
                try store.save(item)
            }
        } else {
            // Only enqueueSynthetic can set this host-owned field. The spool cannot grant it.
            guard item.input.subject == ReplySyntheticFixture.triage.message.subject,
                  item.input.body == ReplySyntheticFixture.triage.message.body else { throw PipelineError.invalidCapture }
            item.accountID = "synthetic-validation"; item.localID = "synthetic-" + item.id
            if item.revision == nil { item.revision = settings.revision; item.level = settings.level; item.state = .queued; try store.save(item) }
        }
        guard item.revision == settings.revision else {
            item.state = .needsReview; item.error = "policyChanged"; try store.save(item); return
        }
        if item.state == .queued {
            try await invoke(id: id, task: .triage(item.triageRequest), kind: .triage, executable: executable)
        }
        guard var refreshed = try store.record(id), refreshed.state == .draftQueued else { return }
        guard let decision = refreshed.decision else {
            refreshed.state = .needsReview; refreshed.error = "invalidStoredDecision"; try store.save(refreshed); return
        }
        let request = try ReplyDraftRequest(requestID: refreshed.id + "-draft", triage: refreshed.triageRequest, decision: decision, level: refreshed.level)
        try await invoke(id: id, task: .draft(request), kind: .draft, executable: executable)
    }
    private func authorize(_ id: String, revision: UUID) throws {
        try Task.checkCancellation()
        let settings = try store.settings()
        guard !settings.paused else { throw MailpipeError.paused }
        guard settings.revision == revision, let item = try store.record(id),
              item.state == .triaging || item.state == .drafting,
              item.syntheticAuthorized || (settings.permission?.id == item.permissionID && settings.authorizedScopes.contains { $0.accountID == item.accountID && (item.scopeID == nil || $0.id == item.scopeID) }) else { throw PipelineError.revoked }
    }
    private func invoke(id: String, task: ReplyModelTask, kind: ReplyTaskKind, executable: String) async throws {
        guard var item = try store.record(id), let revision = item.revision else { throw PipelineError.storage }
        item.state = kind == .triage ? .triaging : .drafting
        let destination = try DataDestination(messageRef: id, runID: UUID().uuidString, taskKind: kind, harness: .deepseek)
        item.runs.append(PipelineRun(destination: destination, startedAt: Date()))
        try store.save(item)
        do {
            let output = try await model(executable).run(task, route: AccountRoute(accountID: item.accountID, allowedHarnesses: [.deepseek])) { [self] in
                try await MainActor.run { try self.authorize(id, revision: revision) }
            }
            guard var current = try store.record(id) else { throw PipelineError.storage }
            let last = current.runs.count - 1
            current.runs[last].destination = try DataDestination(messageRef: id, runID: destination.runID, taskKind: kind, harness: .deepseek,
                vendor: "deepseek-official", model: "deepseek-flash", evidence: .detected)
            current.runs[last].inputTokens = output.inputTokens; current.runs[last].outputTokens = output.outputTokens
            current.runs[last].inputCharacters = output.inputCharacters; current.runs[last].outputCharacters = output.outputCharacters
            current.runs[last].finishedAt = Date()
            try store.save(current)
            try authorize(id, revision: revision)
            switch task {
            case .triage(let request):
                let decision = try ReplyDecision.validated(output.content, for: request)
                current.decisionData = output.content
                switch current.level.disposition(for: decision) {
                case .none: current.state = decision.shouldReply == .unknown ? .needsReview : .noReply
                case .needsReply: current.state = .needsReply
                case .generateDraft: current.state = .draftQueued
                }
            case .draft(let request):
                _ = try ReplyDraft.validated(output.content, for: request)
                current.draftData = output.content; current.state = .draftReady
            }
            try store.save(current)
        } catch {
            guard var current = try store.record(id) else { throw PipelineError.storage }
            let code = (error as? MailpipeError)?.rawValue ?? (error as? PipelineError)?.rawValue ?? (error is CancellationError ? "cancelled" : "operationFailed")
            if current.state != .cancelled { current.state = .needsReview }
            current.error = code
            if !current.runs.isEmpty {
                current.runs[current.runs.count - 1].error = code
                current.runs[current.runs.count - 1].finishedAt = Date()
            }
            try store.save(current)
        }
    }
    /// Explicit user action authorizes only this fixed synthetic input and the selected dsh.
    /// Uses the same spool importer, durable states, model path and pending view as mail.
    @discardableResult public func enqueueSynthetic() throws -> String {
        let settings = try store.settings()
        guard !settings.paused, settings.executable != nil else { throw MailpipeError.paused }
        // A private temporary inbox avoids changing the user's MailKit capture consent.
        let temporary = store.directory.appendingPathComponent("synthetic-inbox")
        let syntheticInbox = try CaptureInbox(directory: temporary)
        let permission = CapturePermission(exactSubject: ReplySyntheticFixture.triage.message.subject)
        try syntheticInbox.setPermission(permission)
        let input = ReplySyntheticFixture.triage.message
        let raw = Data(("Content-Type: text/plain; charset=utf-8\r\n\r\n" + input.body).utf8)
        let capture = InboundCapture(permissionID: permission.id, subject: input.subject, messageID: "synthetic@example.com", raw: raw)
        try syntheticInbox.publish(capture)
        // Synthetic import has a separate explicit grant; production settings remain untouched.
        let persisted = try JSONDecoder().decode(InboundCapture.self, from: CaptureInbox.read(
            temporary.appendingPathComponent(capture.id.uuidString + ".capture"), limit: 100_000))
        let id = try store.importCapture(persisted, syntheticGrant: true)
        try FileManager.default.removeItem(at: temporary.appendingPathComponent(capture.id.uuidString + ".capture"))
        return id
    }
}

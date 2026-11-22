import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import MailpipeCore
import HarnessAdapters

public struct AccountScope: Codable, Hashable, Sendable, Identifiable {
    public let accountID: String
    public let accountName: String
    public let mailboxName: String
    public var mailboxPath: [String]?
    public var displayMailbox: String {
        let path = mailboxPath ?? [mailboxName]
        return (path.count > 1 && path.first == accountName ? Array(path.dropFirst()) : path).joined(separator: " / ")
    }
    public var id: String { ([accountID] + (mailboxPath ?? [mailboxName])).map { "\($0.utf8.count):\($0)" }.joined() }
    public init(accountID: String, accountName: String, mailboxName: String, mailboxPath: [String]? = nil) throws {
        guard [accountID, accountName, mailboxName].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 998 }) else { throw MailpipeError.invalidInput }
        self.mailboxPath = mailboxPath
        self.accountID = accountID; self.accountName = accountName; self.mailboxName = mailboxName
    }
}
public struct PipelineSettings: Codable, Sendable {
    public var revision = UUID()
    public var permission: CapturePermission?
    public var scope: AccountScope? // Legacy single-scope payloads remain readable.
    public var scopes: [AccountScope]?
    public var authorizedScopes: [AccountScope] { scopes ?? scope.map { [$0] } ?? [] }
    private var selectedHarness: HarnessKind?
    public var harnessKind: HarnessKind {
        get { selectedHarness ?? .deepseek }
        set { selectedHarness = newValue }
    }
    public var executable: String?
    public var openCodeModel: String?
    public fileprivate(set) var replyInstructions: String?
    public var level: ServiceLevel = .default
    var suggestionsOnly: Bool? // Decode the old manual-only policy without granting capture.
    public var paused = false
    public init() {}
}
public enum ReplyState: String, Codable, Sendable {
    case awaitingBody, awaitingAccount, queued, triaging, draftQueued, drafting
    case needsReply, draftReady, noReply, needsReview, cancelled
    public var label: String {
        switch self {
        case .awaitingBody: "等待正文"
        case .awaitingAccount: "待确认账户"
        case .queued: "等待分拣"
        case .triaging: "正在分拣"
        case .draftQueued: "等待起草"
        case .drafting: "正在起草"
        case .needsReply: "需要回复"
        case .draftReady: "草稿已备好"
        case .noReply: "无需准备回复"
        case .needsReview: "需要核对"
        case .cancelled: "已取消"
        }
    }
    public var isPending: Bool { self == .needsReply || self == .draftReady }
}
public struct PipelineRun: Codable, Sendable {
    public var destination: DataDestination
    public let startedAt: Date
    public var finishedAt: Date?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var inputCharacters: Int?
    public var outputCharacters: Int?
    public var error: String?
    public var readPullRequestDiff: Bool?
    public var actualCost: Double?

    mutating func record(_ output: ReplyModelOutput, installation: HarnessInstallation) throws {
        if installation.kind == .opencode {
            guard let actual = output.actualModel, OpenCodeDialect.validModelReference(actual),
                  installation.openCodeModel == nil || installation.openCodeModel == actual else {
                throw MailpipeError.invalidOutput
            }
        }
        if installation.kind == .codex {
            destination = try DataDestination(messageRef: destination.messageRef, runID: destination.runID, taskKind: .draft,
                harness: .codex, vendor: "OpenAI", model: "gpt-6.2-sol", evidence: .declared)
        }
        let modelName = installation.kind == .deepseek ? "deepseek-flash" : output.actualModel
        if let modelName {
            let usesOfficialDeepSeek = [.deepseek, .openclaw, .hermes].contains(installation.kind)
            destination = try DataDestination(messageRef: destination.messageRef, runID: destination.runID, taskKind: .draft,
                harness: installation.kind, vendor: usesOfficialDeepSeek ? "deepseek-official" : nil,
                model: modelName, evidence: .detected)
        }
        readPullRequestDiff = output.readPullRequestDiff
        inputTokens = output.inputTokens; outputTokens = output.outputTokens
        inputCharacters = output.inputCharacters; outputCharacters = output.outputCharacters
        finishedAt = Date()
    }
}
public enum InboxMembershipDecision {
    public static func combine(_ results: [Bool?]) -> Bool? {
        let included = results.filter { $0 == true }.count
        if included == 1 { return true }
        if included > 1 || results.isEmpty || results.contains(where: { $0 == nil }) { return nil }
        return false
    }
}
public struct StoredReply: Codable, Identifiable, Sendable {
    public let id: String
    public let permissionID: UUID
    public let capturedAt: Date
    public let messageID: String?
    public var input: MailInput
    public var state: ReplyState
    public var error: String?
    public var sourceDigest: String?
    public var sourceEvidence: MailSourceEvidence?
    public var displayBody: String?
    public var correspondents: MailCorrespondents?
    public var composeHandoff: MailComposeHandoff?
    public var accountID: String?
    public var localID: String?
    public var scopeID: String?
    public var revision: UUID?
    public var level: ServiceLevel = .default
    public var decisionData: Data?
    public var draftData: Data?
    public var runs: [PipelineRun] = []
    /// Build 43 shortened panel text. Keep its receipts separate from regeneration attempts.
    public internal(set) var composeShortenRuns: [PipelineRun]?
    public internal(set) var composeRegenerationRuns: [PipelineRun]?
    var isRegeneratingInCompose: Bool { composeRegenerationRuns?.last.map { $0.finishedAt == nil } ?? false }
    public var regenerationLimitReached: Bool { (regenerationCount ?? 0) + (composeRegenerationRuns?.count ?? 0) >= 3 }
    public var mailKitBody: Bool?
    public internal(set) var manualExecutable: String? // Identifies archived manually entered messages.
    public var syntheticAuthorized = false
    public var excludedFromAuthorizedInbox: Bool?
    public var editedSubject: String?
    public var editedBody: String?
    public var reviewedDraftVersion: String?
    public var draftVersion: String? {
        guard let draftData, draft != nil else { return nil }
        let runID = runs.last { $0.destination.taskKind == .draft && $0.finishedAt != nil && $0.error == nil }?.destination.runID ?? "legacy"
        return runID + ":" + contentDigest(draftData)
    }
    public var hasDraftCandidate: Bool {
        state == .draftReady && error == nil && editedBody != nil && (regenerationCount ?? 0) > 0 &&
        draftVersion != reviewedDraftVersion && draft?.body != editedBody && draft != nil
    }
    public var discardedAt: Date?
    public var approvedPullRequest: String?
    public var regenerationCount: Int?
    public var isPreparing: Bool { [.awaitingAccount, .queued, .triaging, .draftQueued, .drafting].contains(state) }
    public var displayedSubject: String { editedSubject ?? draft?.subject ?? input.subject }
    public var displayedBody: String { editedBody ?? draft?.body ?? "" }
    public func isReadyForReplyReminder(settings: PipelineSettings, now: Date) -> Bool {
        guard isReadyForComposeSuggestion(settings: settings, now: now) else { return false }
        // Both confirmed and unresolved handoffs remove that draft from the reminder.
        guard let handoff = composeHandoff else { return true }
        return runs.contains { $0.destination.taskKind == .draft && $0.error == nil && ($0.finishedAt ?? .distantPast) > handoff.startedAt }
    }
    func isReadyForComposeSuggestion(settings: PipelineSettings, now: Date) -> Bool {
        guard state == .draftReady, error == nil, isAuthorizedForCompose(settings: settings, now: now), let draft else { return false }
        return !(editedBody ?? draft.body).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func composeIdentity(includingBody: Bool) -> ComposeMessageIdentity? {
        guard let messageID, let correspondents, let sender = correspondents.sender else { return nil }
        return ComposeMessageIdentity(messageID: messageID, subject: input.subject, sender: sender,
            to: correspondents.recipients, cc: correspondents.cc,
            displayBody: includingBody ? (displayBody ?? input.body) : nil)
    }
    func isAuthorizedForCompose(settings: PipelineSettings, now: Date) -> Bool {
        guard discardedAt == nil, excludedFromAuthorizedInbox != true,
              !syntheticAuthorized, manualExecutable == nil, messageID?.isEmpty == false, !input.body.isEmpty,
              capturedAt > now.addingTimeInterval(-7 * 86_400),
              !settings.paused, let permission = settings.permission, permission.id == permissionID,
              permission.accepts(input.subject) else { return false }
        if mailKitBody == true {
            guard permission.delivery == .mailKit else { return false }
        } else {
            guard settings.authorizedScopes.contains(where: { $0.accountID == accountID && (scopeID == nil || $0.id == scopeID) }) else { return false }
        }
        return true
    }
    var canGenerateFirstComposeDraft: Bool {
        guard draftData == nil, editedSubject == nil, editedBody == nil, composeHandoff == nil,
              !isRegeneratingInCompose, !runs.contains(where: { $0.finishedAt == nil }) else { return false }
        switch state {
        case .needsReply, .noReply:
            return error == nil
        case .needsReview:
            guard let error, let code = MailpipeError(rawValue: error), runs.last?.error == error else { return false }
            // Safe to ask for a new draft after a known, completed failure.
            switch code {
            case .notInstalled, .launchFailed, .authRequired, .rateLimited, .quotaExhausted,
                 .invalidOutput, .outputLimit, .outputJSON, .outputFields, .outputReference, .outputSummary, .outputEvidence:
                return !regenerationLimitReached
            default: return false
            }
        default: return false
        }
    }
    /// UI preflight only; dispatch still rechecks the authoritative policy.
    public func canRequestRegeneration(settings: PipelineSettings, now: Date = Date()) -> Bool {
        guard manualExecutable == nil, excludedFromAuthorizedInbox != true, state != .awaitingBody, !settings.paused, !isPreparing, discardedAt == nil,
              !isRegeneratingInCompose, !runs.contains(where: { $0.finishedAt == nil }), !regenerationLimitReached,
              capturedAt > now.addingTimeInterval(-7 * 86_400), settings.executable != nil else { return false }
        if mailKitBody == true { return settings.permission?.id == permissionID && settings.permission?.delivery == .mailKit && !input.body.isEmpty }
        if syntheticAuthorized { return true }
        return settings.permission?.id == permissionID && settings.authorizedScopes.contains {
            $0.id == scopeID || (scopeID == nil && $0.accountID == accountID)
        }
    }
    public var canDisplayInWorkbench: Bool {
        guard excludedFromAuthorizedInbox != true else { return false }
        if state == .noReply && draftData == nil && (editedBody ?? "").isEmpty { return false }
        // Keep existing substantive content during a transient scope lookup failure.
        return mailKitBody == true || syntheticAuthorized || manualExecutable != nil || excludedFromAuthorizedInbox == false ||
            draft != nil || !input.body.isEmpty || !(editedBody ?? "").isEmpty
    }
    public var canRecheckIdentity: Bool {
        manualExecutable == nil && state == .needsReview && runs.isEmpty && (!input.body.isEmpty ||
            (sourceEvidence != nil && ["identitySourceMismatch", "identityUnresolved", "identityUnavailable", "identityAmbiguous"].contains(error ?? "")))
    }
    public var triageRequest: ReplyTriageRequest { ReplyTriageRequest(requestID: id + "-triage", message: input) }
    public var decision: ReplyDecision? { decisionData.flatMap { try? ReplyDecision.validated($0, for: triageRequest) } }
    public var draft: ReplyDraft? {
        guard let draftData, let request = try? ReplyDraftRequest(message: input) else { return nil }
        return try? ReplyDraft.validated(draftData, for: request)
    }
}

/// One host writer per directory. flock prevents CLI/UI double-dispatch; SQLite handles
/// crash-atomic writes. No background worker owns the database after the host exits.
@MainActor
public final class PipelineStore {
    // All operations are MainActor-isolated; deinit only closes an exclusively owned handle.
    nonisolated(unsafe) private var db: OpaquePointer?
    private var lockFD: Int32 = -1
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PipelineError.storage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw PipelineError.alreadyOpen }
        lockFD = fd
        guard sqlite3_open_v2(directory.appendingPathComponent("state.sqlite").path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw PipelineError.storage }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        let version = try scalar("PRAGMA user_version")
        guard version == "0" || version == "1" else { throw MailpipeError.unsupportedVersion }
        try execute("CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS ingests (id TEXT PRIMARY KEY, record_id TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS metadata (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try execute("PRAGMA user_version=1")
        for var item in try records() {
            let shortened = Self.closeInterruptedRun(&item.composeShortenRuns)
            let regenerated = Self.closeInterruptedRun(&item.composeRegenerationRuns)
            if shortened || regenerated { try save(item) }
            if item.state == .triaging || item.state == .drafting {
                item.state = .needsReview; item.error = "interrupted"
                if !item.runs.isEmpty { item.runs[item.runs.count - 1].error = "interrupted" }
            } else if item.manualExecutable != nil && item.isPreparing {
                item.state = .cancelled; item.error = "cancelled"
            } else if item.manualExecutable == nil && item.hasDraftCandidate {
                // Finish pending choices from versions that kept regenerated drafts as candidates.
                item.editedBody = nil
                item.reviewedDraftVersion = item.draftVersion
            } else { continue }
            try save(item)
        }
    }
    private static func closeInterruptedRun(_ runs: inout [PipelineRun]?) -> Bool {
        guard let last = runs?.indices.last, runs?[last].finishedAt == nil else { return false }
        runs?[last].error = "interrupted"
        runs?[last].finishedAt = Date()
        return true
    }
    deinit { sqlite3_close(db); if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw PipelineError.storage }
    }
    private func statement(_ sql: String, _ strings: [String] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw PipelineError.storage }
        for (index, text) in strings.enumerated() {
            let result = text.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { sqlite3_finalize(stmt); throw PipelineError.storage }
        }
        return stmt
    }
    private func scalar(_ sql: String, _ strings: [String] = []) throws -> String? {
        let stmt = try statement(sql, strings); defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw PipelineError.storage }
        guard status == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }
    private func put<T: Encodable>(_ value: T, id: String, table: String) throws {
        let data = try JSONEncoder().encode(value)
        let stmt = try statement("INSERT OR REPLACE INTO \(table) (id,payload) VALUES (?,?)", [id])
        defer { sqlite3_finalize(stmt) }
        let bound = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bound == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw PipelineError.storage }
    }
    private func values<T: Decodable>(_ type: T.Type, table: String, id: String? = nil) throws -> [T] {
        let stmt = try statement("SELECT payload FROM \(table)" + (id == nil ? "" : " WHERE id=?"), id.map { [$0] } ?? [])
        defer { sqlite3_finalize(stmt) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw PipelineError.storage }
            result.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))))
        }
    }
    public func settings() throws -> PipelineSettings {
        var settings = try values(PipelineSettings.self, table: "metadata", id: "settings").first ?? PipelineSettings()
        if settings.suggestionsOnly == true {
            settings.permission = nil; settings.scope = nil; settings.scopes = nil
        }
        settings.suggestionsOnly = nil
        return settings
    }
    public func hasCurrentMailReadAuthorization(_ expected: PipelineSettings) throws -> Bool {
        let current = try settings()
        return current.revision == expected.revision && current.paused == expected.paused &&
            current.permission == expected.permission && current.authorizedScopes == expected.authorizedScopes
    }
    public func saveSettings(_ value: PipelineSettings) throws { try put(value, id: "settings", table: "metadata") }
    public func saveReplyInstructions(_ value: String) throws {
        var current = try settings()
        current.replyInstructions = try ReplyDraftRequest.normalizedReplyInstructions(value)
        try saveSettings(current)
    }
    public func onboarding() throws -> OnboardingDraft {
        var draft = try values(OnboardingDraft.self, table: "metadata", id: "onboarding").first ?? OnboardingDraft()
        draft.step = min(draft.step, 5)
        if draft.suggestionsOnly == true {
            draft.extensionAcknowledged = false
            if !draft.completed { draft.step = min(draft.step, 3) }
        }
        draft.suggestionsOnly = nil
        return draft
    }
    public func saveOnboarding(_ draft: OnboardingDraft) throws { try put(draft, id: "onboarding", table: "metadata") }
    public func activateOnboarding(_ draft: OnboardingDraft) throws {
        guard draft.suggestionsOnly != true, draft.extensionAcknowledged else { throw MailpipeError.invalidInput }
        if draft.harnessKind == .opencode {
            guard let model = draft.requestedModel, OpenCodeDialect.validModelReference(model),
                  draft.testedOpenCodeModel == model else { throw MailpipeError.invalidInput }
        }
        try execute("BEGIN IMMEDIATE")
        do {
            var settings = try settings()
            var completed = draft; completed.completed = true
            let subject = draft.exactSubject.isEmpty ? nil : draft.exactSubject
            if let previous = settings.permission,
               previous.exactSubject == subject, settings.harnessKind == draft.harnessKind, settings.executable == draft.executable,
               settings.openCodeModel == draft.requestedModel {
                settings.permission = CapturePermission(renewing: previous)
            } else {
                settings.scope = nil; settings.scopes = nil
                settings.permission = CapturePermission(exactSubject: subject, delivery: .mailKit)
            }
            settings.openCodeModel = draft.requestedModel
            settings.harnessKind = draft.harnessKind; settings.executable = draft.executable; settings.level = draft.level
            settings.revision = UUID() // Preserve existing pause; never resume implicitly.
            try saveSettings(settings); try saveOnboarding(completed)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func records() throws -> [StoredReply] { try values(StoredReply.self, table: "records").sorted { $0.capturedAt < $1.capturedAt } }
    /// An open Mail panel only needs complete records for the original Message-ID.
    func composeCandidates(messageIDDigest: String) throws -> [StoredReply] {
        let stmt = try statement("SELECT id, json_extract(CAST(payload AS TEXT), '$.messageID') FROM records")
        defer { sqlite3_finalize(stmt) }
        var candidates: [StoredReply] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return candidates }
            guard status == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0) else { throw PipelineError.storage }
            if let messageID = sqlite3_column_text(stmt, 1),
               ComposeMessageIdentity.digest(forMessageID: String(cString: messageID)) == messageIDDigest,
               let item = try record(String(cString: id)) {
                candidates.append(item)
            }
        }
    }
    /// A restored compose window can explicitly search existing ready drafts by original subject.
    func composeDraftChoices(subjectDigest: String, settings: PipelineSettings, now: Date) throws -> [ComposeDraftChoice] {
        guard let permission = settings.permission else { return [] }
        let stmt = try statement("""
            SELECT id, json_extract(CAST(payload AS TEXT), '$.input.subject') FROM records
            WHERE json_extract(CAST(payload AS TEXT), '$.state') = ?
              AND json_extract(CAST(payload AS TEXT), '$.permissionID') = ?
              AND json_extract(CAST(payload AS TEXT), '$.discardedAt') IS NULL
            ORDER BY json_extract(CAST(payload AS TEXT), '$.capturedAt') DESC, id
            """, [ReplyState.draftReady.rawValue, permission.id.uuidString])
        defer { sqlite3_finalize(stmt) }
        var choices: [ComposeDraftChoice] = []
        while choices.count < ComposeDraftChoice.limit {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0),
                  let subject = sqlite3_column_text(stmt, 1) else { throw PipelineError.storage }
            guard ComposeMessageIdentity.digest(forSubject: String(cString: subject)) == subjectDigest,
                  let item = try record(String(cString: id)), item.isReadyForComposeSuggestion(settings: settings, now: now),
                  let sender = item.correspondents?.sender, let identity = item.composeIdentity(includingBody: true) else { continue }
            choices.append(ComposeDraftChoice(sender: sender, capturedAt: item.capturedAt, identity: identity))
        }
        return choices
    }
    func canAddComposeOriginal() throws -> Bool {
        try scalar("SELECT COUNT(*) < 1000 FROM records") == "1"
    }
    public func record(_ id: String) throws -> StoredReply? { try values(StoredReply.self, table: "records", id: id).first }
    public func save(_ item: StoredReply) throws { try put(item, id: item.id, table: "records") }
    public func saveEdits(_ id: String, subject: String, body: String) throws {
        guard var item = try record(id), subject.utf8.count <= 2_048,
              body.utf8.count <= 65_536 else { throw MailpipeError.invalidInput }
        item.reviewedDraftVersion = item.draftVersion
        item.editedSubject = subject; item.editedBody = body
        try save(item)
    }
    public func discard(_ id: String, now: Date = Date()) throws {
        guard var item = try record(id), !item.isPreparing else { throw MailpipeError.invalidInput }
        item.discardedAt = now; try save(item)
    }
    public func restoreDiscard(_ id: String, now: Date = Date()) throws {
        guard var item = try record(id), let date = item.discardedAt,
              now.timeIntervalSince(date) <= 15 else { throw MailpipeError.invalidInput }
        item.discardedAt = nil; try save(item)
    }
    public func note(_ issue: String) throws { try put(issue, id: "captureIssue", table: "metadata") }
    public func issue() throws -> String? { try values(String.self, table: "metadata", id: "captureIssue").first }
    @discardableResult public func importCapture(_ capture: InboundCapture, syntheticGrant: Bool = false) throws -> String {
        try capture.validate()
        if let existing = try scalar("SELECT record_id FROM ingests WHERE id=?", [capture.id.uuidString]) { return existing }
        let settings = try settings()
        if syntheticGrant {
            guard let raw = capture.raw, capture.subject == ReplySyntheticFixture.triage.message.subject,
                  try PlainMailBody.decode(raw) == ReplySyntheticFixture.triage.message.body else { throw PipelineError.invalidCapture }
        } else {
        guard let permission = settings.permission, permission.id == capture.permissionID,
              permission.accepts(capture.subject), capture.capturedAt >= permission.grantedAt,
              capture.capturedAt > Date().addingTimeInterval(-86_400) else { throw PipelineError.revoked }
        }
        if !syntheticGrant, settings.permission?.delivery == .mailKit {
            return try importMailKitBody(capture, settings: settings)
        }
        guard try records().count < 1_000 else { throw PipelineError.quota }
        // Header-only entries are candidates, not account identities. Merge a body result
        // only into a single matching empty candidate; never merge two full messages here.
        let candidates = try records().filter {
            $0.permissionID == capture.permissionID && $0.messageID != nil && $0.messageID == capture.messageID &&
            $0.input.subject == capture.subject && $0.state == .awaitingBody
        }
        let hasBodyResult = capture.raw != nil || capture.issue != nil
        let pending = hasBodyResult && candidates.count == 1 ? candidates[0] : nil
        let id = pending?.id ?? UUID().uuidString
        let evidence = capture.raw.flatMap(MailSourceEvidence.init)
        var body = "", bodyIssue = capture.issue
        if let raw = capture.raw {
            do { body = try PlainMailBody.decode(raw) }
            catch let rejection as MailBodyRejection {
                // MailKit can drop top-level MIME parameters. Defer extraction to the
                // full source, after source evidence and a unique authorized account match.
                if evidence == nil || ![.malformedMIME, .unsupportedCharset].contains(rejection) {
                    bodyIssue = rejection.rawValue
                }
            }
            catch { bodyIssue = "unsupportedMIME" }
        }
        var item = StoredReply(id: id, permissionID: capture.permissionID, capturedAt: capture.capturedAt,
            messageID: capture.messageID, input: MailInput(messageRef: id, subject: capture.subject, body: body),
            state: bodyIssue != nil ? .needsReview : (body.isEmpty && evidence == nil ? .awaitingBody : .awaitingAccount), error: bodyIssue)
        item.editedSubject = pending?.editedSubject
        item.editedBody = pending?.editedBody
        item.sourceDigest = capture.raw.flatMap(mailSourceDigest)
        if !body.isEmpty, let raw = capture.raw { item.displayBody = try? PlainMailBody.displayText(raw) }
        item.sourceEvidence = evidence
        item.correspondents = capture.raw.flatMap(MailCorrespondents.init)
        item.syntheticAuthorized = syntheticGrant
        if syntheticGrant {
            item.revision = settings.revision; item.level = settings.level
        }
        return try commitIngest(capture.id, recordID: id, saving: item)
    }

    private func importMailKitBody(_ capture: InboundCapture, settings: PipelineSettings) throws -> String {
        guard !settings.paused else { throw PipelineError.revoked }
        let rows = try records()
        let matching = rows.filter {
            capture.messageID?.isEmpty == false && $0.messageID == capture.messageID &&
            !$0.syntheticAuthorized && $0.manualExecutable == nil
        }
        if let first = matching.first(where: { !$0.input.body.isEmpty }) {
            return try commitIngest(capture.id, recordID: first.id, saving: nil)
        }
        let pending = matching.first { $0.mailKitBody == true && $0.permissionID == capture.permissionID &&
            $0.discardedAt == nil && $0.runs.isEmpty && [.awaitingBody, .needsReview].contains($0.state) }
        guard pending != nil || rows.count < 1_000 else { throw PipelineError.quota }
        if let pending, capture.raw == nil, capture.issue == nil {
            return try commitIngest(capture.id, recordID: pending.id, saving: nil)
        }
        let id = pending?.id ?? UUID().uuidString
        var body = "", error = capture.issue
        if let raw = capture.raw {
            do { body = try PlainMailBody.decode(raw, fromMailKit: true) }
            catch let reason as MailBodyRejection { error = reason.rawValue }
        }
        var item = StoredReply(id: id, permissionID: capture.permissionID, capturedAt: capture.capturedAt,
            messageID: capture.messageID, input: MailInput(messageRef: id, subject: capture.subject, body: body),
            state: error != nil ? .needsReview : (body.isEmpty ? .awaitingBody : .queued), error: error)
        item.editedSubject = pending?.editedSubject
        item.editedBody = pending?.editedBody
        item.mailKitBody = true
        item.level = settings.level; item.revision = settings.revision
        item.correspondents = capture.raw.flatMap(MailCorrespondents.init)
        if let raw = capture.raw, !body.isEmpty { item.displayBody = try? PlainMailBody.displayText(raw, fromMailKit: true) }
        return try commitIngest(capture.id, recordID: id, saving: item)
    }

    private func commitIngest(_ captureID: UUID, recordID id: String, saving item: StoredReply?) throws -> String {
        try execute("BEGIN IMMEDIATE")
        do {
            if let item { try save(item) }
            let stmt = try statement("INSERT INTO ingests (id,record_id) VALUES (?,?)", [captureID.uuidString, id])
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw PipelineError.storage }
            try execute("COMMIT")
            return id
        } catch { try? execute("ROLLBACK"); throw error }
    }
    /// Merge only after account + locator + content verification, never by Message-ID alone.
    public func removeDuplicate(_ item: StoredReply, keeping target: StoredReply) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let update = try statement("UPDATE ingests SET record_id=? WHERE record_id=?", [target.id, item.id])
            defer { sqlite3_finalize(update) }
            guard sqlite3_step(update) == SQLITE_DONE else { throw PipelineError.storage }
            let delete = try statement("DELETE FROM records WHERE id=?", [item.id])
            defer { sqlite3_finalize(delete) }
            guard sqlite3_step(delete) == SQLITE_DONE else { throw PipelineError.storage }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
}

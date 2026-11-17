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
    public var executable: String?
    public var level: ServiceLevel = .default
    public var suggestionsOnly: Bool?
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
    public var actualCost: Double?
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
    public var accountID: String?
    public var localID: String?
    public var scopeID: String?
    public var revision: UUID?
    public var level: ServiceLevel = .default
    public var decisionData: Data?
    public var draftData: Data?
    public var runs: [PipelineRun] = []
    public var manualExecutable: String? // Host-only, single-message confirmation; never imported from the spool.
    public var syntheticAuthorized = false
    public var canRecheckIdentity: Bool {
        state == .needsReview && runs.isEmpty && (!input.body.isEmpty ||
            (sourceEvidence != nil && ["identityUnresolved", "identityUnavailable", "identityAmbiguous"].contains(error ?? "")))
    }
    public var triageRequest: ReplyTriageRequest { ReplyTriageRequest(requestID: id + "-triage", message: input) }
    public var decision: ReplyDecision? { decisionData.flatMap { try? ReplyDecision.validated($0, for: triageRequest) } }
    public var draft: ReplyDraft? {
        guard let decision, let draftData,
              let request = try? ReplyDraftRequest(requestID: id + "-draft", triage: triageRequest, decision: decision, level: level) else { return nil }
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
        for var item in try records() where item.state == .triaging || item.state == .drafting {
            item.state = .needsReview; item.error = "interrupted"
            if !item.runs.isEmpty { item.runs[item.runs.count - 1].error = "interrupted" }
            try save(item)
        }
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
    public func settings() throws -> PipelineSettings { try values(PipelineSettings.self, table: "metadata", id: "settings").first ?? PipelineSettings() }
    public func saveSettings(_ value: PipelineSettings) throws { try put(value, id: "settings", table: "metadata") }
    public func onboarding() throws -> OnboardingDraft {
        try values(OnboardingDraft.self, table: "metadata", id: "onboarding").first ?? OnboardingDraft()
    }
    public func saveOnboarding(_ draft: OnboardingDraft) throws { try put(draft, id: "onboarding", table: "metadata") }
    public func activateOnboarding(_ draft: OnboardingDraft, scopes: [AccountScope]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            var settings = try settings()
            var completed = draft; completed.completed = true
            settings.scope = nil; settings.scopes = scopes; settings.executable = draft.executable; settings.level = draft.level
            settings.suggestionsOnly = draft.isSuggestionsOnly
            settings.permission = draft.isSuggestionsOnly ? nil : CapturePermission(exactSubject: draft.exactSubject.isEmpty ? nil : draft.exactSubject)
            settings.revision = UUID() // Preserve existing pause; never resume implicitly.
            try saveSettings(settings); try saveOnboarding(completed)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func records() throws -> [StoredReply] { try values(StoredReply.self, table: "records").sorted { $0.capturedAt < $1.capturedAt } }
    public func record(_ id: String) throws -> StoredReply? { try values(StoredReply.self, table: "records", id: id).first }
    public func save(_ item: StoredReply) throws { try put(item, id: item.id, table: "records") }
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
        guard try records().count < 1_000 else { throw PipelineError.quota }
        // Header-only entries are candidates, not account identities. Merge a body result
        // only into a single matching empty candidate; never merge two full messages here.
        let candidates = try records().filter {
            $0.permissionID == capture.permissionID && $0.messageID != nil && $0.messageID == capture.messageID &&
            $0.input.subject == capture.subject && $0.state == .awaitingBody
        }
        let hasBodyResult = capture.raw != nil || capture.issue != nil
        let id = hasBodyResult && candidates.count == 1 ? candidates[0].id : UUID().uuidString
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
        item.sourceDigest = capture.raw.flatMap(mailSourceDigest)
        item.sourceEvidence = evidence
        item.syntheticAuthorized = syntheticGrant
        try execute("BEGIN IMMEDIATE")
        do {
            try save(item)
            let stmt = try statement("INSERT INTO ingests (id,record_id) VALUES (?,?)", [capture.id.uuidString, id])
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

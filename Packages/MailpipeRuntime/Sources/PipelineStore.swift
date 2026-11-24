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
    var suggestionsOnly: Bool? // Decode the old manual-only policy without granting capture.
    public var paused = false
    public init() {}
}

public enum ReplyState: String, Codable, Sendable {
    case awaitingBody, awaitingAccount, queued, triaging, draftQueued, drafting
    case needsReply, draftReady, noReply, needsReview, cancelled
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

public struct StoredReply: Codable, Identifiable, Sendable {
    public let id: String
    public let permissionID: UUID
    public let capturedAt: Date
    public let messageID: String?
    public var input: MailInput {
        didSet { cachedDraft = Self.decodeDraft(draftData, for: input) }
    }
    public var state: ReplyState
    public var error: String?
    public var sourceDigest: String?
    public var sourceEvidence: MailSourceEvidence?
    public var displayBody: String?
    public var correspondents: MailCorrespondents?
    /// Projected MailKit addresses are only for the workbench. Compose identity uses the source fields.
    var mailKitAddresses: MailCorrespondents?
    public var displayCorrespondents: MailCorrespondents? {
        guard let mailKitAddresses else { return correspondents }
        return correspondents?.fillingMissingFields(from: mailKitAddresses) ?? mailKitAddresses
    }
    public var composeHandoff: MailComposeHandoff?
    public var accountID: String?
    public var localID: String?
    public var scopeID: String?
    public var revision: UUID?
    public var draftData: Data? {
        didSet { cachedDraft = Self.decodeDraft(draftData, for: input) }
    }
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
    public var discardedAt: Date?
    public var approvedPullRequest: String?
    public var regenerationCount: Int?

    /// Validated draft cached alongside `draftData` to avoid repeated JSON decoding on UI renders.
    private var cachedDraft: ReplyDraft?

    enum CodingKeys: String, CodingKey {
        case id, permissionID, capturedAt, messageID, input, state, error
        case sourceDigest, sourceEvidence, displayBody, correspondents, mailKitAddresses
        case composeHandoff, accountID, localID, scopeID, revision, draftData
        case runs, composeShortenRuns, composeRegenerationRuns, mailKitBody
        case manualExecutable, syntheticAuthorized, excludedFromAuthorizedInbox
        case editedSubject, editedBody, reviewedDraftVersion, discardedAt
        case approvedPullRequest, regenerationCount
    }

    public init(id: String, permissionID: UUID, capturedAt: Date, messageID: String?, input: MailInput,
                state: ReplyState, error: String? = nil) {
        self.id = id
        self.permissionID = permissionID
        self.capturedAt = capturedAt
        self.messageID = messageID
        self.input = input
        self.state = state
        self.error = error
        self.cachedDraft = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        permissionID = try c.decode(UUID.self, forKey: .permissionID)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID)
        input = try c.decode(MailInput.self, forKey: .input)
        state = try c.decode(ReplyState.self, forKey: .state)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        sourceDigest = try c.decodeIfPresent(String.self, forKey: .sourceDigest)
        sourceEvidence = try c.decodeIfPresent(MailSourceEvidence.self, forKey: .sourceEvidence)
        displayBody = try c.decodeIfPresent(String.self, forKey: .displayBody)
        correspondents = try c.decodeIfPresent(MailCorrespondents.self, forKey: .correspondents)
        mailKitAddresses = try c.decodeIfPresent(MailCorrespondents.self, forKey: .mailKitAddresses)
        composeHandoff = try c.decodeIfPresent(MailComposeHandoff.self, forKey: .composeHandoff)
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
        localID = try c.decodeIfPresent(String.self, forKey: .localID)
        scopeID = try c.decodeIfPresent(String.self, forKey: .scopeID)
        revision = try c.decodeIfPresent(UUID.self, forKey: .revision)
        draftData = try c.decodeIfPresent(Data.self, forKey: .draftData)
        runs = try c.decodeIfPresent([PipelineRun].self, forKey: .runs) ?? []
        composeShortenRuns = try c.decodeIfPresent([PipelineRun].self, forKey: .composeShortenRuns)
        composeRegenerationRuns = try c.decodeIfPresent([PipelineRun].self, forKey: .composeRegenerationRuns)
        mailKitBody = try c.decodeIfPresent(Bool.self, forKey: .mailKitBody)
        manualExecutable = try c.decodeIfPresent(String.self, forKey: .manualExecutable)
        syntheticAuthorized = try c.decodeIfPresent(Bool.self, forKey: .syntheticAuthorized) ?? false
        excludedFromAuthorizedInbox = try c.decodeIfPresent(Bool.self, forKey: .excludedFromAuthorizedInbox)
        editedSubject = try c.decodeIfPresent(String.self, forKey: .editedSubject)
        editedBody = try c.decodeIfPresent(String.self, forKey: .editedBody)
        reviewedDraftVersion = try c.decodeIfPresent(String.self, forKey: .reviewedDraftVersion)
        discardedAt = try c.decodeIfPresent(Date.self, forKey: .discardedAt)
        approvedPullRequest = try c.decodeIfPresent(String.self, forKey: .approvedPullRequest)
        regenerationCount = try c.decodeIfPresent(Int.self, forKey: .regenerationCount)
        cachedDraft = Self.decodeDraft(draftData, for: input)
    }

    private static func decodeDraft(_ data: Data?, for input: MailInput) -> ReplyDraft? {
        guard let data, let request = try? ReplyDraftRequest(message: input) else { return nil }
        return try? ReplyDraft.validated(data, for: request)
    }

    public var draft: ReplyDraft? { cachedDraft }

    public var draftVersion: String? {
        guard let draftData, cachedDraft != nil else { return nil }
        let runID = runs.last { $0.destination.taskKind == .draft && $0.finishedAt != nil && $0.error == nil }?.destination.runID ?? "legacy"
        return runID + ":" + contentDigest(draftData)
    }
    public var hasDraftCandidate: Bool {
        state == .draftReady && error == nil && editedBody != nil && (regenerationCount ?? 0) > 0 &&
        draftVersion != reviewedDraftVersion && cachedDraft?.body != editedBody && cachedDraft != nil
    }
    public var isPreparing: Bool { [.awaitingAccount, .queued, .triaging, .draftQueued, .drafting].contains(state) }
    public var displayedSubject: String { editedSubject ?? cachedDraft?.subject ?? input.subject }
    public var displayedBody: String { editedBody ?? cachedDraft?.body ?? "" }

    public func isReadyForReplyReminder(settings: PipelineSettings, now: Date) -> Bool {
        guard isReadyForComposeSuggestion(settings: settings, now: now) else { return false }
        // Both confirmed and unresolved handoffs remove that draft from the reminder.
        guard let handoff = composeHandoff else { return true }
        return runs.contains { $0.destination.taskKind == .draft && $0.error == nil && ($0.finishedAt ?? .distantPast) > handoff.startedAt }
    }
    func isReadyForComposeSuggestion(settings: PipelineSettings, now: Date) -> Bool {
        guard state == .draftReady, error == nil, isAuthorizedForCompose(settings: settings, now: now), let draft = cachedDraft else { return false }
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
            cachedDraft != nil || !input.body.isEmpty || !(editedBody ?? "").isEmpty
    }
    public var canRecheckIdentity: Bool {
        manualExecutable == nil && state == .needsReview && runs.isEmpty && (!input.body.isEmpty ||
            (sourceEvidence != nil && ["identitySourceMismatch", "identityUnresolved", "identityUnavailable", "identityAmbiguous"].contains(error ?? "")))
    }
}

public struct PipelineSnapshot: Sendable {
    public let generation: UInt64
    public let records: [StoredReply]
    public let settings: PipelineSettings
    public let issue: String?
}

/// One host writer per directory. flock prevents CLI/UI double-dispatch; SQLite handles
/// crash-atomic writes. Runs on its own actor executor so SQLite I/O and JSON decoding
/// stay off the UI main thread.
public actor PipelineStore {
    nonisolated(unsafe) private var db: OpaquePointer?
    private var lockFD: Int32 = -1
    public nonisolated let directory: URL
    public private(set) var generation: UInt64 = 0

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PipelineError.storage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw PipelineError.alreadyOpen }
        lockFD = fd
        guard sqlite3_open_v2(directory.appendingPathComponent("state.sqlite").path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            flock(fd, LOCK_UN); close(fd); lockFD = -1
            throw PipelineError.storage
        }
        try Self.execute(db, "PRAGMA journal_mode=WAL")
        try Self.execute(db, "PRAGMA synchronous=FULL")
        let version = try Self.scalar(db, "PRAGMA user_version") ?? "0"
        guard ["0", "1", "2"].contains(version) else { throw MailpipeError.unsupportedVersion }
        try Self.execute(db, """
            CREATE TABLE IF NOT EXISTS records (
                id TEXT PRIMARY KEY,
                payload BLOB NOT NULL,
                state TEXT,
                permission_id TEXT,
                message_id_digest TEXT,
                subject_digest TEXT,
                captured_at REAL,
                discarded_at REAL
            )
            """)
        try Self.execute(db, "CREATE TABLE IF NOT EXISTS ingests (id TEXT PRIMARY KEY, record_id TEXT NOT NULL)")
        try Self.execute(db, "CREATE TABLE IF NOT EXISTS metadata (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")

        if version == "1" {
            try Self.migrateV1ToV2(db)
        } else {
            try Self.createIndexes(db)
            if version == "0" { try Self.execute(db, "PRAGMA user_version=2") }
        }

        for var item in try Self.loadAllRecords(db) {
            let shortened = Self.closeInterruptedRun(&item.composeShortenRuns)
            let regenerated = Self.closeInterruptedRun(&item.composeRegenerationRuns)
            if shortened || regenerated { try Self.putRecord(db, item) }
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
            try Self.putRecord(db, item)
        }
    }

    private static func createIndexes(_ db: OpaquePointer?) throws {
        try execute(db, "CREATE INDEX IF NOT EXISTS idx_records_captured_at ON records(captured_at, id)")
        try execute(db, "CREATE INDEX IF NOT EXISTS idx_records_message_id_digest ON records(message_id_digest)")
        try execute(db, "CREATE INDEX IF NOT EXISTS idx_records_compose_choices ON records(state, permission_id, subject_digest, discarded_at, captured_at DESC)")
    }

    private static func migrateV1ToV2(_ db: OpaquePointer?) throws {
        try execute(db, "BEGIN IMMEDIATE")
        do {
            let existing = try tableColumns(db, table: "records")
            for (name, type) in [
                ("state", "TEXT"), ("permission_id", "TEXT"), ("message_id_digest", "TEXT"),
                ("subject_digest", "TEXT"), ("captured_at", "REAL"), ("discarded_at", "REAL")
            ] where !existing.contains(name) {
                try execute(db, "ALTER TABLE records ADD COLUMN \(name) \(type)")
            }
            for item in try loadAllRecords(db) {
                try putRecord(db, item)
            }
            try createIndexes(db)
            try execute(db, "PRAGMA user_version=2")
            try execute(db, "COMMIT")
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    private static func tableColumns(_ db: OpaquePointer?, table: String) throws -> Set<String> {
        let stmt = try statement(db, "PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(stmt) }
        var columns: Set<String> = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return columns }
            guard status == SQLITE_ROW, let name = sqlite3_column_text(stmt, 1) else { throw PipelineError.storage }
            columns.insert(String(cString: name))
        }
    }

    private static func closeInterruptedRun(_ runs: inout [PipelineRun]?) -> Bool {
        guard let last = runs?.indices.last, runs?[last].finishedAt == nil else { return false }
        runs?[last].error = "interrupted"
        runs?[last].finishedAt = Date()
        return true
    }

    deinit {
        sqlite3_close(db)
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw PipelineError.storage }
    }

    private static func statement(_ db: OpaquePointer?, _ sql: String, _ strings: [String] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw PipelineError.storage }
        for (index, text) in strings.enumerated() {
            let result = text.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, transient) }
            guard result == SQLITE_OK else { sqlite3_finalize(stmt); throw PipelineError.storage }
        }
        return stmt
    }

    private static func scalar(_ db: OpaquePointer?, _ sql: String, _ strings: [String] = []) throws -> String? {
        let stmt = try statement(db, sql, strings); defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw PipelineError.storage }
        guard status == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    private static func putRecord(_ db: OpaquePointer?, _ item: StoredReply) throws {
        let data = try JSONEncoder().encode(item)
        let sql = """
            INSERT OR REPLACE INTO records
                (id, payload, state, permission_id, message_id_digest, subject_digest, captured_at, discarded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        let stmt = try statement(db, sql, [item.id])
        defer { sqlite3_finalize(stmt) }
        func bindText(_ index: Int32, _ value: String?) -> Int32 {
            guard let value else { return sqlite3_bind_null(stmt, index) }
            return value.withCString { sqlite3_bind_text(stmt, index, $0, -1, transient) }
        }
        let messageDigest = item.messageID.flatMap(ComposeMessageIdentity.digest(forMessageID:))
        let subjectDigest = ComposeMessageIdentity.digest(forSubject: item.input.subject)
        let boundBlob = data.withUnsafeBytes {
            sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), transient)
        }
        let boundDiscarded: Int32 = item.discardedAt.map {
            sqlite3_bind_double(stmt, 8, $0.timeIntervalSinceReferenceDate)
        } ?? sqlite3_bind_null(stmt, 8)
        guard boundBlob == SQLITE_OK,
              bindText(3, item.state.rawValue) == SQLITE_OK,
              bindText(4, item.permissionID.uuidString) == SQLITE_OK,
              bindText(5, messageDigest) == SQLITE_OK,
              bindText(6, subjectDigest) == SQLITE_OK,
              sqlite3_bind_double(stmt, 7, item.capturedAt.timeIntervalSinceReferenceDate) == SQLITE_OK,
              boundDiscarded == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else {
            throw PipelineError.storage
        }
    }

    private static func loadAllRecords(_ db: OpaquePointer?) throws -> [StoredReply] {
        let stmt = try statement(db, "SELECT payload FROM records ORDER BY captured_at ASC, id ASC")
        defer { sqlite3_finalize(stmt) }
        let decoder = JSONDecoder()
        var result: [StoredReply] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw PipelineError.storage }
            result.append(try decoder.decode(StoredReply.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))))
        }
    }

    private func execute(_ sql: String) throws { try Self.execute(db, sql) }
    private func statement(_ sql: String, _ strings: [String] = []) throws -> OpaquePointer { try Self.statement(db, sql, strings) }
    private func scalar(_ sql: String, _ strings: [String] = []) throws -> String? { try Self.scalar(db, sql, strings) }

    private func putMetadata<T: Encodable>(_ value: T, id: String) throws {
        let data = try JSONEncoder().encode(value)
        let stmt = try statement("INSERT OR REPLACE INTO metadata (id,payload) VALUES (?,?)", [id])
        defer { sqlite3_finalize(stmt) }
        let bound = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), Self.transient) }
        guard bound == SQLITE_OK, sqlite3_step(stmt) == SQLITE_DONE else { throw PipelineError.storage }
        generation &+= 1
    }

    private func metadata<T: Decodable>(_ type: T.Type, id: String) throws -> T? {
        let stmt = try statement("SELECT payload FROM metadata WHERE id=?", [id])
        defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw PipelineError.storage }
        return try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
    }

    public func snapshot(ifChangedSince lastGeneration: UInt64?) throws -> PipelineSnapshot? {
        if let lastGeneration, lastGeneration == generation { return nil }
        return PipelineSnapshot(
            generation: generation,
            records: try records(),
            settings: try settings(),
            issue: try issue()
        )
    }

    public func settings() throws -> PipelineSettings {
        var settings = try metadata(PipelineSettings.self, id: "settings") ?? PipelineSettings()
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

    public func saveSettings(_ value: PipelineSettings) throws { try putMetadata(value, id: "settings") }

    public func saveReplyInstructions(_ value: String) throws {
        var current = try settings()
        current.replyInstructions = try ReplyDraftRequest.normalizedReplyInstructions(value)
        try saveSettings(current)
    }

    public func onboarding() throws -> OnboardingDraft {
        var draft = try metadata(OnboardingDraft.self, id: "onboarding") ?? OnboardingDraft()
        draft.step = min(draft.step, 5)
        if draft.suggestionsOnly == true {
            draft.extensionAcknowledged = false
            if !draft.completed { draft.step = min(draft.step, 3) }
        }
        draft.suggestionsOnly = nil
        return draft
    }

    public func saveOnboarding(_ draft: OnboardingDraft) throws { try putMetadata(draft, id: "onboarding") }

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
            settings.harnessKind = draft.harnessKind; settings.executable = draft.executable
            settings.revision = UUID() // Preserve existing pause; never resume implicitly.
            try saveSettings(settings); try saveOnboarding(completed)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func records() throws -> [StoredReply] {
        try Self.loadAllRecords(db)
    }

    /// Indexed lookup for an open Mail compose panel by original Message-ID digest.
    func composeCandidates(messageIDDigest: String) throws -> [StoredReply] {
        let stmt = try statement("SELECT payload FROM records WHERE message_id_digest = ?", [messageIDDigest])
        defer { sqlite3_finalize(stmt) }
        let decoder = JSONDecoder()
        var candidates: [StoredReply] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return candidates }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw PipelineError.storage }
            candidates.append(try decoder.decode(StoredReply.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))))
        }
    }

    /// Indexed lookup for restored compose windows searching ready drafts by original subject.
    func composeDraftChoices(subjectDigest: String, settings: PipelineSettings, now: Date) throws -> [ComposeDraftChoice] {
        guard let permission = settings.permission else { return [] }
        let stmt = try statement("""
            SELECT payload FROM records
            WHERE state = ? AND permission_id = ? AND subject_digest = ? AND discarded_at IS NULL
            ORDER BY captured_at DESC, id
            """, [ReplyState.draftReady.rawValue, permission.id.uuidString, subjectDigest])
        defer { sqlite3_finalize(stmt) }
        let decoder = JSONDecoder()
        var choices: [ComposeDraftChoice] = []
        while choices.count < ComposeDraftChoice.limit {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw PipelineError.storage }
            let item = try decoder.decode(StoredReply.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
            guard item.isReadyForComposeSuggestion(settings: settings, now: now),
                  let sender = item.correspondents?.sender, let identity = item.composeIdentity(includingBody: true) else { continue }
            choices.append(ComposeDraftChoice(sender: sender, capturedAt: item.capturedAt, identity: identity))
        }
        return choices
    }

    func canAddComposeOriginal() throws -> Bool {
        try scalar("SELECT COUNT(*) < 1000 FROM records") == "1"
    }

    public func record(_ id: String) throws -> StoredReply? {
        let stmt = try statement("SELECT payload FROM records WHERE id=?", [id])
        defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw PipelineError.storage }
        return try JSONDecoder().decode(StoredReply.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
    }

    public func save(_ item: StoredReply) throws {
        try Self.putRecord(db, item)
        generation &+= 1
    }

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

    public func note(_ issue: String) throws { try putMetadata(issue, id: "captureIssue") }
    public func issue() throws -> String? { try metadata(String.self, id: "captureIssue") }

    @discardableResult public func importCapture(_ capture: InboundCapture, syntheticGrant: Bool = false) throws -> String {
        try capture.validate()
        if let existing = try scalar("SELECT record_id FROM ingests WHERE id=?", [capture.id.uuidString]) { return existing }
        let settings = try settings()
        if syntheticGrant {
            guard let raw = capture.raw, capture.subject == ReplySyntheticFixture.message.subject,
                  try PlainMailBody.decode(raw) == ReplySyntheticFixture.message.body else { throw PipelineError.invalidCapture }
        } else {
            guard let permission = settings.permission, permission.id == capture.permissionID,
                  permission.accepts(capture.subject), capture.capturedAt >= permission.grantedAt,
                  capture.capturedAt > Date().addingTimeInterval(-86_400) else { throw PipelineError.revoked }
        }
        if !syntheticGrant, settings.permission?.delivery == .mailKit {
            return try importMailKitBody(capture, settings: settings)
        }
        guard try canAddComposeOriginal() else { throw PipelineError.quota }
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
            item.revision = settings.revision
        }
        return try commitIngest(capture.id, recordID: id, saving: item)
    }

    private func importMailKitBody(_ capture: InboundCapture, settings: PipelineSettings) throws -> String {
        guard !settings.paused else { throw PipelineError.revoked }
        let matching: [StoredReply]
        if let messageID = capture.messageID, !messageID.isEmpty,
           let digest = ComposeMessageIdentity.digest(forMessageID: messageID) {
            matching = try composeCandidates(messageIDDigest: digest).filter {
                $0.messageID == messageID && !$0.syntheticAuthorized && $0.manualExecutable == nil
            }
        } else {
            matching = []
        }
        let pending = matching.first { $0.mailKitBody == true && $0.permissionID == capture.permissionID &&
            $0.discardedAt == nil && $0.runs.isEmpty && [.awaitingBody, .needsReview].contains($0.state) }
        let completed = matching.first { !$0.input.body.isEmpty }
        let previous = completed ?? pending
        let sameMessage = matching.count == 1 && previous?.mailKitBody == true && previous?.discardedAt == nil &&
            previous?.permissionID == capture.permissionID && previous?.input.subject == capture.subject
        var addresses = capture.mailKitAddresses
        if sameMessage, let earlier = previous?.mailKitAddresses {
            addresses = addresses.map { earlier.fillingMissingFields(from: $0) } ?? earlier
        }
        if var existing = previous, completed != nil || (capture.raw == nil && capture.issue == nil) {
            // Callbacks may arrive in either order. A duplicate can only fill missing display fields.
            guard sameMessage, addresses != existing.mailKitAddresses else {
                return try commitIngest(capture.id, recordID: existing.id, saving: nil)
            }
            existing.mailKitAddresses = addresses
            return try commitIngest(capture.id, recordID: existing.id, saving: existing)
        }
        guard try pending != nil || canAddComposeOriginal() else { throw PipelineError.quota }
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
        item.revision = settings.revision
        item.correspondents = capture.raw.flatMap(MailCorrespondents.init)
        item.mailKitAddresses = pending == nil || sameMessage ? addresses : nil
        if let raw = capture.raw, !body.isEmpty { item.displayBody = try? PlainMailBody.displayText(raw, fromMailKit: true) }
        return try commitIngest(capture.id, recordID: id, saving: item)
    }

    private func commitIngest(_ captureID: UUID, recordID id: String, saving item: StoredReply?) throws -> String {
        try execute("BEGIN IMMEDIATE")
        do {
            if let item { try Self.putRecord(db, item) }
            let stmt = try statement("INSERT INTO ingests (id,record_id) VALUES (?,?)", [captureID.uuidString, id])
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw PipelineError.storage }
            try execute("COMMIT")
            generation &+= 1
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
            generation &+= 1
        } catch { try? execute("ROLLBACK"); throw error }
    }
}

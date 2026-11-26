import Foundation
import MailpipeCore
import HarnessAdapters

public struct VerifiedMail: Sendable {
    public let accountID: String
    public let localID: String
    public let source: Data?
    public init(accountID: String, localID: String, source: Data? = nil) {
        self.accountID = accountID; self.localID = localID; self.source = source
    }
}

public typealias MailIdentityResolver = @Sendable (StoredReply, AccountScope) async throws -> VerifiedMail?

public typealias MailMailboxClassifier = @Sendable ([MailMessageLookup]) async throws -> [MailMailboxDisposition]

public typealias ReplyModelFactory = @Sendable (HarnessInstallation) throws -> any ReplyModelRunning

public func makeReplyModel(for installation: HarnessInstallation) throws -> any ReplyModelRunning {
    switch installation.kind {
    case .deepseek: return DeepSeekHarnessAdapter(executable: installation.executable, dialect: DeepSeekHarnessDialect())
    case .claude: return ClaudeCodeHarnessAdapter(executable: installation.executable, dialect: ClaudeCodeDialect())
    case .opencode: return OpenCodeHarnessAdapter(executable: installation.executable, dialect: OpenCodeDialect(model: installation.openCodeModel))
    case .openclaw: return OpenClawHarnessAdapter(executable: installation.executable, dialect: OpenClawDialect())
    case .hermes: return HermesHarnessAdapter(executable: installation.executable, dialect: HermesDialect())
    case .codex: return CodexCLIAdapter(executable: installation.executable, dialect: CodexCLIDialect())
    }
}

public actor ReplyPipeline {
    public nonisolated let store: PipelineStore
    public nonisolated let inbox: CaptureInbox
    private let composeInboxes: @Sendable () async throws -> [AccountScope]
    private let resolve: MailIdentityResolver
    private let classifyMailboxes: MailMailboxClassifier
    private let mailboxAuditInterval: TimeInterval
    private var lastMailboxAuditAt: Date?
    private var mailboxAuditDenied = false
    let model: ReplyModelFactory
    public private(set) var pumping = false
    var activeComposeGenerations: Set<String> = []
    var activeComposeRegenerations: Set<String> = []

    public init(store: PipelineStore, inbox: CaptureInbox, resolve: @escaping MailIdentityResolver,
                composeInboxes: @escaping @Sendable () async throws -> [AccountScope] = { [] },
                classifyMailboxes: @escaping MailMailboxClassifier = { Array(repeating: .unknown, count: $0.count) },
                mailboxAuditInterval: TimeInterval = 60,
                model: @escaping ReplyModelFactory = makeReplyModel) {
        self.composeInboxes = composeInboxes
        self.classifyMailboxes = classifyMailboxes
        self.mailboxAuditInterval = mailboxAuditInterval
        self.store = store; self.inbox = inbox; self.resolve = resolve; self.model = model
    }

    private func mailReadStillAuthorized(_ settings: PipelineSettings) async throws -> Bool {
        try Task.checkCancellation()
        return try await store.hasCurrentMailReadAuthorization(settings)
    }

    /// Read-only enrichment for older rows, using the same source/account proof as dispatch.
    /// No state transition, body replacement, model call or email mutation.
    public func loadCorrespondents(_ id: String, includeBody: Bool = false) async throws {
        try Task.checkCancellation()
        guard let item = try await store.record(id), item.mailKitBody != true, (item.correspondents == nil || (includeBody && item.displayBody == nil)), item.discardedAt == nil,
              !item.syntheticAuthorized, item.manualExecutable == nil,
              item.excludedFromAuthorizedInbox != true else { return }
        let settings = try await store.settings()
        if includeBody && (settings.paused || item.capturedAt < Date().addingTimeInterval(-7 * 86_400)) { return }
        guard settings.permission?.id == item.permissionID else { return }
        let scopes = settings.authorizedScopes.filter { item.accountID == nil || $0.accountID == item.accountID }
        var matches: [VerifiedMail] = []
        for scope in scopes {
            let result = try await resolve(item, scope)
            guard try await mailReadStillAuthorized(settings) else { return }
            guard let verified = result, verified.accountID == scope.accountID,
                  item.localID == nil || verified.localID == item.localID,
                  let source = verified.source else { continue }
            let valid = item.sourceEvidence?.matches(source)
                ?? (item.sourceDigest != nil && mailSourceDigest(source) == item.sourceDigest)
            if valid { matches.append(verified) }
        }
        guard matches.count == 1, let source = matches.first?.source,
              var current = try await store.record(id),
              current.discardedAt == nil, current.excludedFromAuthorizedInbox != true,
              current.localID == item.localID, current.accountID == item.accountID,
              current.sourceEvidence == item.sourceEvidence, current.sourceDigest == item.sourceDigest else { return }
        current.correspondents = MailCorrespondents(source)
        if includeBody, current.displayBody == nil { current.displayBody = try? PlainMailBody.displayText(source) }
        try await store.save(current)
    }

    func resolveComposeOriginal(_ item: StoredReply, settings: PipelineSettings) async throws -> (AccountScope, VerifiedMail, Data) {
        let scopes = item.mailKitBody == true ? try await composeInboxes() : settings.authorizedScopes.filter {
            item.accountID == nil || $0.accountID == item.accountID
        }
        guard try await mailReadStillAuthorized(settings) else { throw MailComposeError.unavailable }
        var matches: [(AccountScope, VerifiedMail)] = []
        for scope in scopes {
            try Task.checkCancellation()
            let result = try await resolve(item, scope)
            guard try await mailReadStillAuthorized(settings) else { throw MailComposeError.unavailable }
            guard let verified = result, verified.accountID == scope.accountID,
                  item.localID == nil || verified.localID == item.localID, let source = verified.source else { continue }
            if item.mailKitBody == true {
                matches.append((scope, verified))
                break
            }
            guard item.sourceEvidence?.matches(source) ?? (item.sourceDigest != nil && item.sourceDigest == mailSourceDigest(source))
            else { continue }
            matches.append((scope, verified))
        }
        guard matches.count == 1, let (scope, match) = matches.first, let source = match.source,
              try await store.settings().revision == settings.revision else { throw MailComposeError.unavailable }
        return (scope, match, source)
    }

    public func prepareMailCompose(id: String, subject: String, body: String,
        senderAddress: @Sendable (String, [String]) async throws -> String) async throws -> MailComposeRequest {
        guard let item = try await store.record(id), item.excludedFromAuthorizedInbox != true,
              item.manualExecutable == nil, !item.syntheticAuthorized, item.discardedAt == nil,
              !item.isPreparing, item.state != .cancelled, !item.input.body.isEmpty,
              item.displayedSubject == subject, item.displayedBody == body,
              item.capturedAt > Date().addingTimeInterval(-7 * 86_400),
              let messageID = item.messageID else { throw MailComposeError.unavailable }
        let settings = try await store.settings()
        guard !settings.paused, settings.permission?.id == item.permissionID else { throw MailComposeError.unavailable }
        let (scope, match, source) = try await resolveComposeOriginal(item, settings: settings)
        let latestSettings = try await store.settings()
        guard !latestSettings.paused, latestSettings.permission?.id == item.permissionID,
              let latest = try await store.record(id), latest.discardedAt == nil, !latest.isPreparing, latest.state != .cancelled,
              latest.excludedFromAuthorizedInbox != true, latest.displayedSubject == subject,
              latest.displayedBody == body, latest.capturedAt > Date().addingTimeInterval(-7 * 86_400)
        else { throw MailComposeError.changedSinceConfirmation }
        let recipients = try MailReplyRecipients.parse(source)
        let addresses = MailCorrespondents(source)
        let sender = try await senderAddress(scope.accountID, (addresses?.recipients ?? []) + (addresses?.cc ?? []))
        return try MailComposeRequest(recordID: id, accountID: scope.accountID, accountName: scope.accountName,
            sender: sender, recipients: recipients, subject: subject, body: body,
            originalSubject: item.input.subject, messageID: messageID, localID: match.localID,
            sourceDigest: contentDigest(source), settingsRevision: settings.revision)
    }

    public func openMailCompose(confirmedRequest: MailComposeRequest,
        senderAddress: @Sendable (String, [String]) async throws -> String,
        open: @Sendable (MailComposeRequest) async throws -> MailComposeReceipt) async throws -> MailComposeReceipt {
        let fresh = try await prepareMailCompose(id: confirmedRequest.recordID, subject: confirmedRequest.subject,
            body: confirmedRequest.body, senderAddress: senderAddress)
        guard fresh == confirmedRequest else { throw MailComposeError.changedSinceConfirmation }
        return try await executeMailCompose(fresh, open: open)
    }

    /// Single-pass compose handoff for direct user click in the workbench (avoids resolving twice).
    public func composeReply(id: String, subject: String, body: String,
        senderAddress: @Sendable (String, [String]) async throws -> String,
        open: @Sendable (MailComposeRequest) async throws -> MailComposeReceipt) async throws -> MailComposeReceipt {
        let request = try await prepareMailCompose(id: id, subject: subject, body: body, senderAddress: senderAddress)
        return try await executeMailCompose(request, open: open)
    }

    private func executeMailCompose(_ fresh: MailComposeRequest,
        open: @Sendable (MailComposeRequest) async throws -> MailComposeReceipt) async throws -> MailComposeReceipt {
        let finalSettings = try await store.settings()
        guard !finalSettings.paused, finalSettings.revision == fresh.settingsRevision,
              var current = try await store.record(fresh.recordID), current.permissionID == finalSettings.permission?.id,
              current.discardedAt == nil, current.state != .cancelled, !current.isPreparing,
              current.excludedFromAuthorizedInbox != true,
              current.displayedSubject == fresh.subject, current.displayedBody == fresh.body else {
            throw MailComposeError.changedSinceConfirmation
        }
        // Each explicit click is a new compose request. Never replay one on startup.
        let attempt = MailComposeHandoff(fingerprint: fresh.fingerprint)
        current.composeHandoff = attempt
        try await store.save(current)
        let receipt: MailComposeReceipt
        do { receipt = try await open(fresh) }
        catch { throw MailComposeError.outcomeUnknown }
        guard !receipt.outgoingID.isEmpty, var latest = try await store.record(fresh.recordID),
              latest.composeHandoff?.fingerprint == fresh.fingerprint,
              latest.composeHandoff?.startedAt == attempt.startedAt else { throw MailComposeError.outcomeUnknown }
        latest.composeHandoff?.receipt = receipt
        try await store.save(latest)
        return receipt
    }

    public func updateSettings(_ change: @Sendable (inout PipelineSettings) -> Void) async throws {
        let previous = try await store.settings()
        var settings = previous; change(&settings)
        let changedTool = settings.harnessKind != previous.harnessKind || settings.executable != previous.executable ||
            settings.openCodeModel != previous.openCodeModel
        if changedTool, previous.executable != nil, let oldGrant = previous.permission, oldGrant.id == settings.permission?.id {
            throw PipelineError.revoked
        }
        if settings.permission != previous.permission || settings.authorizedScopes != previous.authorizedScopes ||
            changedTool { settings.revision = UUID() }
        // DB is authoritative. A crash before the extension snapshot changes cannot grant a model call.
        try await store.saveSettings(settings)
        try inbox.setPermission(settings.paused ? nil : settings.permission)
    }

    public func importInbox() async throws {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        _ = try await importCaptures()
    }

    private func importCaptures() async throws -> Bool {
        try Task.checkCancellation()
        try inbox.pruneClaims()
        if let issue = try inbox.issue() { try await store.note(issue) }
        let files = try inbox.files().sorted {
            let a = (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? .distantPast
            let b = (try? FileManager.default.attributesOfItem(atPath: $1.path)[.modificationDate] as? Date) ?? .distantPast
            return a < b
        }
        var imported = false
        for file in files {
            try Task.checkCancellation()
            let capture: InboundCapture
            do {
                capture = try JSONDecoder().decode(InboundCapture.self, from: CaptureInbox.read(file, limit: MailBodyLimits.captureFileCeiling))
                try capture.validate()
            } catch {
                try await store.note("invalidCapture")
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory != true || values.isSymbolicLink == true { try FileManager.default.removeItem(at: file) }
                continue
            }
            let currentSettings = try await store.settings()
            if currentSettings.permission?.delivery == .mailKit && currentSettings.paused { return imported }
            do {
                _ = try await store.importCapture(capture)
                imported = true
            }
            catch PipelineError.quota { try await store.note("quota"); break }
            catch PipelineError.revoked {
                try await store.note("captureExpiredOrRevoked")
                try FileManager.default.removeItem(at: file); continue
            }
            // A database or decoding failure is not invalid input: retain the spool for recovery.
            try FileManager.default.removeItem(at: file)
        }
        return imported
    }

    public func recheckIdentity(_ id: String) async throws {
        guard var item = try await store.record(id), item.canRecheckIdentity, item.permissionID == (try await store.settings()).permission?.id else { throw MailpipeError.invalidInput }
        item.accountID = nil; item.localID = nil; item.revision = nil
        item.state = .awaitingAccount; item.error = nil; try await store.save(item)
    }

    /// User-confirmed retry only. Reverify captured mail and preserve local edits.
    public func regenerate(_ id: String, approvedPullRequest: String? = nil) async throws {
        let settings = try await store.settings()
        guard var item = try await store.record(id), !settings.paused, !item.isPreparing,
              item.discardedAt == nil, !item.isRegeneratingInCompose, !item.runs.contains(where: { $0.finishedAt == nil }),
              !item.regenerationLimitReached,
              item.capturedAt > Date().addingTimeInterval(-7 * 86_400),
              settings.executable != nil else { throw MailpipeError.invalidInput }
        guard item.manualExecutable == nil else { throw PipelineError.revoked }
        guard approvedPullRequest == nil || settings.harnessKind == .deepseek else { throw MailpipeError.unsafeCapability }
        if item.mailKitBody == true {
            guard item.canRequestRegeneration(settings: settings) else { throw PipelineError.revoked }
            item.state = .queued; item.revision = settings.revision
        } else if item.syntheticAuthorized {
            item.state = .queued; item.revision = settings.revision
        } else {
            guard settings.permission?.id == item.permissionID,
                  settings.authorizedScopes.contains(where: { $0.id == item.scopeID ||
                      (item.scopeID == nil && $0.accountID == item.accountID) }) else { throw PipelineError.revoked }
            item.accountID = nil; item.localID = nil; item.revision = nil
            item.state = .awaitingAccount
        }
        item.approvedPullRequest = approvedPullRequest
        item.regenerationCount = (item.regenerationCount ?? 0) + 1
        item.error = nil
        try await store.save(item)
    }

    public func cancel(_ id: String) async throws {
        guard var item = try await store.record(id) else { return }
        item.state = .cancelled; item.error = "cancelled"; try await store.save(item)
    }

    /// Process bounded batches; each pump is serial. No automatic retry of failed/unknown calls.
    public func pump(mailboxAuditMinInterval: TimeInterval? = nil, now: Date = Date()) async throws {
        guard !pumping else { return }
        pumping = true; defer { pumping = false }
        let imported = try await importCaptures()
        let initialRecords = try await store.records()
        let hasQueued = initialRecords.contains {
            $0.discardedAt == nil && $0.excludedFromAuthorizedInbox != true &&
            !$0.syntheticAuthorized && $0.manualExecutable == nil &&
            [.awaitingAccount, .queued, .draftQueued].contains($0.state)
        }
        let minInterval = (imported || hasQueued) ? 0 : (mailboxAuditMinInterval ?? mailboxAuditInterval)
        try await auditJunkOrTrash(minInterval: minInterval, now: now)
        for item in try await store.records().prefix(1_000) {
            try Task.checkCancellation()
            let settings = try await store.settings()
            guard !settings.paused else { return }
            if item.excludedFromAuthorizedInbox == true { continue }
            if [.awaitingAccount, .queued, .draftQueued].contains(item.state) { try await process(item.id) }
        }
    }

    private func auditJunkOrTrash(minInterval: TimeInterval, now: Date) async throws {
        try Task.checkCancellation()
        guard !mailboxAuditDenied else { return }
        let settings = try await store.settings()
        guard !settings.paused, settings.permission != nil else { return }
        if minInterval > 0, let last = lastMailboxAuditAt, now.timeIntervalSince(last) < minInterval {
            return
        }
        let records = try await store.records()
        let candidates = records.filter { item in
            item.discardedAt == nil &&
            item.excludedFromAuthorizedInbox != true &&
            !item.syntheticAuthorized &&
            item.manualExecutable == nil &&
            item.state != .triaging && item.state != .drafting &&
            !item.isRegeneratingInCompose &&
            !item.runs.contains(where: { $0.finishedAt == nil }) &&
            item.messageID?.isEmpty == false &&
            (item.canDisplayInWorkbench || [.awaitingBody, .awaitingAccount, .queued, .draftQueued].contains(item.state))
        }
        guard !candidates.isEmpty else {
            lastMailboxAuditAt = now
            return
        }
        let batch = Array(candidates.suffix(100))
        let lookups = batch.map { MailMessageLookup(messageID: $0.messageID!, subject: $0.input.subject) }
        let dispositions: [MailMailboxDisposition]
        do {
            dispositions = try await classifyMailboxes(lookups)
        } catch is CancellationError {
            throw CancellationError()
        } catch MailMailboxAuditError.automationDenied {
            // Stop asking for this session after user denial; fail open so drafting continues.
            mailboxAuditDenied = true
            lastMailboxAuditAt = now
            return
        } catch {
            lastMailboxAuditAt = now
            return
        }
        guard dispositions.count == batch.count else {
            lastMailboxAuditAt = now
            return
        }
        guard try await mailReadStillAuthorized(settings) else { return }
        lastMailboxAuditAt = now
        for (candidate, disposition) in zip(batch, dispositions) where disposition == .junkOrTrash {
            guard var current = try await store.record(candidate.id),
                  current.discardedAt == nil,
                  current.excludedFromAuthorizedInbox != true,
                  current.state != .triaging, current.state != .drafting,
                  !current.isRegeneratingInCompose,
                  !current.runs.contains(where: { $0.finishedAt == nil }) else { continue }
            current.excludedFromAuthorizedInbox = true
            if [.awaitingBody, .awaitingAccount, .queued, .draftQueued].contains(current.state) {
                current.state = .cancelled
                current.error = "junkOrTrash"
            }
            try await store.save(current)
        }
    }

    private func process(_ id: String) async throws {
        try Task.checkCancellation()
        guard var item = try await store.record(id), [.awaitingAccount, .queued, .draftQueued].contains(item.state),
              item.discardedAt == nil, item.excludedFromAuthorizedInbox != true else { return }
        guard item.manualExecutable == nil else { try await cancel(id); return }
        let settings = try await store.settings()
        guard let executable = settings.executable, executable.hasPrefix("/"), !settings.paused else { return }
        guard item.capturedAt > Date().addingTimeInterval(-7 * 86_400) else {
            item.state = .needsReview; item.error = "contentExpired"; try await store.save(item); return
        }
        if item.mailKitBody == true {
            guard settings.permission?.id == item.permissionID, settings.permission?.delivery == .mailKit,
                  !item.input.body.isEmpty else {
                item.state = .cancelled; item.error = "revoked"; try await store.save(item); return
            }
        } else if !item.syntheticAuthorized {
            guard settings.permission?.id == item.permissionID else {
                item.state = .cancelled; item.error = "revoked"; try await store.save(item); return
            }
            let scopes = settings.authorizedScopes
            guard !scopes.isEmpty else { return }
            if item.accountID == nil {
                func currentCandidate(_ expected: StoredReply) async throws -> StoredReply? {
                    guard try await mailReadStillAuthorized(settings),
                          let current = try await store.record(id), current.state == expected.state, current.accountID == nil,
                          current.discardedAt == nil, current.excludedFromAuthorizedInbox != true,
                          current.sourceDigest == expected.sourceDigest, current.sourceEvidence == expected.sourceEvidence,
                          current.capturedAt > Date().addingTimeInterval(-7 * 86_400) else { return nil }
                    return current
                }
                do {
                    var matches: [(AccountScope, VerifiedMail)] = []
                    var sourceMismatch = false
                    for scope in scopes {
                        let result = try await resolve(item, scope)
                        guard let current = try await currentCandidate(item) else { return }
                        item = current
                        guard let verified = result, verified.accountID == scope.accountID else { continue }
                        if let evidence = item.sourceEvidence,
                           verified.source.map(evidence.matches) != true {
                            sourceMismatch = true
                            continue
                        }
                        matches.append((scope, verified))
                    }
                    guard matches.count == 1, let (scope, verified) = matches.first else {
                        item.error = matches.isEmpty ? (sourceMismatch ? "identitySourceMismatch" : "identityUnresolved") : "identityAmbiguous"
                        item.state = .needsReview; try await store.save(item); return
                    }
                    if item.sourceEvidence != nil, let source = verified.source {
                        item.displayBody = try? PlainMailBody.displayText(source)
                        item.input = MailInput(messageRef: item.id, subject: item.input.subject, body: try PlainMailBody.decode(source))
                    }
                    if let source = verified.source { item.correspondents = MailCorrespondents(source) }
                    item.accountID = verified.accountID; item.localID = verified.localID; item.scopeID = scope.id
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard var current = try await currentCandidate(item) else { return }
                    current.error = (error as? MailBodyRejection)?.rawValue ?? "identityUnavailable"
                    current.state = .needsReview
                    try await store.save(current)
                    return
                }
                if let duplicate = try await store.records().first(where: {
                    $0.id != item.id && $0.accountID == item.accountID && $0.localID == item.localID &&
                    $0.input.subject == item.input.subject && $0.input.body == item.input.body
                }) {
                    try await store.removeDuplicate(item, keeping: duplicate); return
                }
                item.revision = settings.revision; item.state = .queued
                try await store.save(item)
            }
        } else {
            // Only enqueueSynthetic can set this host-owned field. The spool cannot grant it.
            guard item.input.subject == ReplySyntheticFixture.message.subject,
                  item.input.body == ReplySyntheticFixture.message.body else { throw PipelineError.invalidCapture }
            item.accountID = "synthetic-validation"; item.localID = "synthetic-" + item.id
            // Before harness selection existed, a pending fixture was authorized only for DSH.
            if item.revision == nil && settings.harnessKind == .deepseek {
                item.revision = settings.revision
            }
            item.state = .queued
            try await store.save(item)
        }
        guard item.revision == settings.revision else {
            item.state = .needsReview; item.error = "policyChanged"; try await store.save(item); return
        }
        let allowsNoReply = !item.syntheticAuthorized && item.runs.isEmpty &&
            (item.regenerationCount ?? 0) == 0 && item.editedBody == nil
        // A connection test is authorized for the fixed example alone.
        let instructions = item.syntheticAuthorized ? nil : try await store.settings().replyInstructions
        let externalContext: DraftExternalContext? = {
            guard settings.harnessKind == .deepseek,
                  let target = GitHubPullRequestLink.first(in: item.input.body) else { return nil }
            return .gitHubPullRequest(url: target, authenticated: item.approvedPullRequest == target)
        }()
        let request = try ReplyDraftRequest(message: item.input, allowsNoReply: allowsNoReply,
                                            replyInstructions: instructions, externalContext: externalContext)
        if settings.harnessKind == .opencode && !item.syntheticAuthorized {
            guard let model = settings.openCodeModel, OpenCodeDialect.validModelReference(model) else {
                item.state = .needsReview; item.error = MailpipeError.routeNotAllowed.rawValue; try await store.save(item); return
            }
        }
        let installation = HarnessInstallation(kind: settings.harnessKind, executable: URL(fileURLWithPath: executable),
                                               openCodeModel: settings.openCodeModel)
        try await generateDraft(for: item, request: request, installation: installation)
    }

    private func authorize(_ id: String, revision: UUID) async throws {
        try Task.checkCancellation()
        let settings = try await store.settings()
        guard !settings.paused else { throw MailpipeError.paused }
        guard settings.revision == revision, let item = try await store.record(id), item.manualExecutable == nil,
              item.state == .triaging || item.state == .drafting,
              (item.mailKitBody == true && settings.permission?.delivery == .mailKit && settings.permission?.id == item.permissionID) || item.syntheticAuthorized || (settings.permission?.id == item.permissionID && settings.authorizedScopes.contains { $0.accountID == item.accountID && (item.scopeID == nil || $0.id == item.scopeID) }) else { throw PipelineError.revoked }
    }

    func generateDraft(for original: StoredReply, request: ReplyDraftRequest, installation: HarnessInstallation,
                       runID: String = UUID().uuidString,
                       confirmStart: @Sendable () async throws -> Void = {},
                       checkPanel: @escaping @Sendable () async throws -> Void = {}) async throws {
        var item = original
        let id = item.id
        guard let revision = item.revision else { throw PipelineError.storage }
        item.state = .drafting
        let destination = try DataDestination(messageRef: id, runID: runID, taskKind: .draft, harness: installation.kind)
        item.runs.append(PipelineRun(destination: destination, startedAt: Date()))
        try await confirmStart()
        try await store.save(item)
        do {
            let route = item.mailKitBody == true ? AccountRoute(mailKitPermission: item.permissionID, allowedHarnesses: [installation.kind])
                : AccountRoute(accountID: item.accountID, allowedHarnesses: [installation.kind])
            let output = try await model(installation).run(.draft(request), route: route) { [self] in
                try await self.authorize(id, revision: revision)
                try await checkPanel()
            }
            guard var current = try await store.record(id) else { throw PipelineError.storage }
            let last = current.runs.count - 1
            try current.runs[last].record(output, installation: installation)
            try await store.save(current)
            try await authorize(id, revision: revision)
            try await checkPanel()
            switch try ReplyDraftOutcome.validated(output.content, for: request) {
            case .noReply:
                current.state = .noReply
            case .draft:
                current.draftData = output.content
                current.state = .draftReady
                if (current.regenerationCount ?? 0) > 0 {
                    current.editedBody = nil
                    current.reviewedDraftVersion = current.draftVersion
                }
            }
            try await store.save(current)
        } catch {
            guard var current = try await store.record(id) else { throw PipelineError.storage }
            let code = (error as? MailpipeError)?.rawValue ?? (error as? PipelineError)?.rawValue ?? (error is CancellationError ? "cancelled" : "operationFailed")
            if current.state != .cancelled { current.state = .needsReview }
            current.error = code
            if !current.runs.isEmpty {
                current.runs[current.runs.count - 1].error = code
                current.runs[current.runs.count - 1].finishedAt = Date()
            }
            try await store.save(current)
        }
    }

    /// Explicit user action authorizes only this fixed synthetic input and the selected harness.
    /// Uses the same store importer, durable states, and model path without creating throwaway spool files.
    @discardableResult public func enqueueSynthetic() async throws -> String {
        let settings = try await store.settings()
        guard !settings.paused, settings.executable != nil else { throw MailpipeError.paused }
        let input = ReplySyntheticFixture.message
        let permission = CapturePermission(exactSubject: input.subject)
        let raw = Data(("Content-Type: text/plain; charset=utf-8\r\n\r\n" + input.body).utf8)
        let capture = InboundCapture(permissionID: permission.id, subject: input.subject, messageID: "synthetic@example.com", raw: raw)
        return try await store.importCapture(capture, syntheticGrant: true)
    }
}

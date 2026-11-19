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
public typealias MailIdentityResolver = @MainActor @Sendable (StoredReply, AccountScope) async throws -> VerifiedMail?

@MainActor
public final class ReplyPipeline {
    public let store: PipelineStore
    public let inbox: CaptureInbox
    private let resolve: MailIdentityResolver
    private let model: @Sendable (String) -> any ReplyModelRunning
    private var pumping = false
    private let inAuthorizedInbox: (@MainActor @Sendable (String, String, [AccountScope]) async throws -> Bool?)?
    private var scopeChecked: Set<String> = []
    private var nextCaptureCheck: [String: Date] = [:]
    private var nextRecordCheck: [String: Date] = [:]
    public init(store: PipelineStore, inbox: CaptureInbox, resolve: @escaping MailIdentityResolver,
                inAuthorizedInbox: (@MainActor @Sendable (String, String, [AccountScope]) async throws -> Bool?)? = nil,
                model: @escaping @Sendable (String) -> any ReplyModelRunning = {
                    DeepSeekHarnessAdapter(executable: URL(fileURLWithPath: $0), dialect: DeepSeekHarnessDialect())
                }) {
        self.store = store; self.inbox = inbox; self.resolve = resolve; self.model = model; self.inAuthorizedInbox = inAuthorizedInbox
    }
    private func mailReadStillAuthorized(_ settings: PipelineSettings) throws -> Bool {
        try Task.checkCancellation()
        return try store.hasCurrentMailReadAuthorization(settings)
    }

    /// Read-only enrichment for older rows, using the same source/account proof as dispatch.
    /// No state transition, body replacement, model call or email mutation.
    public func loadCorrespondents(_ id: String) async throws {
        try Task.checkCancellation()
        guard let item = try store.record(id), item.correspondents == nil, item.discardedAt == nil,
              !item.syntheticAuthorized, item.manualExecutable == nil,
              item.excludedFromAuthorizedInbox != true else { return }
        let settings = try store.settings()
        guard settings.permission?.id == item.permissionID else { return }
        let scopes = settings.authorizedScopes.filter { item.accountID == nil || $0.accountID == item.accountID }
        var matches: [VerifiedMail] = []
        for scope in scopes {
            let result = try await resolve(item, scope)
            guard try mailReadStillAuthorized(settings) else { return }
            guard let verified = result, verified.accountID == scope.accountID,
                  item.localID == nil || verified.localID == item.localID,
                  let source = verified.source else { continue }
            let valid = item.sourceEvidence?.matches(source)
                ?? (item.sourceDigest != nil && mailSourceDigest(source) == item.sourceDigest)
            if valid { matches.append(verified) }
        }
        guard matches.count == 1, let source = matches.first?.source,
              let correspondents = MailCorrespondents(source),
              var current = try store.record(id), current.correspondents == nil,
              current.discardedAt == nil, current.excludedFromAuthorizedInbox != true,
              current.localID == item.localID, current.accountID == item.accountID,
              current.sourceEvidence == item.sourceEvidence, current.sourceDigest == item.sourceDigest else { return }
        current.correspondents = correspondents
        try store.save(current)
    }
    public func prepareMailCompose(id: String, subject: String, body: String,
        senderAddress: @MainActor (String, [String]) throws -> String) async throws -> MailComposeRequest {
        guard let item = try store.record(id), item.excludedFromAuthorizedInbox != true,
              item.manualExecutable == nil, !item.syntheticAuthorized, item.discardedAt == nil,
              !item.isPreparing, item.state != .cancelled, !item.input.body.isEmpty,
              item.displayedSubject == subject, item.displayedBody == body,
              item.capturedAt > Date().addingTimeInterval(-7 * 86_400),
              let messageID = item.messageID else { throw MailComposeError.unavailable }
        let settings = try store.settings()
        guard !settings.paused, settings.permission?.id == item.permissionID else { throw MailComposeError.unavailable }
        let scopes = settings.authorizedScopes.filter { item.accountID == nil || $0.accountID == item.accountID }
        var matches: [(AccountScope, VerifiedMail)] = []
        for scope in scopes {
            try Task.checkCancellation()
            let result = try await resolve(item, scope)
            guard try mailReadStillAuthorized(settings) else { throw MailComposeError.unavailable }
            guard let verified = result, verified.accountID == scope.accountID,
                  item.localID == nil || verified.localID == item.localID, let source = verified.source,
                  item.sourceEvidence?.matches(source) ?? (item.sourceDigest != nil && item.sourceDigest == mailSourceDigest(source)) else { continue }
            matches.append((scope, verified))
        }
        guard matches.count == 1, let (scope, match) = matches.first, let source = match.source,
              try store.settings().revision == settings.revision else { throw MailComposeError.unavailable }
        let latestSettings = try store.settings()
        guard !latestSettings.paused, latestSettings.permission?.id == item.permissionID,
              let latest = try store.record(id), latest.discardedAt == nil, !latest.isPreparing, latest.state != .cancelled,
              latest.excludedFromAuthorizedInbox != true, latest.displayedSubject == subject,
              latest.displayedBody == body, latest.capturedAt > Date().addingTimeInterval(-7 * 86_400)
        else { throw MailComposeError.changedSinceConfirmation }
        let recipients = try MailReplyRecipients.parse(source)
        let addresses = MailCorrespondents(source)
        let sender = try senderAddress(scope.accountID, (addresses?.recipients ?? []) + (addresses?.cc ?? []))
        return try MailComposeRequest(recordID: id, accountID: scope.accountID, accountName: scope.accountName,
            sender: sender, recipients: recipients, subject: subject, body: body,
            originalSubject: item.input.subject, messageID: messageID, localID: match.localID,
            sourceDigest: contentDigest(source), settingsRevision: settings.revision)
    }

    public func openMailCompose(confirmedRequest: MailComposeRequest,
        senderAddress: @MainActor (String, [String]) throws -> String,
        open: @MainActor (MailComposeRequest) async throws -> MailComposeReceipt) async throws -> MailComposeReceipt {
        let fresh = try await prepareMailCompose(id: confirmedRequest.recordID, subject: confirmedRequest.subject,
            body: confirmedRequest.body, senderAddress: senderAddress)
        guard fresh == confirmedRequest else { throw MailComposeError.changedSinceConfirmation }
        let finalSettings = try store.settings()
        guard !finalSettings.paused, finalSettings.revision == fresh.settingsRevision,
              var current = try store.record(fresh.recordID), current.permissionID == finalSettings.permission?.id,
              current.discardedAt == nil, current.state != .cancelled, !current.isPreparing,
              current.excludedFromAuthorizedInbox != true,
              current.displayedSubject == fresh.subject, current.displayedBody == fresh.body else {
            throw MailComposeError.changedSinceConfirmation
        }
        if let handoff = current.composeHandoff {
            if handoff.fingerprint == fresh.fingerprint, let receipt = handoff.receipt { return receipt }
            throw MailComposeError.alreadyAttempted
        }
        // Persist before crossing the process boundary. Any throw/crash remains a non-replayable attempt.
        current.composeHandoff = MailComposeHandoff(fingerprint: fresh.fingerprint)
        try store.save(current)
        let receipt: MailComposeReceipt
        do { receipt = try await open(fresh) }
        catch { throw MailComposeError.outcomeUnknown }
        guard !receipt.outgoingID.isEmpty, var latest = try store.record(fresh.recordID),
              latest.composeHandoff?.fingerprint == fresh.fingerprint else { throw MailComposeError.outcomeUnknown }
        latest.composeHandoff?.receipt = receipt
        try store.save(latest)
        return receipt
    }

    public func updateSettings(_ change: (inout PipelineSettings) -> Void) throws {
        let previous = try store.settings()
        var settings = previous; change(&settings)
        if settings.permission != previous.permission || settings.authorizedScopes != previous.authorizedScopes ||
            settings.executable != previous.executable || settings.level != previous.level || settings.suggestionsOnly != previous.suggestionsOnly { settings.revision = UUID() }
        // DB is authoritative. A crash before the extension snapshot changes cannot grant a model call.
        try store.saveSettings(settings)
        try inbox.setPermission(settings.paused ? nil : settings.permission)
    }
    public func importInbox() async throws {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        try await importCaptures()
    }

    private func importCaptures() async throws {
        try Task.checkCancellation()
        try inbox.pruneClaims()
        if let issue = try inbox.issue() { try store.note(issue) }
        let files = try inbox.files().sorted {
            let a = (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? .distantPast
            let b = (try? FileManager.default.attributesOfItem(atPath: $1.path)[.modificationDate] as? Date) ?? .distantPast
            return a < b
        }
        var membershipQueries = 0
        for file in files {
            try Task.checkCancellation()
            let capture: InboundCapture
            do {
                capture = try JSONDecoder().decode(InboundCapture.self, from: CaptureInbox.read(file, limit: MailBodyLimits.captureFileCeiling))
                try capture.validate()
            } catch {
                try store.note("invalidCapture")
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory != true || values.isSymbolicLink == true { try FileManager.default.removeItem(at: file) }
                continue
            }
            if let inAuthorizedInbox {
                let settings = try store.settings()
                guard capture.permissionID == settings.permission?.id,
                      capture.capturedAt > Date().addingTimeInterval(-86_400) else {
                    try store.note("captureExpiredOrRevoked")
                    nextCaptureCheck.removeValue(forKey: file.path)
                    try FileManager.default.removeItem(at: file); continue
                }
                guard !settings.paused else { continue }
                if let next = nextCaptureCheck[file.path], next > Date() { continue }
                guard let messageID = capture.messageID else { continue }
                guard membershipQueries < 2 else { break }
                membershipQueries += 1
                let membership: Bool?
                do { membership = try await inAuthorizedInbox(messageID, capture.subject, settings.authorizedScopes) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    guard try mailReadStillAuthorized(settings) else { continue }
                    // A Mail timeout must not starve unrelated candidates or authorize this one.
                    nextCaptureCheck[file.path] = Date().addingTimeInterval(30)
                    continue
                }
                guard try mailReadStillAuthorized(settings),
                      capture.capturedAt > Date().addingTimeInterval(-86_400) else { continue }
                guard let included = membership else {
                    nextCaptureCheck[file.path] = Date().addingTimeInterval(30)
                    // Mail indexing can lag the callback. Keep the bounded staging file, not a visible record.
                    continue
                }
                nextCaptureCheck.removeValue(forKey: file.path)
                if !included {
                    // Only discard a confirmed outside-scope staging file, never an existing record or Mail message.
                    try FileManager.default.removeItem(at: file); continue
                }
            }
            do {
                let id = try store.importCapture(capture)
                if inAuthorizedInbox != nil, var imported = try store.record(id) {
                    imported.excludedFromAuthorizedInbox = false; try store.save(imported)
                }
            }
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
        guard var item = try store.record(id), item.canRecheckIdentity, item.permissionID == (try store.settings()).permission?.id else { throw MailpipeError.invalidInput }
        item.accountID = nil; item.localID = nil; item.revision = nil
        item.state = .awaitingAccount; item.error = nil; try store.save(item)
    }
    /// User-confirmed retry only. Reverify captured mail and preserve local edits.
    public func regenerate(_ id: String) throws {
        let settings = try store.settings()
        guard var item = try store.record(id), !settings.paused, !item.isPreparing,
              item.discardedAt == nil, !item.runs.contains(where: { $0.finishedAt == nil }),
              (item.regenerationCount ?? 0) < 3,
              item.capturedAt > Date().addingTimeInterval(-7 * 86_400),
              let executable = settings.executable else { throw MailpipeError.invalidInput }
        if let tool = item.manualExecutable {
            guard settings.suggestionsOnly == true, tool == executable else { throw PipelineError.revoked }
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
        item.level = settings.level
        item.regenerationCount = (item.regenerationCount ?? 0) + 1
        item.error = nil
        try store.save(item)
    }
    public func cancel(_ id: String) throws {
        guard var item = try store.record(id) else { return }
        item.state = .cancelled; item.error = "cancelled"; try store.save(item)
    }
    /// Process bounded batches; each timer tick is serial. No automatic retry of failed/unknown calls.
    public func pump() async throws {
        guard !pumping else { return }
        pumping = true; defer { pumping = false }
        try await importCaptures()
        var membershipQueries = 0
        for var item in try store.records().prefix(1_000) {
            try Task.checkCancellation()
            let settings = try store.settings()
            guard !settings.paused else { return }
            if settings.permission?.id == item.permissionID, !item.syntheticAuthorized, item.manualExecutable == nil, let inAuthorizedInbox {
                let key = item.id + settings.revision.uuidString
                if !scopeChecked.contains(key) {
                    if let next = nextRecordCheck[key], next > Date() { continue }
                    guard let current = try store.record(item.id), current.discardedAt == nil,
                          current.permissionID == settings.permission?.id else { continue }
                    item = current
                    let included: Bool?
                    do {
                        if let messageID = item.messageID {
                            guard membershipQueries < 2 else { continue }
                            membershipQueries += 1
                            included = try await inAuthorizedInbox(messageID, item.input.subject, settings.authorizedScopes)
                        } else { included = nil }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard try mailReadStillAuthorized(settings) else { continue }
                        nextRecordCheck[key] = Date().addingTimeInterval(30)
                        continue
                    }
                    guard try mailReadStillAuthorized(settings), let current = try store.record(item.id) else { continue }
                    item = current
                    guard let included else {
                        // Unknown is not exclusion. Preserve substantive existing content but do not dispatch.
                        item.excludedFromAuthorizedInbox = nil; try store.save(item)
                        nextRecordCheck[key] = Date().addingTimeInterval(30)
                        continue
                    }
                    nextRecordCheck.removeValue(forKey: key)
                    item.excludedFromAuthorizedInbox = !included
                    try store.save(item)
                    scopeChecked.insert(key)
                }
                if item.excludedFromAuthorizedInbox == true { continue }
            }
            if [.awaitingAccount, .queued, .draftQueued].contains(item.state) { try await process(item.id) }
        }
    }
    private func process(_ id: String) async throws {
        try Task.checkCancellation()
        guard var item = try store.record(id), [.awaitingAccount, .queued, .draftQueued].contains(item.state),
              item.discardedAt == nil, item.excludedFromAuthorizedInbox != true else { return }
        let settings = try store.settings()
        guard let executable = settings.executable, executable.hasPrefix("/"), !settings.paused else { return }
        guard item.capturedAt > Date().addingTimeInterval(-7 * 86_400) else {
            item.state = .needsReview; item.error = "contentExpired"; try store.save(item); return
        }
        if let confirmedTool = item.manualExecutable {
            guard settings.suggestionsOnly == true, confirmedTool == executable else {
                item.state = .cancelled; item.error = "revoked"; try store.save(item); return
            }
        } else if !item.syntheticAuthorized {
            guard settings.permission?.id == item.permissionID else {
                item.state = .cancelled; item.error = "revoked"; try store.save(item); return
            }
            let scopes = settings.authorizedScopes
            guard !scopes.isEmpty else { return }
            if item.accountID == nil {
                func currentCandidate() throws -> StoredReply? {
                    guard try mailReadStillAuthorized(settings),
                          let current = try store.record(id), current.state == item.state, current.accountID == nil,
                          current.discardedAt == nil, current.excludedFromAuthorizedInbox != true,
                          current.sourceDigest == item.sourceDigest, current.sourceEvidence == item.sourceEvidence,
                          current.capturedAt > Date().addingTimeInterval(-7 * 86_400) else { return nil }
                    return current
                }
                do {
                    var matches: [(AccountScope, VerifiedMail)] = []
                    for scope in scopes {
                        let result = try await resolve(item, scope)
                        guard let current = try currentCandidate() else { return }
                        item = current
                        if let verified = result, verified.accountID == scope.accountID { matches.append((scope, verified)) }
                    }
                    guard matches.count == 1, let (scope, verified) = matches.first else {
                        item.error = matches.isEmpty ? "identityUnresolved" : "identityAmbiguous"
                        item.state = .needsReview; try store.save(item); return
                    }
                    if let evidence = item.sourceEvidence {
                        guard let source = verified.source, evidence.matches(source) else {
                            item.error = "identityUnresolved"; item.state = .needsReview; try store.save(item); return
                        }
                        item.input = MailInput(messageRef: item.id, subject: item.input.subject, body: try PlainMailBody.decode(source))
                    }
                    if let source = verified.source { item.correspondents = MailCorrespondents(source) }
                    item.accountID = verified.accountID; item.localID = verified.localID; item.scopeID = scope.id
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard var current = try currentCandidate() else { return }
                    current.error = (error as? MailBodyRejection)?.rawValue ?? "identityUnavailable"
                    current.state = .needsReview
                    try store.save(current)
                    return
                }
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
              (item.manualExecutable == settings.executable && item.manualExecutable != nil && settings.suggestionsOnly == true) || item.syntheticAuthorized || (settings.permission?.id == item.permissionID && settings.authorizedScopes.contains { $0.accountID == item.accountID && (item.scopeID == nil || $0.id == item.scopeID) }) else { throw PipelineError.revoked }
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
    /// Explicit confirmation authorizes exactly this pasted content and tool, without Mail access.
    @discardableResult public func enqueueManual(id: UUID, subject: String, body: String, executable: String) throws -> String {
        let settings = try store.settings()
        guard settings.suggestionsOnly == true, !settings.paused,
              settings.executable == executable, executable.hasPrefix("/"),
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              subject.utf8.count <= 998, body.utf8.count <= 16_384 else { throw MailpipeError.invalidInput }
        let key = id.uuidString
        if let existing = try store.record(key) {
            guard existing.manualExecutable == executable, existing.input.subject == subject,
                  existing.input.body == body else { throw MailpipeError.invalidInput }
            return key // A repeated confirmation never replays a completed/unknown call.
        }
        guard try store.records().count < 1_000 else { throw PipelineError.quota }
        var item = StoredReply(id: key, permissionID: UUID(), capturedAt: Date(), messageID: nil,
            input: MailInput(messageRef: key, subject: subject, body: body), state: .queued)
        item.manualExecutable = executable
        item.accountID = "explicit-single-message" // Consent route, not a discovered Mail account.
        item.revision = settings.revision; item.level = settings.level
        try store.save(item)
        return key
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
            temporary.appendingPathComponent(capture.id.uuidString + ".capture"), limit: MailBodyLimits.captureFileCeiling))
        let id = try store.importCapture(persisted, syntheticGrant: true)
        try FileManager.default.removeItem(at: temporary.appendingPathComponent(capture.id.uuidString + ".capture"))
        return id
    }
}

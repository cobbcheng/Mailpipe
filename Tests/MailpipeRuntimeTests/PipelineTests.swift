import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
@testable import MailpipeRuntime
import MailpipeCore
import HarnessAdapters

func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

actor FakeReplyModel: ReplyModelRunning {
    private(set) var calls = 0
    private(set) var draftRequests: [ReplyDraftRequest] = []
    let harness: HarnessKind
    let actualModel: String?
    private var returnsNoReply = false
    func respondWithNoReply() { returnsNoReply = true }
    var afterRun: (@Sendable () async throws -> Void)?
    func setAfterRun(_ action: @escaping @Sendable () async throws -> Void) { afterRun = action }
    init(harness: HarnessKind = .deepseek, actualModel: String? = nil) {
        self.harness = harness; self.actualModel = actualModel
    }
    func run(_ task: ReplyModelTask, route: AccountRoute, authorize: @escaping @Sendable () async throws -> Void) async throws -> ReplyModelOutput {
        try route.authorize(harness); try await authorize(); calls += 1
        var object: [String: Any]
        switch task {
        case .draft(let request):
            draftRequests.append(request)
            if returnsNoReply {
                object = ["schema_version": 1, "disposition": "no_reply"]
            } else {
                object = try JSONSerialization.jsonObject(with: ReplySyntheticFixture.draft) as! [String: Any]
            }
            object["request_id"] = request.requestID; object["triage_request_id"] = request.triageRequestID; object["message_ref"] = request.message.messageRef
        }
        try await afterRun?()
        return ReplyModelOutput(content: try JSONSerialization.data(withJSONObject: object), inputTokens: 10, outputTokens: 20, actualModel: actualModel)
    }
}

/// Keep a synthetic Mail read outstanding while a separate task uses the workbench.
private actor DelayedMailRead {
    let started = XCTestExpectation(description: "Mail read started")
    private(set) var calls = 0
    private var reply: CheckedContinuation<Void, Never>?
    private var finished = false

    func waitForReply() async {
        calls += 1
        guard !finished, calls == 1 else { return }
        await withCheckedContinuation { continuation in
            reply = continuation
            started.fulfill()
        }
    }

    func finish() {
        finished = true
        reply?.resume()
        reply = nil
    }
}

@MainActor
final class PipelineTests: XCTestCase {
    func testMigratesV1DatabaseToIndexedV2SchemaAndCachesDraft() async throws {
        let root = try temporary()
        let dbPath = root.appendingPathComponent("state.sqlite").path
        let permission = CapturePermission(delivery: .mailKit)
        let input = MailInput(messageRef: "legacy-row", subject: "Legacy Subject", body: "Please confirm.")
        var legacy = StoredReply(id: "legacy-row", permissionID: permission.id, capturedAt: Date(),
                                 messageID: "legacy@example.com", input: input, state: .draftReady)
        legacy.mailKitBody = true
        legacy.correspondents = MailCorrespondents(sender: "from@example.com", recipients: ["to@example.com"], cc: [])
        let task = try ReplyDraftRequest(message: input)
        legacy.draftData = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "request_id": task.requestID, "triage_request_id": task.triageRequestID,
            "message_ref": legacy.id, "subject": "Re: Legacy Subject", "body": "Confirmed."
        ])
        let payload = try JSONEncoder().encode(legacy)
        var settings = PipelineSettings()
        settings.permission = permission
        let settingsPayload = try JSONEncoder().encode(settings)

        // Seed a legacy v1 database without indexed columns.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE records (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
            CREATE TABLE ingests (id TEXT PRIMARY KEY, record_id TEXT NOT NULL);
            CREATE TABLE metadata (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
            PRAGMA user_version = 1;
            """, nil, nil, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO records (id, payload) VALUES (?, ?)", -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_text(stmt, 1, legacy.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO metadata (id, payload) VALUES ('settings', ?)", -1, &stmt, nil), SQLITE_OK)
        _ = settingsPayload.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
        sqlite3_close(db)

        // Opening PipelineStore migrates v1 -> v2 and populates indexed columns.
        let store = try PipelineStore(directory: root)
        let migrated = try unwrap(try await store.record(legacy.id))
        XCTAssertEqual(migrated.draft?.body, "Confirmed.")
        let idDigest = try XCTUnwrap(ComposeMessageIdentity.digest(forMessageID: "legacy@example.com"))
        let candidates = try await store.composeCandidates(messageIDDigest: idDigest)
        XCTAssertEqual(candidates.map(\.id), [legacy.id])
        let subjectDigest = ComposeMessageIdentity.digest(forSubject: "Legacy Subject")
        let choices = try await store.composeDraftChoices(subjectDigest: subjectDigest, settings: settings, now: Date())
        XCTAssertEqual(choices.map(\.sender), ["from@example.com"])

        // Generation-gated snapshot returns nil when unchanged and refreshes after writes.
        let firstSnapshot = try unwrap(try await store.snapshot(ifChangedSince: nil))
        let unchanged = try await store.snapshot(ifChangedSince: firstSnapshot.generation)
        XCTAssertNil(unchanged)
        try await store.saveEdits(legacy.id, subject: "Re: Legacy Subject", body: "Updated body")
        let updatedSnapshot = try unwrap(try await store.snapshot(ifChangedSince: firstSnapshot.generation))
        XCTAssertGreaterThan(updatedSnapshot.generation, firstSnapshot.generation)
        XCTAssertEqual(updatedSnapshot.records.first?.displayedBody, "Updated body")
    }

    func testAddressLoadPreservesConcurrentEditsAndHonorsRevocation() async throws {
        let root = try temporary()
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let raw = Data("From: sender@example.com\nTo: recipient@example.com\n\nBody".utf8)
        var settings = PipelineSettings()
        settings.permission = CapturePermission()
        settings.scope = try AccountScope(accountID: "test", accountName: "Test", mailboxName: "INBOX")
        try await store.saveSettings(settings)
        let id = try await store.importCapture(InboundCapture(permissionID: settings.permission!.id, subject: "Synthetic", messageID: "test@example.com", raw: raw))
        var item = try unwrap(try await store.record(id)); item.correspondents = nil; item.displayBody = nil; try await store.save(item)
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { item, scope in
            var current = try unwrap(try await store.record(item.id))
            current.editedBody = "Concurrent edit"; current.state = .cancelled
            try await store.save(current)
            return VerifiedMail(accountID: scope.accountID, localID: "1", source: raw)
        })
        try await pipeline.loadCorrespondents(id, includeBody: true)
        item = try unwrap(try await store.record(id))
        XCTAssertEqual(item.displayBody, "Body")
        XCTAssertEqual(item.editedBody, "Concurrent edit")
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertEqual(item.correspondents?.sender, "sender@example.com")
        item.correspondents = nil; try await store.save(item)
        let revoked = ReplyPipeline(store: store, inbox: inbox, resolve: { _, scope in
            var changed = try await store.settings(); changed.permission = nil; changed.revision = UUID()
            try await store.saveSettings(changed)
            return VerifiedMail(accountID: scope.accountID, localID: "1", source: raw)
        })
        try await revoked.loadCorrespondents(id)
        let afterRevoke = try await store.record(id)?.correspondents
        XCTAssertNil(afterRevoke)
    }

    func testCorrespondentsEnrichmentIsVerifiedAndDoesNotRunModel() async throws {
        let root = try temporary()
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let fake = FakeReplyModel()
        let raw = Data("From: sender@example.com\nTo: alias@example.com\nReply-To: reply@example.com\n\nOriginal body".utf8)
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, scope in
            VerifiedMail(accountID: scope.accountID, localID: "1", source: raw)
        }, model: { _ in fake })
        try await pipeline.updateSettings {
            $0.permission = CapturePermission(); $0.paused = true
            $0.scope = try? AccountScope(accountID: "test", accountName: "account@example.com", mailboxName: "INBOX")
        }
        let permission = try unwrap(try await store.settings().permission)
        let id = try await store.importCapture(InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "test@example.com", raw: raw))
        var old = try unwrap(try await store.record(id))
        XCTAssertEqual(old.correspondents?.recipients, ["alias@example.com"])
        old.correspondents = nil; old.editedBody = "Keep my edit"
        try await store.save(old)
        try await pipeline.loadCorrespondents(id)
        var filled = try unwrap(try await store.record(id))
        XCTAssertEqual(filled.correspondents?.sender, "sender@example.com")
        XCTAssertEqual(filled.correspondents?.recipients, ["alias@example.com"])
        XCTAssertEqual(filled.editedBody, old.editedBody)
        XCTAssertEqual(filled.state, old.state)
        XCTAssertEqual(filled.input, old.input)
        XCTAssertTrue(filled.runs.isEmpty)
        filled.correspondents = nil; filled.sourceDigest = "incorrect"
        try await store.save(filled)
        try await pipeline.loadCorrespondents(id)
        let badDigest = try await store.record(id)?.correspondents
        XCTAssertNil(badDigest)
        filled.sourceDigest = mailSourceDigest(raw); filled.excludedFromAuthorizedInbox = true
        try await store.save(filled)
        try await pipeline.loadCorrespondents(id)
        let excluded = try await store.record(id)?.correspondents
        XCTAssertNil(excluded)
        let calls = await fake.calls; XCTAssertEqual(calls, 0)
    }

    func testChangingPermissionDoesNotQueryNewMailboxesWithOldRecord() async throws {
        let configured = try await setup(try temporary())
        let pipeline = ReplyPipeline(store: configured.store, inbox: configured.inbox,
            resolve: { _, _ in XCTFail("Revoked identity lookup"); return nil })
        let id = try await pipeline.store.importCapture(try await capture(pipeline))
        try await pipeline.updateSettings { $0.permission = CapturePermission() }
        try await pipeline.pump()
        let saved = try await pipeline.store.record(id)
        XCTAssertEqual(saved?.state, .cancelled)
        XCTAssertEqual(saved?.error, "revoked")
    }

    func testLateIdentityResultOrErrorCannotUndoCancellation() async throws {
        for lookupFails in [false, true] {
            let configured = try await setup(try temporary())
            let delayed = DelayedMailRead()
            let fake = FakeReplyModel()
            let pipeline = ReplyPipeline(store: configured.store, inbox: configured.inbox, resolve: { _, scope in
                await delayed.waitForReply()
                if lookupFails { throw PipelineError.storage }
                return VerifiedMail(accountID: scope.accountID, localID: "one")
            }, model: { _ in fake })
            let id = try await pipeline.store.importCapture(try await capture(pipeline))
            let pumping = Task { try await pipeline.pump() }
            let status = await XCTWaiter.fulfillment(of: [delayed.started], timeout: 3)
            XCTAssertEqual(status, .completed)
            try await pipeline.cancel(id)
            await delayed.finish()
            try await pumping.value
            let current = try unwrap(try await pipeline.store.record(id))
            XCTAssertEqual(current.state, .cancelled)
            XCTAssertEqual(current.error, "cancelled")
            XCTAssertTrue(current.runs.isEmpty)
            let calls = await fake.calls
            XCTAssertEqual(calls, 0)
        }
    }

    func testFailedBodyPublicationReleasesOnlyItsOwnClaim() throws {
        let inbox = try CaptureInbox(directory: try temporary().appendingPathComponent("inbox"))
        let permission = CapturePermission(); try inbox.setPermission(permission)
        XCTAssertThrowsError(try inbox.publishBodyRequest(permission: permission, subject: "Synthetic", messageID: "one@example.com") { throw PipelineError.quota })
        XCTAssertTrue(try inbox.publishBodyRequest(permission: permission, subject: "Synthetic", messageID: "one@example.com") { })
        XCTAssertFalse(try inbox.publishBodyRequest(permission: permission, subject: "Synthetic", messageID: "one@example.com") { XCTFail("Duplicate request") })
        XCTAssertTrue(try inbox.publishBodyRequest(permission: permission, subject: "Synthetic", messageID: "two@example.com") { })
        XCTAssertFalse(try inbox.claimBody(permission: permission, subject: "Synthetic", messageID: "one@example.com"))
    }

    func temporary() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    func setup(_ root: URL, fake: FakeReplyModel = FakeReplyModel()) async throws -> ReplyPipeline {
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, scope in VerifiedMail(accountID: scope.accountID, localID: "one") }, model: { _ in fake })
        try await pipeline.updateSettings {
            $0.executable = "/fake/dsh"
            $0.permission = CapturePermission()
            $0.scope = try? AccountScope(accountID: "test", accountName: "test", mailboxName: "INBOX")
        }
        return pipeline
    }

    func capture(_ pipeline: ReplyPipeline) async throws -> InboundCapture {
        InboundCapture(permissionID: try unwrap(try await pipeline.store.settings().permission).id,
            subject: "Synthetic", messageID: "test@example.com", raw: Data("Content-Type: text/plain\r\n\r\nPlease reply".utf8))
    }

    func testEditsDiscardUndoAndLegacyPayload() async throws {
        let pipeline = try await setup(temporary())
        try pipeline.inbox.publish(try await capture(pipeline)); try await pipeline.pump()
        let item = try unwrap(try await pipeline.store.records().first)
        try await pipeline.store.saveEdits(item.id, subject: "Edited", body: "Local reply")
        let now = Date()
        try await pipeline.store.discard(item.id, now: now)
        let discarded = try await pipeline.store.record(item.id)?.discardedAt
        XCTAssertNotNil(discarded)
        try await pipeline.store.restoreDiscard(item.id, now: now.addingTimeInterval(10))
        let restored = try await pipeline.store.record(item.id)
        XCTAssertEqual(restored?.displayedBody, "Local reply")
        XCTAssertNil(restored?.discardedAt)
        try await pipeline.store.discard(item.id, now: now)
        do { try await pipeline.store.restoreDiscard(item.id, now: now.addingTimeInterval(16)); XCTFail("expired undo") } catch {}
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        for key in ["editedSubject", "editedBody", "discardedAt", "regenerationCount"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(StoredReply.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.editedBody)
        XCTAssertEqual(legacy.displayedBody, item.draft?.body)
    }

    func testReplyBodyEditsSurviveStoreReopen() async throws {
        let root = try temporary()
        var pipeline: ReplyPipeline? = try await setup(root)
        try pipeline!.inbox.publish(try await capture(pipeline!)); try await pipeline!.pump()
        let id = try unwrap(try await pipeline!.store.records().first).id
        try await pipeline!.store.saveEdits(id, subject: "Unchanged subject", body: "Persisted reply only")
        pipeline = nil
        let reopened = try PipelineStore(directory: root.appendingPathComponent("state"))
        let savedBody = try await reopened.record(id)?.displayedBody
        XCTAssertEqual(savedBody, "Persisted reply only")
    }

    func testRegenerationIsBoundedAndReplacesBody() async throws {
        let fake = FakeReplyModel(), pipeline = try await setup(temporary(), fake: fake)
        try pipeline.inbox.publish(try await capture(pipeline)); try await pipeline.pump()
        let id = try unwrap(try await pipeline.store.records().first).id
        try await pipeline.store.saveEdits(id, subject: "My subject", body: "My local edit")
        for _ in 0..<3 {
            try await pipeline.regenerate(id)
            do { try await pipeline.regenerate(id); XCTFail("duplicate regeneration") } catch {}
            try await pipeline.pump()
            let saved = try unwrap(try await pipeline.store.record(id))
            XCTAssertEqual(saved.displayedBody, try XCTUnwrap(saved.draft).body)
            XCTAssertEqual(saved.displayedSubject, "My subject")
            XCTAssertFalse(saved.hasDraftCandidate)
            XCTAssertEqual(saved.state, .draftReady)
        }
        do { try await pipeline.regenerate(id); XCTFail("limit reached") } catch {}
        let count = await fake.calls; XCTAssertEqual(count, 4)
        try await pipeline.store.discard(id)
        do { try await pipeline.regenerate(id); XCTFail("discarded") } catch {}
    }

    func testRegenerationFailureAndCancelKeepLocalEdit() async throws {
        let fake = FakeReplyModel(), pipeline = try await setup(temporary(), fake: fake)
        try pipeline.inbox.publish(try await capture(pipeline)); try await pipeline.pump()
        let id = try unwrap(try await pipeline.store.records().first).id
        try await pipeline.store.saveEdits(id, subject: "Edited subject", body: "Keep this reply")
        await fake.setAfterRun { throw MailpipeError.invalidOutput }
        try await pipeline.regenerate(id); try await pipeline.pump()
        let failed = try await pipeline.store.record(id)
        XCTAssertEqual(failed?.state, .needsReview)
        XCTAssertEqual(failed?.displayedBody, "Keep this reply")
        try await pipeline.regenerate(id); try await pipeline.cancel(id); try await pipeline.pump()
        let cancelled = try await pipeline.store.record(id)
        XCTAssertEqual(cancelled?.state, .cancelled)
        XCTAssertEqual(cancelled?.displayedBody, "Keep this reply")
    }

    func testSyntheticRunOmitsSavedReplyInstructions() async throws {
        let fake = FakeReplyModel()
        let pipeline = try await setup(temporary(), fake: fake)
        try await pipeline.store.saveReplyInstructions("Close with a thank-you.")
        let id = try await pipeline.enqueueSynthetic()
        try await pipeline.pump()
        let state = try await pipeline.store.record(id)?.state
        XCTAssertEqual(state, .draftReady)
        let requests = await fake.draftRequests
        XCTAssertEqual(requests.map(\.replyInstructions), [nil])
    }

    func testLegacyManualRecordsReopenWithoutDispatchAndKeepLocalEdits() async throws {
        let directory = try temporary()
        let inbox = try CaptureInbox(directory: directory.appendingPathComponent("inbox"))
        let permission = CapturePermission(delivery: .mailKit)
        var archived = StoredReply(id: "archived", permissionID: permission.id, capturedAt: Date(), messageID: nil,
            input: MailInput(messageRef: "archived", subject: "Example", body: "Please confirm receipt."), state: .draftReady)
        archived.manualExecutable = "/fake/dsh"
        archived.draftData = Data(#"{"schema_version":1,"request_id":"archived-draft","triage_request_id":"archived-triage","message_ref":"archived","subject":"Re: Example","body":"Received."}"#.utf8)
        archived.editedBody = "Preserved edit"
        archived.regenerationCount = 1
        var queued = StoredReply(id: "queued", permissionID: permission.id, capturedAt: Date(), messageID: nil,
            input: ReplySyntheticFixture.message, state: .queued)
        queued.manualExecutable = "/fake/dsh"
        do {
            let store = try PipelineStore(directory: directory)
            var settings = PipelineSettings()
            settings.executable = "/fake/dsh"; settings.paused = true
            try await store.saveSettings(settings)
            try await store.save(archived); try await store.save(queued)
        }
        let store = try PipelineStore(directory: directory)
        let fake = FakeReplyModel()
        let pipeline = ReplyPipeline(store: store, inbox: inbox,
            resolve: { _, _ in XCTFail("Archived manual records cannot read Mail"); return nil }, model: { _ in fake })
        let queuedState = try await store.record(queued.id)?.state
        XCTAssertEqual(queuedState, .cancelled)
        let history = try unwrap(try await store.record(archived.id))
        XCTAssertEqual(history.state, .draftReady)
        XCTAssertTrue(history.canDisplayInWorkbench)
        XCTAssertEqual(history.draft?.body, "Received.")
        XCTAssertEqual(history.displayedBody, "Preserved edit")
        XCTAssertEqual(history.draftData, archived.draftData)
        try await store.saveEdits(history.id, subject: history.displayedSubject, body: "Updated edit")
        try await pipeline.updateSettings { $0.paused = false; $0.permission = permission }
        let currentSettings = try await store.settings()
        XCTAssertFalse(history.canRequestRegeneration(settings: currentSettings))
        do { try await pipeline.regenerate(history.id); XCTFail("archived manual") } catch {}
        try await pipeline.loadCorrespondents(history.id, includeBody: true)
        try await pipeline.pump()
        let updatedBody = try await store.record(history.id)?.displayedBody
        XCTAssertEqual(updatedBody, "Updated edit")
        let calls = await fake.calls; XCTAssertEqual(calls, 0)
    }

    func testCancelledRunMustFinishBeforeRegeneration() async throws {
        let pipeline = try await setup(temporary())
        try pipeline.inbox.publish(try await capture(pipeline)); try await pipeline.pump()
        var item = try unwrap(try await pipeline.store.records().first)
        item.state = .cancelled
        item.runs[item.runs.count - 1].finishedAt = nil
        try await pipeline.store.save(item)
        do { try await pipeline.regenerate(item.id); XCTFail("unfinished run") } catch {}
    }

    func testRegenerationRespectsPauseAndRevocation() async throws {
        let pipeline = try await setup(temporary())
        try pipeline.inbox.publish(try await capture(pipeline)); try await pipeline.pump()
        let id = try unwrap(try await pipeline.store.records().first).id
        try await pipeline.updateSettings { $0.paused = true }
        do { try await pipeline.regenerate(id); XCTFail("paused") } catch {}
        try await pipeline.updateSettings { $0.paused = false; $0.permission = nil }
        do { try await pipeline.regenerate(id); XCTFail("revoked") } catch {}
    }

    func testMultipleSelectedMailboxesRequireUniqueMatch() async throws {
        for ambiguous in [false, true] {
            let root = try temporary(), fake = FakeReplyModel()
            let store = try PipelineStore(directory: root.appendingPathComponent("multi"))
            let pipeline = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")),
                resolve: { _, scope in
                    if ambiguous || scope.mailboxName == "Second" { return VerifiedMail(accountID: scope.accountID, localID: "one") }
                    return nil
                }, model: { _ in fake })
            let scopes = try ["First", "Second"].map { try AccountScope(accountID: $0, accountName: $0, mailboxName: $0) }
            try await pipeline.updateSettings { $0.scopes = scopes; $0.permission = CapturePermission(); $0.executable = "/fake/dsh" }
            try pipeline.inbox.publish(try await capture(pipeline)); try await pipeline.pump()
            let item = try unwrap(try await store.records().first)
            XCTAssertEqual(item.state, ambiguous ? .needsReview : .draftReady)
            if ambiguous { XCTAssertEqual(item.error, "identityAmbiguous") }
            else { XCTAssertEqual(item.scopeID, scopes[1].id) }
            let count = await fake.calls; XCTAssertEqual(count, ambiguous ? 0 : 1)
        }
    }

    func testLegacySettingsAndMultipleSelectionPersistSeparately() async throws {
        let scope = try AccountScope(accountID: "a", accountName: "Synthetic", mailboxName: "INBOX")
        var legacy = PipelineSettings(); legacy.scope = scope
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        object.removeValue(forKey: "scopes")
        object.removeValue(forKey: "replyInstructions")
        let decoded = try JSONDecoder().decode(PipelineSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.replyInstructions)
        XCTAssertEqual(decoded.authorizedScopes, [scope])
        let store = try PipelineStore(directory: temporary()); try await store.saveSettings(decoded)
        var draft = OnboardingDraft(); draft.selectedScopes = [scope, try AccountScope(accountID: "b", accountName: "Other", mailboxName: "INBOX")]
        try await store.saveOnboarding(draft)
        let selectionCount = try await store.onboarding().selections.count
        let activeScopes = try await store.settings().authorizedScopes
        XCTAssertEqual(selectionCount, 2)
        XCTAssertEqual(activeScopes, [scope])
    }

    func testReplyInstructionsPersistWithoutChangingCaptureAuthorization() async throws {
        let directory = try temporary()
        let instructions = String(repeating: "e\u{301}", count: ReplyDraftRequest.maxReplyInstructionLength / 2)
        var active = PipelineSettings()
        active.permission = CapturePermission(delivery: .mailKit)
        active.paused = true
        do {
            let store = try PipelineStore(directory: directory)
            try await store.saveSettings(active)
            try await store.saveReplyInstructions(instructions)
            do { try await store.saveReplyInstructions(instructions + "!"); XCTFail("oversize instructions") } catch {}
        }
        let reopened = try PipelineStore(directory: directory)
        let saved = try await reopened.settings()
        XCTAssertEqual(saved.replyInstructions, instructions)
        XCTAssertEqual(saved.revision, active.revision)
        XCTAssertEqual(saved.permission, active.permission)
        XCTAssertTrue(saved.paused)
        try await reopened.saveReplyInstructions("  \n\t  ")
        let cleared = try await reopened.settings().replyInstructions
        XCTAssertNil(cleared)
    }

    func testPersistentImportDedupAndDraft() async throws {
        let root = try temporary(), fake = FakeReplyModel()
        var pipeline: ReplyPipeline? = try await setup(root, fake: fake)
        let input = try await capture(pipeline!)
        try pipeline!.inbox.publish(input)
        try await pipeline!.importInbox()
        try pipeline!.inbox.publish(input) // deletion-before-crash replay of the same ingest
        try await pipeline!.importInbox()
        let countAfterDedup = try await pipeline!.store.records().count
        XCTAssertEqual(countAfterDedup, 1)
        pipeline = nil
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let resumed = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")),
            resolve: { _, scope in VerifiedMail(accountID: scope.accountID, localID: "one") }, model: { _ in fake })
        try await resumed.pump()
        let first = try await store.records().first
        XCTAssertEqual(first?.state, .draftReady)
        XCTAssertNotNil(first?.draft)
        try resumed.inbox.publish(try await capture(resumed)) // a separate callback for the same account/message/content
        try await resumed.pump()
        let finalCount = try await store.records().count
        XCTAssertEqual(finalCount, 1)
        let count = await fake.calls; XCTAssertEqual(count, 1)
    }

    func testPauseRevokeAndUnknownAccountPreventCalls() async throws {
        let root = try temporary(), fake = FakeReplyModel()
        let pipeline = try await setup(root, fake: fake)
        try pipeline.inbox.publish(try await capture(pipeline))
        try await pipeline.updateSettings { $0.paused = true }
        try await pipeline.pump()
        let pausedState = try await pipeline.store.records().first?.state
        XCTAssertEqual(pausedState, .awaitingAccount)
        try await pipeline.updateSettings { $0.paused = false; $0.scope = nil }
        try await pipeline.pump()
        let count = await fake.calls; XCTAssertEqual(count, 0)
        try await pipeline.updateSettings { $0.permission = nil }
        try await pipeline.pump()
        let revokedState = try await pipeline.store.records().first?.state
        XCTAssertEqual(revokedState, .cancelled)
    }

    func testRestartDoesNotReplayUnknownCallAndWriterLock() async throws {
        let root = try temporary()
        var pipeline: ReplyPipeline? = try await setup(root)
        try pipeline!.inbox.publish(try await capture(pipeline!)); try await pipeline!.importInbox()
        var item = try unwrap(try await pipeline!.store.records().first)
        item.state = .triaging; try await pipeline!.store.save(item)
        XCTAssertThrowsError(try PipelineStore(directory: root.appendingPathComponent("state")))
        pipeline = nil
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let recovered = try await store.records().first
        XCTAssertEqual(recovered?.state, .needsReview)
        XCTAssertEqual(recovered?.error, "interrupted")
    }

    func testSymlinkAndUnsupportedMIME() async throws {
        let root = try temporary(), pipeline = try await setup(root)
        let target = root.appendingPathComponent("private")
        try Data("secret".utf8).write(to: target)
        let link = pipeline.inbox.directory.appendingPathComponent("bad.capture")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try await pipeline.importInbox()
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let recordedIssue = try await pipeline.store.issue()
        XCTAssertEqual(recordedIssue, "invalidCapture")
        XCTAssertThrowsError(try PlainMailBody.decode(Data("Content-Type: multipart/mixed; boundary=x\r\n\r\nbody".utf8))) { error in
            XCTAssertEqual(error as? MailBodyRejection, .malformedMIME)
        }
        XCTAssertEqual(try PlainMailBody.decode(Data("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nPlease=20reply".utf8)), "Please reply")
        let html = Data("Content-Type: text/html; charset=utf-8\r\n\r\n<p>Please reply</p>".utf8)
        let imported = InboundCapture(permissionID: try unwrap(try await pipeline.store.settings().permission).id,
            subject: "Synthetic", messageID: "html@example.com", raw: html)
        try pipeline.inbox.publish(imported)
        try await pipeline.importInbox()
        let record = try unwrap(try await pipeline.store.records().first { $0.messageID == "html@example.com" })
        XCTAssertEqual(record.input.body, "Please reply")
        XCTAssertEqual(record.state, .awaitingAccount)
        XCTAssertNil(record.error)
        let sealed = Data("Content-Type: application/pkcs7-mime; smime-type=enveloped-data\r\n\r\nsecret".utf8)
        try pipeline.inbox.publish(InboundCapture(permissionID: imported.permissionID, subject: "Synthetic", messageID: "sealed@example.com", raw: sealed))
        try await pipeline.importInbox()
        let rejected = try unwrap(try await pipeline.store.records().first { $0.messageID == "sealed@example.com" })
        XCTAssertEqual(rejected.state, .needsReview)
        XCTAssertEqual(rejected.error, MailBodyRejection.encryptedContent.rawValue)
    }
}

actor PausingReplyModel: ReplyModelRunning {
    let fake = FakeReplyModel()
    let pause: @Sendable () async throws -> Void
    init(pause: @escaping @Sendable () async throws -> Void) { self.pause = pause }
    func run(_ task: ReplyModelTask, route: AccountRoute, authorize: @escaping @Sendable () async throws -> Void) async throws -> ReplyModelOutput {
        let output = try await fake.run(task, route: route, authorize: authorize)
        try await pause()
        return output
    }
}

extension PipelineTests {
    func testPauseDuringDraftDiscardsOutput() async throws {
        let root = try temporary()
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let fake = PausingReplyModel { var settings = try await store.settings(); settings.paused = true; try await store.saveSettings(settings) }
        let pipeline = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")),
            resolve: { _, scope in VerifiedMail(accountID: scope.accountID, localID: "one") }, model: { _ in fake })
        try await pipeline.updateSettings { $0.executable = "/fake/dsh" }
        let id = try await pipeline.enqueueSynthetic()
        try await pipeline.pump()
        let record = try unwrap(try await store.record(id))
        XCTAssertEqual(record.state, .needsReview)
        XCTAssertEqual(record.error, "paused")
        XCTAssertNil(record.draftData)
        XCTAssertEqual(record.runs.count, 1)
        XCTAssertEqual(record.runs.first?.inputTokens, 10)
        try await pipeline.updateSettings { $0.paused = false }
        try await pipeline.pump()
        let count = await fake.fake.calls; XCTAssertEqual(count, 1)
    }

    func testBodyReentryAndResumeFromLegacyDraftQueued() async throws {
        let root = try temporary(), fake = FakeReplyModel()
        var pipeline: ReplyPipeline? = try await setup(root, fake: fake)
        let full = try await capture(pipeline!)
        let metadata = InboundCapture(permissionID: full.permissionID, subject: full.subject, messageID: full.messageID, raw: nil)
        try pipeline!.inbox.publish(metadata); try await pipeline!.importInbox()
        let waitingState = try await pipeline!.store.records().first?.state
        XCTAssertEqual(waitingState, .awaitingBody)
        try pipeline!.inbox.publish(full); try await pipeline!.importInbox()
        let countAfterMerge = try await pipeline!.store.records().count
        XCTAssertEqual(countAfterMerge, 1)
        var item = try unwrap(try await pipeline!.store.records().first)
        item.accountID = "test"; item.localID = "one"; item.revision = try await pipeline!.store.settings().revision
        item.state = .draftQueued
        try await pipeline!.store.save(item); pipeline = nil
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let resumed = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, _ in nil }, model: { _ in fake })
        try await resumed.pump()
        let finalState = try await store.record(item.id)?.state
        XCTAssertEqual(finalState, .draftReady)
        let count = await fake.calls; XCTAssertEqual(count, 1)
    }

    func testRevokedCaptureIsNotImportedAndBodyRequestIsOneShot() async throws {
        let pipeline = try await setup(try temporary())
        let capture = try await capture(pipeline)
        let permission = try unwrap(try await pipeline.store.settings().permission)
        XCTAssertTrue(try pipeline.inbox.claimBody(permission: permission, subject: capture.subject, messageID: capture.messageID))
        XCTAssertFalse(try pipeline.inbox.claimBody(permission: permission, subject: capture.subject, messageID: capture.messageID))
        try pipeline.inbox.publish(capture)
        try await pipeline.updateSettings { $0.permission = nil }
        try await pipeline.importInbox()
        let empty = try await pipeline.store.records().isEmpty
        XCTAssertTrue(empty)
        XCTAssertTrue(try pipeline.inbox.files().isEmpty)
    }

    func testBodyRejectionCompletesSingleCandidateAndSurvivesRestart() async throws {
        let root = try temporary(), fake = FakeReplyModel()
        var pipeline: ReplyPipeline? = try await setup(root, fake: fake)
        let permission = try unwrap(try await pipeline!.store.settings().permission)
        let header = InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "oversize@example.com", raw: nil)
        let id = try await pipeline!.store.importCapture(header)
        let rejection = InboundCapture(permissionID: permission.id, subject: header.subject, messageID: header.messageID,
            raw: nil, issue: MailBodyRejection.messageTooLarge.rawValue)
        let mergedID = try await pipeline!.store.importCapture(rejection)
        XCTAssertEqual(mergedID, id)
        let count1 = try await pipeline!.store.records().count
        XCTAssertEqual(count1, 1)
        let rejected = try await pipeline!.store.record(id)
        XCTAssertEqual(rejected?.state, .needsReview)
        XCTAssertEqual(rejected?.error, "messageTooLarge")
        // Both prior ingests still map to the same record after a crash/restart.
        pipeline = nil
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let replayHeader = try await store.importCapture(header)
        let replayRejection = try await store.importCapture(rejection)
        XCTAssertEqual(replayHeader, id)
        XCTAssertEqual(replayRejection, id)
        let resumed = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")),
            resolve: { _, _ in XCTFail("Rejected body must not resolve identity"); return nil }, model: { _ in fake })
        try await resumed.pump()
        let count2 = try await store.records().count
        XCTAssertEqual(count2, 1)
        let calls = await fake.calls; XCTAssertEqual(calls, 0)
    }

    func testBodyRejectionDoesNotMergeAmbiguousOrUnrelatedCandidates() async throws {
        let pipeline = try await setup(try temporary())
        let permission = try unwrap(try await pipeline.store.settings().permission)
        for id in ["ambiguous@example.com", "ambiguous@example.com", "other@example.com"] {
            _ = try await pipeline.store.importCapture(InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: id, raw: nil))
        }
        _ = try await pipeline.store.importCapture(InboundCapture(permissionID: permission.id, subject: "Other subject", messageID: "other@example.com", raw: nil))
        let reject = InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "ambiguous@example.com", raw: nil, issue: "messageTooLarge")
        _ = try await pipeline.store.importCapture(reject)
        let records1 = try await pipeline.store.records()
        XCTAssertEqual(records1.filter { $0.state == .awaitingBody }.count, 4)
        XCTAssertEqual(records1.filter { $0.state == .needsReview }.count, 1)
        let unrelated = InboundCapture(permissionID: permission.id, subject: "Changed", messageID: "other@example.com", raw: nil, issue: "messageTooLarge")
        _ = try await pipeline.store.importCapture(unrelated)
        let countAfterUnrelated = try await pipeline.store.records().count
        XCTAssertEqual(countAfterUnrelated, 6)
        let denied = InboundCapture(permissionID: UUID(), subject: "Synthetic", messageID: "other@example.com", raw: nil, issue: "messageTooLarge")
        do { _ = try await pipeline.store.importCapture(denied); XCTFail("revoked permission") } catch {}
        let finalCount = try await pipeline.store.records().count
        XCTAssertEqual(finalCount, 6)
    }

    func testOversizeMailSourceStopsBeforeHarnessAndDoesNotRetry() async throws {
        let root = try temporary(), fake = FakeReplyModel()
        let configured = try await setup(root, fake: fake)
        let pipeline = ReplyPipeline(store: configured.store, inbox: configured.inbox,
            resolve: { _, _ in throw MailBodyRejection.messageTooLarge }, model: { _ in fake })
        try pipeline.inbox.publish(try await capture(pipeline))
        for _ in 0..<2 { try await pipeline.pump() }
        let item = try unwrap(try await pipeline.store.records().first)
        XCTAssertEqual(item.state, .needsReview)
        XCTAssertEqual(item.error, "messageTooLarge")
        XCTAssertNil(item.accountID)
        XCTAssertTrue(item.runs.isEmpty)
        let calls = await fake.calls; XCTAssertEqual(calls, 0)
    }
}

import XCTest
@testable import MailpipeRuntime
import MailpipeCore
import HarnessAdapters

actor FakeReplyModel: ReplyModelRunning {
    private(set) var calls = 0
    let shouldReply: String
    let harness: HarnessKind
    let actualModel: String?
    private var returnsNoReply = false
    func respondWithNoReply() { returnsNoReply = true }
    var afterRun: (@Sendable () async throws -> Void)?
    func setAfterRun(_ action: @escaping @Sendable () async throws -> Void) { afterRun = action }
    init(shouldReply: String = "yes", harness: HarnessKind = .deepseek, actualModel: String? = nil) {
        self.shouldReply = shouldReply; self.harness = harness; self.actualModel = actualModel
    }
    func run(_ task: ReplyModelTask, route: AccountRoute, authorize: @escaping @Sendable () async throws -> Void) async throws -> ReplyModelOutput {
        try route.authorize(harness); try await authorize(); calls += 1
        var object: [String: Any]
        switch task {
        case .triage(let request):
            object = try JSONSerialization.jsonObject(with: ReplySyntheticFixture.decision) as! [String: Any]
            object["request_id"] = request.requestID; object["message_ref"] = request.message.messageRef
            object["should_reply"] = shouldReply; object["evidence"] = []
        case .draft(let request):
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

/// Keep a synthetic Mail read outstanding while a separate main-actor task uses the workbench.
@MainActor
private final class DelayedMailRead {
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
    func testAddressLoadPreservesConcurrentEditsAndHonorsRevocation() async throws {
        let root = try temporary()
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let raw = Data("From: sender@example.com\nTo: recipient@example.com\n\nBody".utf8)
        var settings = PipelineSettings()
        settings.permission = CapturePermission()
        settings.scope = try AccountScope(accountID: "test", accountName: "Test", mailboxName: "INBOX")
        try store.saveSettings(settings)
        let id = try store.importCapture(InboundCapture(permissionID: settings.permission!.id, subject: "Synthetic", messageID: "test@example.com", raw: raw))
        var item = try XCTUnwrap(store.record(id)); item.correspondents = nil; item.displayBody = nil; try store.save(item)
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { item, scope in
            var current = try XCTUnwrap(store.record(item.id))
            current.editedBody = "Concurrent edit"; current.state = .cancelled
            try store.save(current)
            return VerifiedMail(accountID: scope.accountID, localID: "1", source: raw)
        })
        try await pipeline.loadCorrespondents(id, includeBody: true)
        item = try XCTUnwrap(store.record(id))
        XCTAssertEqual(item.displayBody, "Body")
        XCTAssertEqual(item.editedBody, "Concurrent edit")
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertEqual(item.correspondents?.sender, "sender@example.com")
        item.correspondents = nil; try store.save(item)
        let revoked = ReplyPipeline(store: store, inbox: inbox, resolve: { _, scope in
            var changed = try store.settings(); changed.permission = nil; changed.revision = UUID()
            try store.saveSettings(changed)
            return VerifiedMail(accountID: scope.accountID, localID: "1", source: raw)
        })
        try await revoked.loadCorrespondents(id)
        XCTAssertNil(try store.record(id)?.correspondents)
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
        try pipeline.updateSettings {
            $0.permission = CapturePermission(); $0.paused = true
            $0.scope = try? AccountScope(accountID: "test", accountName: "account@example.com", mailboxName: "INBOX")
        }
        let permission = try XCTUnwrap(store.settings().permission)
        let id = try store.importCapture(InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "test@example.com", raw: raw))
        var old = try XCTUnwrap(store.record(id))
        XCTAssertEqual(old.correspondents?.recipients, ["alias@example.com"])
        old.correspondents = nil; old.editedBody = "Keep my edit"
        try store.save(old)
        try await pipeline.loadCorrespondents(id)
        var filled = try XCTUnwrap(store.record(id))
        XCTAssertEqual(filled.correspondents?.sender, "sender@example.com")
        XCTAssertEqual(filled.correspondents?.recipients, ["alias@example.com"])
        XCTAssertEqual(filled.editedBody, old.editedBody)
        XCTAssertEqual(filled.state, old.state)
        XCTAssertEqual(filled.input, old.input)
        XCTAssertTrue(filled.runs.isEmpty)
        filled.correspondents = nil; filled.sourceDigest = "incorrect"
        try store.save(filled)
        try await pipeline.loadCorrespondents(id)
        XCTAssertNil(try store.record(id)?.correspondents)
        filled.sourceDigest = mailSourceDigest(raw); filled.excludedFromAuthorizedInbox = true
        try store.save(filled)
        try await pipeline.loadCorrespondents(id)
        XCTAssertNil(try store.record(id)?.correspondents)
        let calls = await fake.calls; XCTAssertEqual(calls, 0)
    }
    func testOutsideInboxCaptureIsExcludedAndExistingRecordIsPreserved() async throws {
        let root = try temporary()
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let fake = FakeReplyModel()
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in XCTFail("Must not read source"); return nil },
            inAuthorizedInbox: { _, _, _ in false }, model: { _ in fake })
        try pipeline.updateSettings {
            $0.permission = CapturePermission(); $0.executable = "/fake/dsh"
            $0.scope = try? AccountScope(accountID: "test", accountName: "test", mailboxName: "INBOX")
        }
        let permission = try XCTUnwrap(store.settings().permission)
        let existing = InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "old@example.com", raw: nil)
        let id = try store.importCapture(existing)
        try inbox.publish(InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "new@example.com", raw: nil))
        try await pipeline.pump()
        XCTAssertEqual(try store.records().count, 1)
        let kept = try XCTUnwrap(store.record(id))
        XCTAssertEqual(kept.state, .awaitingBody)
        XCTAssertEqual(kept.excludedFromAuthorizedInbox, true)
        XCTAssertEqual(kept.input.body, "")
        XCTAssertTrue(try inbox.files().isEmpty)
        let calls = await fake.calls; XCTAssertEqual(calls, 0)
    }
    func testUnknownInboxMembershipRetainsCaptureWithoutDispatch() async throws {
        let root = try temporary()
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in XCTFail("No source read"); return nil }, inAuthorizedInbox: { _, _, _ in nil })
        try pipeline.updateSettings { $0.permission = CapturePermission() }
        let permission = try XCTUnwrap(store.settings().permission)
        try inbox.publish(InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "delayed@example.com", raw: nil))
        try await pipeline.pump()
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertEqual(try inbox.files().count, 1)
    }
    func testUnknownExistingRecordPreservesBodyAndDisplayWithoutDispatch() async throws {
        let root = try temporary()
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in XCTFail("Unknown must not read source"); return nil }, inAuthorizedInbox: { _, _, _ in nil })
        try pipeline.updateSettings { $0.permission = CapturePermission(); $0.executable = "/fake/dsh" }
        let permission = try XCTUnwrap(store.settings().permission)
        let raw = Data("Subject: Synthetic\r\nMessage-ID: <existing@example.com>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nExisting body".utf8)
        let id = try store.importCapture(InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "existing@example.com", raw: raw))
        var item = try XCTUnwrap(store.record(id)); item.excludedFromAuthorizedInbox = true; try store.save(item)
        try await pipeline.pump()
        item = try XCTUnwrap(store.record(id))
        XCTAssertNil(item.excludedFromAuthorizedInbox)
        XCTAssertEqual(item.input.body, "Existing body")
        XCTAssertTrue(item.canDisplayInWorkbench)
        XCTAssertTrue(item.runs.isEmpty)
    }
    func testMissingIDsDoNotConsumeMembershipBudget() async throws {
        let root = try temporary()
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in nil }, inAuthorizedInbox: { _, _, _ in true })
        try pipeline.updateSettings { $0.permission = CapturePermission() }
        let permission = try XCTUnwrap(store.settings().permission)
        for _ in 0..<2 { try inbox.publish(InboundCapture(permissionID: permission.id, subject: "Missing", messageID: nil, raw: nil)) }
        try inbox.publish(InboundCapture(permissionID: permission.id, subject: "Valid", messageID: "valid@example.com", raw: nil))
        try await pipeline.importInbox()
        XCTAssertEqual(try store.records().map(\.messageID), ["valid@example.com"])
        XCTAssertEqual(try inbox.files().count, 2)
    }
    func testScopeTimeoutDoesNotStarveFollowingCapture() async throws {
        let root = try temporary()
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in nil }, inAuthorizedInbox: { id, _, _ in
            if id == "timeout@example.com" { throw PipelineError.storage }; return true
        })
        try pipeline.updateSettings { $0.permission = CapturePermission() }
        let permission = try XCTUnwrap(store.settings().permission)
        try inbox.publish(InboundCapture(permissionID: permission.id, subject: "Timeout", messageID: "timeout@example.com", raw: nil))
        try inbox.publish(InboundCapture(permissionID: permission.id, subject: "Valid", messageID: "valid@example.com", raw: nil))
        try await pipeline.importInbox()
        XCTAssertEqual(try store.records().map(\.messageID), ["valid@example.com"])
        XCTAssertEqual(try inbox.files().count, 1)
        try await pipeline.importInbox()
    }
    func testPendingCaptureCheckYieldsToWorkbenchAndIgnoresStaleExclusion() async throws {
        for change in ["pause", "scope", "revoke", "cancelTask"] {
            let configured = try setup(try temporary())
            let delayed = DelayedMailRead()
            let pipeline = ReplyPipeline(store: configured.store, inbox: configured.inbox,
                resolve: { _, _ in XCTFail("No source read"); return nil },
                inAuthorizedInbox: { _, _, _ in await delayed.waitForReply(); return false })
            try pipeline.inbox.publish(try capture(pipeline))
            let importing = Task { try await pipeline.importInbox() }
            let status = await XCTWaiter.fulfillment(of: [delayed.started], timeout: 3)
            XCTAssertEqual(status, .completed, change)
            try await pipeline.pump()
            switch change {
            case "pause": try pipeline.updateSettings { $0.paused = true }
            case "scope": try pipeline.updateSettings { $0.scope = nil }
            case "revoke": try pipeline.updateSettings { $0.permission = nil }
            default: importing.cancel()
            }
            delayed.finish()
            do { try await importing.value; XCTAssertNotEqual(change, "cancelTask") }
            catch is CancellationError { XCTAssertEqual(change, "cancelTask") }
            XCTAssertEqual(delayed.calls, 1, change)
            XCTAssertTrue(try pipeline.store.records().isEmpty, change)
            XCTAssertEqual(try pipeline.inbox.files().count, 1, change)
        }
    }

    func testChangingPermissionDoesNotQueryNewMailboxesWithOldRecord() async throws {
        let configured = try setup(try temporary())
        let pipeline = ReplyPipeline(store: configured.store, inbox: configured.inbox,
            resolve: { _, _ in XCTFail("Revoked identity lookup"); return nil },
            inAuthorizedInbox: { _, _, _ in XCTFail("Revoked membership lookup"); return true })
        let id = try pipeline.store.importCapture(try capture(pipeline))
        try pipeline.updateSettings { $0.permission = CapturePermission() }
        try await pipeline.pump()
        XCTAssertEqual(try pipeline.store.record(id)?.state, .cancelled)
        XCTAssertEqual(try pipeline.store.record(id)?.error, "revoked")
    }

    func testRecordMembershipDoesNotOverwriteWorkbenchEditDiscardOrCancel() async throws {
        let configured = try setup(try temporary())
        let delayed = DelayedMailRead()
        let fake = FakeReplyModel()
        let pipeline = ReplyPipeline(store: configured.store, inbox: configured.inbox,
            resolve: { _, _ in XCTFail("Cancelled mail must not resolve"); return nil },
            inAuthorizedInbox: { _, _, _ in await delayed.waitForReply(); return true }, model: { _ in fake })
        let id = try pipeline.store.importCapture(try capture(pipeline))
        let pumping = Task { try await pipeline.pump() }
        let status = await XCTWaiter.fulfillment(of: [delayed.started], timeout: 3)
        XCTAssertEqual(status, .completed)
        XCTAssertTrue(pipeline.pumping)
        try pipeline.cancel(id)
        try pipeline.store.saveEdits(id, subject: "Edited", body: "Keep these edits")
        try pipeline.store.discard(id)
        delayed.finish()
        try await pumping.value
        XCTAssertFalse(pipeline.pumping)
        let current = try XCTUnwrap(pipeline.store.record(id))
        XCTAssertEqual(current.editedBody, "Keep these edits")
        XCTAssertNotNil(current.discardedAt)
        XCTAssertEqual(current.state, .cancelled)
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }

    func testLateIdentityResultOrErrorCannotUndoCancellation() async throws {
        for lookupFails in [false, true] {
            let configured = try setup(try temporary())
            let delayed = DelayedMailRead()
            let fake = FakeReplyModel()
            let pipeline = ReplyPipeline(store: configured.store, inbox: configured.inbox, resolve: { _, scope in
                await delayed.waitForReply()
                if lookupFails { throw PipelineError.storage }
                return VerifiedMail(accountID: scope.accountID, localID: "one")
            }, model: { _ in fake })
            let id = try pipeline.store.importCapture(try capture(pipeline))
            let pumping = Task { try await pipeline.pump() }
            let status = await XCTWaiter.fulfillment(of: [delayed.started], timeout: 3)
            XCTAssertEqual(status, .completed)
            try pipeline.cancel(id)
            delayed.finish()
            try await pumping.value
            let current = try XCTUnwrap(pipeline.store.record(id))
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
    func setup(_ root: URL, fake: FakeReplyModel = FakeReplyModel()) throws -> ReplyPipeline {
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, scope in VerifiedMail(accountID: scope.accountID, localID: "one") }, model: { _ in fake })
        try pipeline.updateSettings {
            $0.executable = "/fake/dsh"
            $0.permission = CapturePermission()
            $0.scope = try? AccountScope(accountID: "test", accountName: "test", mailboxName: "INBOX")
        }
        return pipeline
    }
    func capture(_ pipeline: ReplyPipeline) throws -> InboundCapture {
        InboundCapture(permissionID: try XCTUnwrap(pipeline.store.settings().permission).id,
            subject: "Synthetic", messageID: "test@example.com", raw: Data("Content-Type: text/plain\r\n\r\nPlease reply".utf8))
    }
    func testEditsDiscardUndoAndLegacyPayload() async throws {
        let pipeline = try setup(temporary())
        try pipeline.inbox.publish(try capture(pipeline)); try await pipeline.pump()
        let item = try XCTUnwrap(pipeline.store.records().first)
        try pipeline.store.saveEdits(item.id, subject: "Edited", body: "Local reply")
        let now = Date()
        try pipeline.store.discard(item.id, now: now)
        XCTAssertNotNil(try pipeline.store.record(item.id)?.discardedAt)
        try pipeline.store.restoreDiscard(item.id, now: now.addingTimeInterval(10))
        XCTAssertEqual(try pipeline.store.record(item.id)?.displayedBody, "Local reply")
        XCTAssertNil(try pipeline.store.record(item.id)?.discardedAt)
        try pipeline.store.discard(item.id, now: now)
        XCTAssertThrowsError(try pipeline.store.restoreDiscard(item.id, now: now.addingTimeInterval(16)))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        for key in ["editedSubject", "editedBody", "discardedAt", "regenerationCount"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(StoredReply.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.editedBody)
        XCTAssertEqual(legacy.displayedBody, item.draft?.body)
    }
    func testReplyBodyEditsSurviveStoreReopen() async throws {
        let root = try temporary()
        var pipeline: ReplyPipeline? = try setup(root)
        try pipeline!.inbox.publish(try capture(pipeline!)); try await pipeline!.pump()
        let id = try XCTUnwrap(pipeline!.store.records().first).id
        try pipeline!.store.saveEdits(id, subject: "Unchanged subject", body: "Persisted reply only")
        pipeline = nil
        let reopened = try PipelineStore(directory: root.appendingPathComponent("state"))
        XCTAssertEqual(try reopened.record(id)?.displayedBody, "Persisted reply only")
    }
    func testRegenerationIsBoundedAndReplacesBody() async throws {
        let fake = FakeReplyModel(), pipeline = try setup(temporary(), fake: fake)
        try pipeline.inbox.publish(try capture(pipeline)); try await pipeline.pump()
        let id = try XCTUnwrap(pipeline.store.records().first).id
        try pipeline.store.saveEdits(id, subject: "My subject", body: "My local edit")
        for _ in 0..<3 {
            try pipeline.regenerate(id)
            XCTAssertThrowsError(try pipeline.regenerate(id))
            try await pipeline.pump()
            let saved = try XCTUnwrap(pipeline.store.record(id))
            XCTAssertEqual(saved.displayedBody, try XCTUnwrap(saved.draft).body)
            XCTAssertEqual(saved.displayedSubject, "My subject")
            XCTAssertFalse(saved.hasDraftCandidate)
            XCTAssertEqual(try pipeline.store.record(id)?.state, .draftReady)
        }
        XCTAssertThrowsError(try pipeline.regenerate(id))
        let count = await fake.calls; XCTAssertEqual(count, 4)
        try pipeline.store.discard(id)
        XCTAssertThrowsError(try pipeline.regenerate(id))
    }
    func testRegenerationFailureAndCancelKeepLocalEdit() async throws {
        let fake = FakeReplyModel(), pipeline = try setup(temporary(), fake: fake)
        try pipeline.inbox.publish(try capture(pipeline)); try await pipeline.pump()
        let id = try XCTUnwrap(pipeline.store.records().first).id
        try pipeline.store.saveEdits(id, subject: "Edited subject", body: "Keep this reply")
        await fake.setAfterRun { throw MailpipeError.invalidOutput }
        try pipeline.regenerate(id); try await pipeline.pump()
        XCTAssertEqual(try pipeline.store.record(id)?.state, .needsReview)
        XCTAssertEqual(try pipeline.store.record(id)?.displayedBody, "Keep this reply")
        try pipeline.regenerate(id); try pipeline.cancel(id); try await pipeline.pump()
        XCTAssertEqual(try pipeline.store.record(id)?.state, .cancelled)
        XCTAssertEqual(try pipeline.store.record(id)?.displayedBody, "Keep this reply")
    }
    func testRegenerationUsesCurrentServiceLevel() async throws {
        let pipeline = try setup(temporary())
        try pipeline.inbox.publish(try capture(pipeline))
        try await pipeline.pump()
        let id = try XCTUnwrap(pipeline.store.records().first).id
        try pipeline.store.saveEdits(id, subject: "Edited", body: "Keep local reply")
        try pipeline.updateSettings { $0.level = .l1 }
        try pipeline.regenerate(id); try await pipeline.pump()
        let item = try XCTUnwrap(pipeline.store.record(id))
        XCTAssertEqual(item.level, .l1)
        XCTAssertEqual(item.state, .draftReady)
        XCTAssertEqual(item.runs.count, 2)
        XCTAssertNotNil(item.draft)
        XCTAssertEqual(item.displayedBody, item.draft?.body)
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
            input: ReplySyntheticFixture.triage.message, state: .queued)
        queued.manualExecutable = "/fake/dsh"
        do {
            let store = try PipelineStore(directory: directory)
            var settings = PipelineSettings()
            settings.executable = "/fake/dsh"; settings.paused = true
            try store.saveSettings(settings)
            try store.save(archived); try store.save(queued)
        }
        let store = try PipelineStore(directory: directory)
        let fake = FakeReplyModel()
        let pipeline = ReplyPipeline(store: store, inbox: inbox,
            resolve: { _, _ in XCTFail("Archived manual records cannot read Mail"); return nil }, model: { _ in fake })
        XCTAssertEqual(try store.record(queued.id)?.state, .cancelled)
        let history = try XCTUnwrap(store.record(archived.id))
        XCTAssertEqual(history.state, .draftReady)
        XCTAssertTrue(history.canDisplayInWorkbench)
        XCTAssertEqual(history.draft?.body, "Received.")
        XCTAssertEqual(history.displayedBody, "Preserved edit")
        XCTAssertEqual(history.draftData, archived.draftData)
        try store.saveEdits(history.id, subject: history.displayedSubject, body: "Updated edit")
        try pipeline.updateSettings { $0.paused = false; $0.permission = permission }
        XCTAssertFalse(history.canRequestRegeneration(settings: try store.settings()))
        XCTAssertThrowsError(try pipeline.regenerate(history.id))
        try await pipeline.loadCorrespondents(history.id, includeBody: true)
        try await pipeline.pump()
        XCTAssertEqual(try store.record(history.id)?.displayedBody, "Updated edit")
        let calls = await fake.calls; XCTAssertEqual(calls, 0)
    }
    func testCancelledRunMustFinishBeforeRegeneration() async throws {
        let pipeline = try setup(temporary())
        try pipeline.inbox.publish(try capture(pipeline)); try await pipeline.pump()
        var item = try XCTUnwrap(pipeline.store.records().first)
        item.state = .cancelled
        item.runs[item.runs.count - 1].finishedAt = nil
        try pipeline.store.save(item)
        XCTAssertThrowsError(try pipeline.regenerate(item.id))
    }
    func testRegenerationRespectsPauseAndRevocation() async throws {
        let pipeline = try setup(temporary())
        try pipeline.inbox.publish(try capture(pipeline)); try await pipeline.pump()
        let id = try XCTUnwrap(pipeline.store.records().first).id
        try pipeline.updateSettings { $0.paused = true }
        XCTAssertThrowsError(try pipeline.regenerate(id))
        try pipeline.updateSettings { $0.paused = false; $0.permission = nil }
        XCTAssertThrowsError(try pipeline.regenerate(id))
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
            try pipeline.updateSettings { $0.scopes = scopes; $0.permission = CapturePermission(); $0.executable = "/fake/dsh" }
            try pipeline.inbox.publish(try capture(pipeline)); try await pipeline.pump()
            let item = try XCTUnwrap(store.records().first)
            XCTAssertEqual(item.state, ambiguous ? .needsReview : .draftReady)
            if ambiguous { XCTAssertEqual(item.error, "identityAmbiguous") }
            else { XCTAssertEqual(item.scopeID, scopes[1].id) }
            let count = await fake.calls; XCTAssertEqual(count, ambiguous ? 0 : 1)
        }
    }
    func testLegacySettingsAndMultipleSelectionPersistSeparately() throws {
        let scope = try AccountScope(accountID: "a", accountName: "Synthetic", mailboxName: "INBOX")
        var legacy = PipelineSettings(); legacy.scope = scope
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        object.removeValue(forKey: "scopes")
        let decoded = try JSONDecoder().decode(PipelineSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.authorizedScopes, [scope])
        let store = try PipelineStore(directory: temporary()); try store.saveSettings(decoded)
        var draft = OnboardingDraft(); draft.selectedScopes = [scope, try AccountScope(accountID: "b", accountName: "Other", mailboxName: "INBOX")]
        try store.saveOnboarding(draft)
        XCTAssertEqual(try store.onboarding().selections.count, 2)
        XCTAssertEqual(try store.settings().authorizedScopes, [scope])
    }
    func testPersistentImportDedupAndL2() async throws {
        let root = try temporary(), fake = FakeReplyModel()
        var pipeline: ReplyPipeline? = try setup(root, fake: fake)
        let input = try capture(pipeline!)
        try pipeline!.inbox.publish(input)
        try await pipeline!.importInbox()
        try pipeline!.inbox.publish(input) // deletion-before-crash replay of the same ingest
        try await pipeline!.importInbox()
        XCTAssertEqual(try pipeline!.store.records().count, 1)
        pipeline = nil
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let resumed = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")),
            resolve: { _, scope in VerifiedMail(accountID: scope.accountID, localID: "one") }, model: { _ in fake })
        try await resumed.pump()
        XCTAssertEqual(try store.records().first?.state, .draftReady)
        XCTAssertNotNil(try store.records().first?.draft)
        try resumed.inbox.publish(try capture(resumed)) // a separate callback for the same account/message/content
        try await resumed.pump()
        XCTAssertEqual(try store.records().count, 1)
        let count = await fake.calls; XCTAssertEqual(count, 1)
    }
    func testPauseRevokeAndUnknownAccountPreventCalls() async throws {
        let root = try temporary(), fake = FakeReplyModel()
        let pipeline = try setup(root, fake: fake)
        try pipeline.inbox.publish(try capture(pipeline))
        try pipeline.updateSettings { $0.paused = true }
        try await pipeline.pump()
        XCTAssertEqual(try pipeline.store.records().first?.state, .awaitingAccount)
        try pipeline.updateSettings { $0.paused = false; $0.scope = nil }
        try await pipeline.pump()
        let count = await fake.calls; XCTAssertEqual(count, 0)
        try pipeline.updateSettings { $0.permission = nil }
        try await pipeline.pump()
        XCTAssertEqual(try pipeline.store.records().first?.state, .cancelled)
    }
    func testReplyRequestsUseOneDraftCallAtEveryServiceLevel() async throws {
        for level in [ServiceLevel.l0, .l1, .l2] {
            let fake = FakeReplyModel(shouldReply: "no"), pipeline = try setup(try temporary(), fake: fake)
            try pipeline.updateSettings { $0.level = level }
            try pipeline.inbox.publish(try capture(pipeline)); try await pipeline.pump()
            let item = try XCTUnwrap(pipeline.store.records().first)
            XCTAssertEqual(item.state, .draftReady)
            XCTAssertEqual(item.runs.map(\.destination.taskKind), [.draft])
            XCTAssertNil(item.decisionData)
            XCTAssertNotNil(item.draft)
        }
    }
    func testRestartDoesNotReplayUnknownCallAndWriterLock() async throws {
        let root = try temporary()
        var pipeline: ReplyPipeline? = try setup(root)
        try pipeline!.inbox.publish(try capture(pipeline!)); try await pipeline!.importInbox()
        var item = try XCTUnwrap(pipeline!.store.records().first)
        item.state = .triaging; try pipeline!.store.save(item)
        XCTAssertThrowsError(try PipelineStore(directory: root.appendingPathComponent("state")))
        pipeline = nil
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        XCTAssertEqual(try store.records().first?.state, .needsReview)
        XCTAssertEqual(try store.records().first?.error, "interrupted")
    }
    func testSymlinkAndUnsupportedMIME() async throws {
        let root = try temporary(), pipeline = try setup(root)
        let target = root.appendingPathComponent("private")
        try Data("secret".utf8).write(to: target)
        let link = pipeline.inbox.directory.appendingPathComponent("bad.capture")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try await pipeline.importInbox()
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try pipeline.store.issue(), "invalidCapture")
        XCTAssertThrowsError(try PlainMailBody.decode(Data("Content-Type: multipart/mixed; boundary=x\r\n\r\nbody".utf8))) { error in
            XCTAssertEqual(error as? MailBodyRejection, .malformedMIME)
        }
        XCTAssertEqual(try PlainMailBody.decode(Data("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nPlease=20reply".utf8)), "Please reply")
        let html = Data("Content-Type: text/html; charset=utf-8\r\n\r\n<p>Please reply</p>".utf8)
        let imported = InboundCapture(permissionID: try XCTUnwrap(pipeline.store.settings().permission).id,
            subject: "Synthetic", messageID: "html@example.com", raw: html)
        try pipeline.inbox.publish(imported)
        try await pipeline.importInbox()
        let record = try XCTUnwrap(pipeline.store.records().first { $0.messageID == "html@example.com" })
        XCTAssertEqual(record.input.body, "Please reply")
        XCTAssertEqual(record.state, .awaitingAccount)
        XCTAssertNil(record.error)
        let sealed = Data("Content-Type: application/pkcs7-mime; smime-type=enveloped-data\r\n\r\nsecret".utf8)
        try pipeline.inbox.publish(InboundCapture(permissionID: imported.permissionID, subject: "Synthetic", messageID: "sealed@example.com", raw: sealed))
        try await pipeline.importInbox()
        let rejected = try XCTUnwrap(pipeline.store.records().first { $0.messageID == "sealed@example.com" })
        XCTAssertEqual(rejected.state, .needsReview)
        XCTAssertEqual(rejected.error, MailBodyRejection.encryptedContent.rawValue)
    }
}

actor PausingReplyModel: ReplyModelRunning {
    let fake = FakeReplyModel()
    let pause: @MainActor @Sendable () throws -> Void
    init(pause: @escaping @MainActor @Sendable () throws -> Void) { self.pause = pause }
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
        let fake = PausingReplyModel { var settings = try store.settings(); settings.paused = true; try store.saveSettings(settings) }
        let pipeline = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")),
            resolve: { _, scope in VerifiedMail(accountID: scope.accountID, localID: "one") }, model: { _ in fake })
        try pipeline.updateSettings { $0.executable = "/fake/dsh" }
        let id = try pipeline.enqueueSynthetic()
        try await pipeline.pump()
        let record = try XCTUnwrap(store.record(id))
        XCTAssertEqual(record.state, .needsReview)
        XCTAssertEqual(record.error, "paused")
        XCTAssertNil(record.draftData)
        XCTAssertEqual(record.runs.count, 1)
        XCTAssertEqual(record.runs.first?.inputTokens, 10)
        try pipeline.updateSettings { $0.paused = false }
        try await pipeline.pump()
        let count = await fake.fake.calls; XCTAssertEqual(count, 1)
    }
    func testBodyReentryAndRestartBetweenStages() async throws {
        let root = try temporary(), fake = FakeReplyModel()
        var pipeline: ReplyPipeline? = try setup(root, fake: fake)
        let full = try capture(pipeline!)
        let metadata = InboundCapture(permissionID: full.permissionID, subject: full.subject, messageID: full.messageID, raw: nil)
        try pipeline!.inbox.publish(metadata); try await pipeline!.importInbox()
        XCTAssertEqual(try pipeline!.store.records().first?.state, .awaitingBody)
        try pipeline!.inbox.publish(full); try await pipeline!.importInbox()
        XCTAssertEqual(try pipeline!.store.records().count, 1)
        var item = try XCTUnwrap(pipeline!.store.records().first)
        item.accountID = "test"; item.localID = "one"; item.revision = try pipeline!.store.settings().revision
        let output = try await fake.run(.triage(item.triageRequest), route: AccountRoute(accountID: "test", allowedHarnesses: [.deepseek])) {}
        item.decisionData = output.content; item.state = .draftQueued
        try pipeline!.store.save(item); pipeline = nil
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        let resumed = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, _ in nil }, model: { _ in fake })
        try await resumed.pump()
        XCTAssertEqual(try store.record(item.id)?.state, .draftReady)
        let count = await fake.calls; XCTAssertEqual(count, 2) // one prior triage, one resumed draft
    }
    func testRevokedCaptureIsNotImportedAndBodyRequestIsOneShot() async throws {
        let pipeline = try setup(try temporary())
        let capture = try capture(pipeline)
        let permission = try XCTUnwrap(pipeline.store.settings().permission)
        XCTAssertTrue(try pipeline.inbox.claimBody(permission: permission, subject: capture.subject, messageID: capture.messageID))
        XCTAssertFalse(try pipeline.inbox.claimBody(permission: permission, subject: capture.subject, messageID: capture.messageID))
        try pipeline.inbox.publish(capture)
        try pipeline.updateSettings { $0.permission = nil }
        try await pipeline.importInbox()
        XCTAssertTrue(try pipeline.store.records().isEmpty)
        XCTAssertTrue(try pipeline.inbox.files().isEmpty)
    }

    func testBodyRejectionCompletesSingleCandidateAndSurvivesRestart() async throws {
        let root = try temporary(), fake = FakeReplyModel()
        var pipeline: ReplyPipeline? = try setup(root, fake: fake)
        let permission = try XCTUnwrap(pipeline!.store.settings().permission)
        let header = InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "oversize@example.com", raw: nil)
        let id = try pipeline!.store.importCapture(header)
        let rejection = InboundCapture(permissionID: permission.id, subject: header.subject, messageID: header.messageID,
            raw: nil, issue: MailBodyRejection.messageTooLarge.rawValue)
        XCTAssertEqual(try pipeline!.store.importCapture(rejection), id)
        XCTAssertEqual(try pipeline!.store.records().count, 1)
        XCTAssertEqual(try pipeline!.store.record(id)?.state, .needsReview)
        XCTAssertEqual(try pipeline!.store.record(id)?.error, "messageTooLarge")
        // Both prior ingests still map to the same record after a crash/restart.
        pipeline = nil
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        XCTAssertEqual(try store.importCapture(header), id)
        XCTAssertEqual(try store.importCapture(rejection), id)
        let resumed = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")),
            resolve: { _, _ in XCTFail("Rejected body must not resolve identity"); return nil }, model: { _ in fake })
        try await resumed.pump()
        XCTAssertEqual(try store.records().count, 1)
        let calls = await fake.calls; XCTAssertEqual(calls, 0)
    }

    func testBodyRejectionDoesNotMergeAmbiguousOrUnrelatedCandidates() throws {
        let pipeline = try setup(try temporary())
        let permission = try XCTUnwrap(pipeline.store.settings().permission)
        for id in ["ambiguous@example.com", "ambiguous@example.com", "other@example.com"] {
            _ = try pipeline.store.importCapture(InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: id, raw: nil))
        }
        _ = try pipeline.store.importCapture(InboundCapture(permissionID: permission.id, subject: "Other subject", messageID: "other@example.com", raw: nil))
        let reject = InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "ambiguous@example.com", raw: nil, issue: "messageTooLarge")
        _ = try pipeline.store.importCapture(reject)
        XCTAssertEqual(try pipeline.store.records().filter { $0.state == .awaitingBody }.count, 4)
        XCTAssertEqual(try pipeline.store.records().filter { $0.state == .needsReview }.count, 1)
        let unrelated = InboundCapture(permissionID: permission.id, subject: "Changed", messageID: "other@example.com", raw: nil, issue: "messageTooLarge")
        _ = try pipeline.store.importCapture(unrelated)
        XCTAssertEqual(try pipeline.store.records().count, 6)
        let denied = InboundCapture(permissionID: UUID(), subject: "Synthetic", messageID: "other@example.com", raw: nil, issue: "messageTooLarge")
        XCTAssertThrowsError(try pipeline.store.importCapture(denied))
        XCTAssertEqual(try pipeline.store.records().count, 6)
    }

    func testOversizeMailSourceStopsBeforeHarnessAndDoesNotRetry() async throws {
        let root = try temporary(), fake = FakeReplyModel()
        let configured = try setup(root, fake: fake)
        let pipeline = ReplyPipeline(store: configured.store, inbox: configured.inbox,
            resolve: { _, _ in throw MailBodyRejection.messageTooLarge }, model: { _ in fake })
        try pipeline.inbox.publish(try capture(pipeline))
        for _ in 0..<2 { try await pipeline.pump() }
        let item = try XCTUnwrap(pipeline.store.records().first)
        XCTAssertEqual(item.state, .needsReview)
        XCTAssertEqual(item.error, "messageTooLarge")
        XCTAssertNil(item.accountID)
        XCTAssertTrue(item.runs.isEmpty)
        let calls = await fake.calls; XCTAssertEqual(calls, 0)
    }
}

import XCTest
@testable import MailpipeRuntime
import MailpipeCore
import HarnessAdapters

actor FakeReplyModel: ReplyModelRunning {
    private(set) var calls = 0
    let shouldReply: String
    var afterRun: (@Sendable () async throws -> Void)?
    func setAfterRun(_ action: @escaping @Sendable () async throws -> Void) { afterRun = action }
    init(shouldReply: String = "yes") { self.shouldReply = shouldReply }
    func run(_ task: ReplyModelTask, route: AccountRoute, authorize: @escaping @Sendable () async throws -> Void) async throws -> ReplyModelOutput {
        try route.authorize(.deepseek); try await authorize(); calls += 1
        var object: [String: Any]
        switch task {
        case .triage(let request):
            object = try JSONSerialization.jsonObject(with: ReplySyntheticFixture.decision) as! [String: Any]
            object["request_id"] = request.requestID; object["message_ref"] = request.message.messageRef
            object["should_reply"] = shouldReply; object["evidence"] = []
        case .draft(let request):
            object = try JSONSerialization.jsonObject(with: ReplySyntheticFixture.draft) as! [String: Any]
            object["request_id"] = request.requestID; object["triage_request_id"] = request.triageRequestID; object["message_ref"] = request.message.messageRef
        }
        try await afterRun?()
        return ReplyModelOutput(content: try JSONSerialization.data(withJSONObject: object), inputTokens: 10, outputTokens: 20)
    }
}

@MainActor
final class PipelineTests: XCTestCase {
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
    func testCandidateRequiresExplicitChoiceAndVersionCheck() async throws {
        let pipeline = try setup(temporary())
        try pipeline.inbox.publish(try capture(pipeline)); try await pipeline.pump()
        let id = try XCTUnwrap(pipeline.store.records().first).id
        try pipeline.store.saveEdits(id, subject: "Hidden subject", body: "Keep my edit")
        try pipeline.regenerate(id); try await pipeline.pump()
        var item = try XCTUnwrap(pipeline.store.record(id))
        XCTAssertTrue(item.hasDraftCandidate)
        XCTAssertEqual(item.displayedBody, "Keep my edit")
        let version = try XCTUnwrap(item.draftVersion)
        // Typing while a candidate is waiting does not dismiss it.
        try pipeline.store.saveEdits(id, subject: item.displayedSubject, body: "Newer edit")
        XCTAssertTrue(try XCTUnwrap(pipeline.store.record(id)).hasDraftCandidate)
        XCTAssertThrowsError(try pipeline.store.resolveDraftCandidate(id, expected: "stale", adopt: true))
        try pipeline.store.resolveDraftCandidate(id, expected: version, adopt: false)
        item = try XCTUnwrap(pipeline.store.record(id))
        XCTAssertFalse(item.hasDraftCandidate)
        XCTAssertEqual(item.displayedBody, "Newer edit")
        // An identical output from a later run is still a new candidate.
        try pipeline.regenerate(id); try await pipeline.pump()
        item = try XCTUnwrap(pipeline.store.record(id))
        XCTAssertTrue(item.hasDraftCandidate)
        XCTAssertNotEqual(item.draftVersion, version)
        let newVersion = try XCTUnwrap(item.draftVersion)
        try pipeline.store.resolveDraftCandidate(id, expected: newVersion, adopt: true)
        item = try XCTUnwrap(pipeline.store.record(id))
        XCTAssertFalse(item.hasDraftCandidate)
        XCTAssertEqual(item.displayedBody, item.draft?.body)
        XCTAssertEqual(item.displayedSubject, "Hidden subject")
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
    func testRegenerationIsBoundedAndPreservesEdits() async throws {
        let fake = FakeReplyModel(), pipeline = try setup(temporary(), fake: fake)
        try pipeline.inbox.publish(try capture(pipeline)); try await pipeline.pump()
        let id = try XCTUnwrap(pipeline.store.records().first).id
        try pipeline.store.saveEdits(id, subject: "My subject", body: "My local edit")
        for _ in 0..<3 {
            try pipeline.regenerate(id)
            XCTAssertThrowsError(try pipeline.regenerate(id))
            try await pipeline.pump()
            XCTAssertEqual(try pipeline.store.record(id)?.displayedBody, "My local edit")
            XCTAssertEqual(try pipeline.store.record(id)?.state, .draftReady)
        }
        XCTAssertThrowsError(try pipeline.regenerate(id))
        let count = await fake.calls; XCTAssertEqual(count, 8)
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
    func testManualRegenerationUsesCurrentServiceLevel() async throws {
        let pipeline = try setup(temporary())
        try pipeline.updateSettings { $0.suggestionsOnly = true }
        let id = try pipeline.enqueueManual(id: UUID(), subject: "Synthetic", body: "Please reply", executable: "/fake/dsh")
        try await pipeline.pump()
        try pipeline.store.saveEdits(id, subject: "Edited", body: "Keep local reply")
        try pipeline.updateSettings { $0.level = .l1 }
        try pipeline.regenerate(id); try await pipeline.pump()
        let item = try XCTUnwrap(pipeline.store.record(id))
        XCTAssertEqual(item.level, .l1)
        XCTAssertEqual(item.state, .needsReply)
        XCTAssertEqual(item.runs.count, 3)
        XCTAssertEqual(item.displayedBody, "Keep local reply")
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
            let count = await fake.calls; XCTAssertEqual(count, ambiguous ? 0 : 2)
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
        try pipeline!.importInbox()
        try pipeline!.inbox.publish(input) // deletion-before-crash replay of the same ingest
        try pipeline!.importInbox()
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
        let count = await fake.calls; XCTAssertEqual(count, 2)
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
    func testNoAndL1DoNotDraft() async throws {
        for (reply, level, expected) in [("no", ServiceLevel.l2, ReplyState.noReply), ("unknown", .l2, .needsReview), ("yes", .l1, .needsReply), ("yes", .l0, .noReply)] {
            let fake = FakeReplyModel(shouldReply: reply), pipeline = try setup(try temporary(), fake: fake)
            try pipeline.updateSettings { $0.level = level }
            try pipeline.inbox.publish(try capture(pipeline)); try await pipeline.pump()
            XCTAssertEqual(try pipeline.store.records().first?.state, expected)
            let count = await fake.calls; XCTAssertEqual(count, 1)
        }
    }
    func testRestartDoesNotReplayUnknownCallAndWriterLock() throws {
        let root = try temporary()
        var pipeline: ReplyPipeline? = try setup(root)
        try pipeline!.inbox.publish(try capture(pipeline!)); try pipeline!.importInbox()
        var item = try XCTUnwrap(pipeline!.store.records().first)
        item.state = .triaging; try pipeline!.store.save(item)
        XCTAssertThrowsError(try PipelineStore(directory: root.appendingPathComponent("state")))
        pipeline = nil
        let store = try PipelineStore(directory: root.appendingPathComponent("state"))
        XCTAssertEqual(try store.records().first?.state, .needsReview)
        XCTAssertEqual(try store.records().first?.error, "interrupted")
    }
    func testSymlinkAndUnsupportedMIME() throws {
        let root = try temporary(), pipeline = try setup(root)
        let target = root.appendingPathComponent("private")
        try Data("secret".utf8).write(to: target)
        let link = pipeline.inbox.directory.appendingPathComponent("bad.capture")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try pipeline.importInbox()
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
        try pipeline.importInbox()
        let record = try XCTUnwrap(pipeline.store.records().first { $0.messageID == "html@example.com" })
        XCTAssertEqual(record.input.body, "Please reply")
        XCTAssertEqual(record.state, .awaitingAccount)
        XCTAssertNil(record.error)
        let sealed = Data("Content-Type: application/pkcs7-mime; smime-type=enveloped-data\r\n\r\nsecret".utf8)
        try pipeline.inbox.publish(InboundCapture(permissionID: imported.permissionID, subject: "Synthetic", messageID: "sealed@example.com", raw: sealed))
        try pipeline.importInbox()
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
    func testPauseDuringTriageDiscardsDecisionAndDoesNotDraft() async throws {
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
        XCTAssertNil(record.decisionData)
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
        try pipeline!.inbox.publish(metadata); try pipeline!.importInbox()
        XCTAssertEqual(try pipeline!.store.records().first?.state, .awaitingBody)
        try pipeline!.inbox.publish(full); try pipeline!.importInbox()
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
    func testRevokedCaptureIsNotImportedAndBodyRequestIsOneShot() throws {
        let pipeline = try setup(try temporary())
        let capture = try capture(pipeline)
        let permission = try XCTUnwrap(pipeline.store.settings().permission)
        XCTAssertTrue(try pipeline.inbox.claimBody(permission: permission, subject: capture.subject, messageID: capture.messageID))
        XCTAssertFalse(try pipeline.inbox.claimBody(permission: permission, subject: capture.subject, messageID: capture.messageID))
        try pipeline.inbox.publish(capture)
        try pipeline.updateSettings { $0.permission = nil }
        try pipeline.importInbox()
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

@MainActor
final class ManualSuggestionTests: XCTestCase {
    func setup(_ fake: FakeReplyModel) throws -> ReplyPipeline {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try PipelineStore(directory: root)
        let pipeline = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")),
            resolve: { _, _ in XCTFail("Manual suggestions must never access Mail"); return nil }, model: { _ in fake })
        try pipeline.updateSettings { $0.executable = "/fake/dsh"; $0.level = .l1; $0.suggestionsOnly = true }
        return pipeline
    }
    func testExplicitConsentIsIdempotentAndNeverUsesMail() async throws {
        let fake = FakeReplyModel(), tested = try setup(fake)
        try await tested.pump(); let initial = await fake.calls; XCTAssertEqual(initial, 0)
        let id = UUID()
        for _ in 0..<2 {
            _ = try tested.enqueueManual(id: id, subject: "Synthetic", body: "Please reply", executable: "/fake/dsh")
            try await tested.pump()
        }
        let calls = await fake.calls; XCTAssertEqual(calls, 1)
        XCTAssertEqual(try tested.store.record(id.uuidString)?.state, .needsReply)
        XCTAssertNil(try tested.store.settings().permission)
        XCTAssertThrowsError(try tested.enqueueManual(id: id, subject: "Changed", body: "Please reply", executable: "/fake/dsh"))
    }
    func testPauseRevocationAndToolChangesPreventDispatch() async throws {
        for change in [0, 1, 2] {
            let fake = FakeReplyModel(), pipeline = try setup(fake)
            let id = try pipeline.enqueueManual(id: UUID(), subject: "Synthetic", body: "Please reply", executable: "/fake/dsh")
            try pipeline.updateSettings {
                if change == 0 { $0.paused = true }
                if change == 1 { $0.suggestionsOnly = false }
                if change == 2 { $0.executable = "/fake/other" }
            }
            try await pipeline.pump()
            let calls = await fake.calls; XCTAssertEqual(calls, 0)
            XCTAssertNotEqual(try pipeline.store.record(id)?.state, .needsReply)
        }
    }
    func testRevocationDuringTriageStopsDraftAndKeepsUsage() async throws {
        let fake = FakeReplyModel(), pipeline = try setup(fake)
        try pipeline.updateSettings { $0.level = .l2 }
        await fake.setAfterRun {
            try await MainActor.run { try pipeline.updateSettings { $0.suggestionsOnly = false } }
        }
        let id = try pipeline.enqueueManual(id: UUID(), subject: "Synthetic", body: "Please reply", executable: "/fake/dsh")
        try await pipeline.pump()
        let item = try XCTUnwrap(pipeline.store.record(id))
        XCTAssertEqual(item.state, .needsReview); XCTAssertNil(item.draft)
        XCTAssertEqual(item.runs.first?.inputTokens, 10)
        let calls = await fake.calls; XCTAssertEqual(calls, 1)
        try await pipeline.pump(); let after = await fake.calls; XCTAssertEqual(after, 1)
    }
    func testUnconfirmedSpoolAndInvalidInputCannotGrantManualRoute() async throws {
        let fake = FakeReplyModel(), pipeline = try setup(fake)
        XCTAssertThrowsError(try pipeline.enqueueManual(id: UUID(), subject: "Synthetic", body: "", executable: "/fake/dsh"))
        XCTAssertThrowsError(try pipeline.enqueueManual(id: UUID(), subject: "Synthetic", body: String(repeating: "a", count: 16_385), executable: "/fake/dsh"))
        XCTAssertThrowsError(try pipeline.enqueueManual(id: UUID(), subject: "Synthetic", body: "Please reply", executable: "/fake/other"))
        let capture = InboundCapture(permissionID: UUID(), subject: "Synthetic", messageID: "synthetic@example.com", raw: Data("Content-Type: text/plain\r\n\r\nPlease reply".utf8))
        XCTAssertThrowsError(try pipeline.store.importCapture(capture))
        try await pipeline.pump(); let calls = await fake.calls; XCTAssertEqual(calls, 0)
    }
}

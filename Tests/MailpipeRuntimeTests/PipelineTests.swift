import XCTest
@testable import MailpipeRuntime
import MailpipeCore
import HarnessAdapters

actor FakeReplyModel: ReplyModelRunning {
    private(set) var calls = 0
    let shouldReply: String
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
        XCTAssertThrowsError(try PlainMailBody.decode(Data("Content-Type: multipart/mixed; boundary=x\r\n\r\nbody".utf8)))
        XCTAssertEqual(try PlainMailBody.decode(Data("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nPlease=20reply".utf8)), "Please reply")
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
}

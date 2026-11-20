import XCTest
import MailpipeCore
import HarnessAdapters
@testable import MailpipeRuntime

@MainActor
final class ComposeSuggestionTests: XCTestCase {
    private struct Fixture {
        let pipeline: ReplyPipeline
        let model: FakeReplyModel
        let item: StoredReply
        let identity: ComposeMessageIdentity
        let session = UUID()

        func request(_ action: ComposePanelAction) -> ComposePanelRequest {
            ComposePanelRequest(sessionID: session, identity: identity, action: action)
        }

        @MainActor func lookup() async throws -> ComposePanelSuggestion {
            let result = await pipeline.handleComposePanelRequest(request(.lookup)) { true }
            guard case .ready(let suggestion) = result else { throw MailpipeError.invalidOutput }
            return suggestion
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try PipelineStore(directory: root.appendingPathComponent("db"))
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        let fake = FakeReplyModel()
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in
            XCTFail("Compose must use the captured original"); return nil
        }, model: { _ in fake })
        let permission = CapturePermission(delivery: .mailKit)
        try pipeline.updateSettings { $0.permission = permission; $0.executable = "/fake/dsh" }
        let raw = Data("From: sender@example.com\r\nTo: receiver@example.com\r\n\r\nOriginal private body".utf8)
        let id = try store.importCapture(InboundCapture(permissionID: permission.id, subject: "Example",
                                                       messageID: "question@example.com", raw: raw))
        var item = try XCTUnwrap(store.record(id))
        let task = try ReplyDraftRequest(message: item.input)
        item.draftData = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "request_id": task.requestID,
            "triage_request_id": task.triageRequestID, "message_ref": id, "subject": "Re: Example", "body": "Original suggestion"])
        item.state = .draftReady
        item.editedBody = "Workbench edit"
        try store.save(item)
        try store.saveReplyInstructions("Use a custom sign-off.")
        let identity = try XCTUnwrap(ComposeMessageIdentity(messageID: "<question@example.com>", subject: "Example",
            sender: "sender@example.com", to: ["receiver@example.com"], cc: [], displayBody: "Original private body"))
        return Fixture(pipeline: pipeline, model: fake, item: item, identity: identity)
    }

    func testLookupNeedsUniqueOriginalAndCurrentPermissionBeforeExposingEdits() async throws {
        let f = try fixture()
        let suggestion = try await f.lookup()
        XCTAssertEqual(suggestion.body, "Workbench edit")
        for other in [
            ComposeMessageIdentity(messageID: "other@example.com", subject: "Example", sender: "sender@example.com",
                                   to: ["receiver@example.com"], cc: []),
            ComposeMessageIdentity(messageID: "question@example.com", subject: "Example", sender: "other@example.com",
                                   to: ["receiver@example.com"], cc: []),
            ComposeMessageIdentity(messageID: "question@example.com", subject: "Example", sender: "sender@example.com",
                                   to: ["receiver@example.com"], cc: [], displayBody: "Different original")
        ] {
            let req = ComposePanelRequest(sessionID: f.session, identity: try XCTUnwrap(other), action: .lookup)
            let result = await f.pipeline.handleComposePanelRequest(req) { true }
            XCTAssertEqual(result, .noDraft)
        }
        try f.pipeline.updateSettings { $0.paused = true }
        let paused = await f.pipeline.handleComposePanelRequest(f.request(.lookup)) { true }
        XCTAssertEqual(paused, .noDraft)
        try f.pipeline.updateSettings { $0.paused = false }
        var duplicate = StoredReply(id: "duplicate", permissionID: f.item.permissionID, capturedAt: Date(),
            messageID: f.item.messageID, input: f.item.input, state: .cancelled)
        duplicate.correspondents = f.item.correspondents
        duplicate.displayBody = f.item.displayBody
        duplicate.discardedAt = Date()
        try f.pipeline.store.save(duplicate)
        let ambiguous = await f.pipeline.handleComposePanelRequest(f.request(.lookup)) { true }
        XCTAssertEqual(ambiguous, .noDraft)
        let calls = await f.model.calls
        XCTAssertEqual(calls, 0)
    }

    func testShortenRunsOnceOnConfirmedPanelTextAndPreservesOriginal() async throws {
        let f = try fixture()
        let original = try await f.lookup()
        let edit = "Please retain my manually edited text. " + String(repeating: "Additional detail. ", count: 8) +
            "https://github.com/example/example/pull/7"
        let req = f.request(.shorten(version: original.version, body: edit))
        let result = await f.pipeline.handleComposePanelRequest(req) { true }
        guard case .ready(let shorter) = result else { return XCTFail("Expected shorter variant, got \(result)") }
        XCTAssertLessThan(shorter.body.count, edit.count)
        XCTAssertEqual(shorter.version, original.version)
        let repeated = await f.pipeline.handleComposePanelRequest(req) { true }
        XCTAssertEqual(repeated, .changed)
        let requests = await f.model.draftRequests
        XCTAssertEqual(requests.count, 1)
        let task = try XCTUnwrap(requests.first)
        XCTAssertEqual(task.draftToShorten, edit)
        XCTAssertTrue(task.message.subject.isEmpty && task.message.body.isEmpty)
        XCTAssertNil(task.approvedPullRequest)
        XCTAssertNotEqual(task.replyInstructions, try f.pipeline.store.settings().replyInstructions)
        let persisted = try XCTUnwrap(f.pipeline.store.record(f.item.id))
        XCTAssertEqual(persisted.draftData, f.item.draftData)
        XCTAssertEqual(persisted.editedBody, "Workbench edit")
        XCTAssertEqual(persisted.draftVersion, f.item.draftVersion)
        XCTAssertTrue(persisted.runs.isEmpty)
        XCTAssertEqual(persisted.composeShortenRuns?.count, 1)
        XCTAssertEqual(persisted.composeShortenRuns?.last?.inputTokens, 10)
        XCTAssertNil(persisted.composeShortenRuns?.last?.actualCost)
    }

    func testConcurrentEditOrDiscardMakesConfirmedVersionStale() async throws {
        let f = try fixture()
        let displayed = try await f.lookup()
        let request = f.request(.shorten(version: displayed.version, body: String(repeating: "Hello ", count: 30)))
        let store = f.pipeline.store, id = f.item.id
        await f.model.setAfterRun {
            try await store.saveEdits(id, subject: "Edited", body: "Latest workbench text")
        }
        let result = await f.pipeline.handleComposePanelRequest(request) { true }
        XCTAssertEqual(result, .changed)
        let current = try XCTUnwrap(store.record(id))
        XCTAssertEqual(current.displayedBody, "Latest workbench text")
        XCTAssertEqual(current.state, .draftReady)
        XCTAssertNil(current.error)
        XCTAssertEqual(current.composeShortenRuns?.last?.error, "revoked")
        let stale = await f.pipeline.handleComposePanelRequest(f.request(request.action)) { true }
        XCTAssertEqual(stale, .changed)
        let fresh = try await f.lookup()
        try store.discard(id)
        let discarded = await f.pipeline.handleComposePanelRequest(f.request(.shorten(version: fresh.version, body: "Edit"))) { true }
        XCTAssertEqual(discarded, .changed)
        let calls = await f.model.calls
        XCTAssertEqual(calls, 1)
    }

    func testOverlapAndRevocationDuringAConfirmedRun() async throws {
        let f = try fixture()
        let suggestion = try await f.lookup()
        let action = ComposePanelAction.shorten(version: suggestion.version, body: String(repeating: "Hello ", count: 30))
        await f.model.setAfterRun { @MainActor in
            let overlapping = await f.pipeline.handleComposePanelRequest(f.request(action)) { true }
            XCTAssertEqual(overlapping, .changed)
            XCTAssertThrowsError(try f.pipeline.regenerate(f.item.id))
            try f.pipeline.updateSettings { $0.permission = nil }
        }
        let revoked = await f.pipeline.handleComposePanelRequest(f.request(action)) { true }
        XCTAssertEqual(revoked, .changed)
        let item = try XCTUnwrap(f.pipeline.store.record(f.item.id))
        XCTAssertEqual(item.editedBody, "Workbench edit")
        XCTAssertEqual(item.composeShortenRuns?.last?.inputTokens, 10)
        let calls = await f.model.calls
        XCTAssertEqual(calls, 1)
    }

    func testRestartClosesUnknownReceiptWithoutReplaying() throws {
        let f = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID().uuidString
        do {
            let store = try PipelineStore(directory: root)
            var item = f.item
            let dest = try DataDestination(messageRef: item.id, runID: runID, taskKind: .draft, harness: .deepseek)
            item.composeShortenRuns = [PipelineRun(destination: dest, startedAt: Date())]
            try store.save(item)
        }
        let recovered = try PipelineStore(directory: root)
        let item = try XCTUnwrap(recovered.record(f.item.id))
        XCTAssertEqual(item.editedBody, "Workbench edit")
        XCTAssertEqual(item.state, .draftReady)
        XCTAssertFalse(item.isShortening)
        XCTAssertEqual(item.composeShortenRuns?.last?.error, "interrupted")
        XCTAssertEqual(item.composeShortenRuns?.last?.destination.runID, runID)
    }

    func testFailureOrClosedPanelLeavesPreparedDraftUsable() async throws {
        let f = try fixture()
        let original = try await f.lookup()
        let request = f.request(.shorten(version: original.version, body: "Text in panel"))
        let inactive = await f.pipeline.handleComposePanelRequest(request) { false }
        XCTAssertEqual(inactive, .unavailable)
        await f.model.setAfterRun { throw MailpipeError.timedOut }
        let failed = await f.pipeline.handleComposePanelRequest(request) { true }
        XCTAssertEqual(failed, .failed)
        let current = try await f.lookup()
        XCTAssertEqual(current, original)
        XCTAssertEqual(try f.pipeline.store.record(f.item.id)?.composeShortenRuns?.last?.error, "timedOut")
        let calls = await f.model.calls
        XCTAssertEqual(calls, 1)
    }
}

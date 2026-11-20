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

    private func fixture(body: String = "Original private body") throws -> Fixture {
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
        let raw = Data("From: sender@example.com\r\nTo: receiver@example.com\r\n\r\n\(body)".utf8)
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
            sender: "sender@example.com", to: ["receiver@example.com"], cc: [], displayBody: body))
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

    func testRegeneratesOnceFromOriginalMailAndSavedInstructions() async throws {
        let f = try fixture(body: "Please review https://github.com/example/example/pull/7")
        let original = try await f.lookup()
        let req = f.request(.regenerate(version: original.version))
        let result = await f.pipeline.handleComposePanelRequest(req) { true }
        guard case .ready(let generated) = result else { return XCTFail("Expected regenerated suggestion") }
        XCTAssertGreaterThan(generated.body.count, original.body.count)
        XCTAssertEqual(generated.version, original.version)
        let repeated = await f.pipeline.handleComposePanelRequest(req) { true }
        XCTAssertEqual(repeated, .changed)
        let requests = await f.model.draftRequests
        XCTAssertEqual(requests.count, 1)
        let task = try XCTUnwrap(requests.first)
        XCTAssertEqual(task.message, f.item.input)
        XCTAssertFalse(task.allowsNoReply)
        XCTAssertNil(task.pullRequestReviewTarget)
        XCTAssertNil(task.approvedPullRequest)
        XCTAssertEqual(task.replyInstructions, "Use a custom sign-off.")
        let persisted = try XCTUnwrap(f.pipeline.store.record(f.item.id))
        XCTAssertEqual(persisted.draftData, f.item.draftData)
        XCTAssertEqual(persisted.editedBody, "Workbench edit")
        XCTAssertEqual(persisted.draftVersion, f.item.draftVersion)
        XCTAssertTrue(persisted.runs.isEmpty)
        XCTAssertEqual(persisted.composeRegenerationRuns?.count, 1)
        XCTAssertEqual(persisted.composeRegenerationRuns?.last?.inputTokens, 10)
        XCTAssertNil(persisted.composeRegenerationRuns?.last?.actualCost)
    }

    func testRegenerationLimitIsSharedWithWorkbenchAndExcludesOldShortenReceipts() async throws {
        let f = try fixture()
        var item = f.item
        item.regenerationCount = 2
        let old = try DataDestination(messageRef: item.id, runID: "build-43", taskKind: .draft, harness: .deepseek)
        item.composeShortenRuns = [PipelineRun(destination: old, startedAt: Date(), finishedAt: Date())]
        try f.pipeline.store.save(item)
        let original = try await f.lookup()
        let action = ComposePanelAction.regenerate(version: original.version)
        let allowed = await f.pipeline.handleComposePanelRequest(f.request(action)) { true }
        guard case .ready = allowed else { return XCTFail("Third attempt should be available") }
        let limited = await f.pipeline.handleComposePanelRequest(f.request(action)) { true }
        XCTAssertEqual(limited, .regenerationLimitReached)
        XCTAssertThrowsError(try f.pipeline.regenerate(item.id))
        let current = try XCTUnwrap(f.pipeline.store.record(item.id))
        XCTAssertEqual(current.composeShortenRuns?.first?.destination.runID, old.runID)
        XCTAssertFalse(current.canRequestRegeneration(settings: try f.pipeline.store.settings()))
        XCTAssertEqual(current.regenerationCount, 2)
        XCTAssertEqual(current.composeRegenerationRuns?.count, 1)
        let reviewed = try await f.lookup()
        XCTAssertEqual(reviewed, original)
        let calls = await f.model.calls
        XCTAssertEqual(calls, 1)
    }

    func testConcurrentEditOrDiscardMakesConfirmedVersionStale() async throws {
        let f = try fixture()
        let displayed = try await f.lookup()
        let request = f.request(.regenerate(version: displayed.version))
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
        XCTAssertEqual(current.composeRegenerationRuns?.last?.error, "revoked")
        let stale = await f.pipeline.handleComposePanelRequest(f.request(request.action)) { true }
        XCTAssertEqual(stale, .changed)
        let fresh = try await f.lookup()
        try store.discard(id)
        let discarded = await f.pipeline.handleComposePanelRequest(f.request(.regenerate(version: fresh.version))) { true }
        XCTAssertEqual(discarded, .changed)
        let calls = await f.model.calls
        XCTAssertEqual(calls, 1)
    }

    func testRegenerationRechecksTheAuthorizedInboxForScopeBasedCaptures() async throws {
        let f = try fixture()
        let scope = try AccountScope(accountID: "test", accountName: "Example", mailboxName: "INBOX")
        let permission = CapturePermission()
        try f.pipeline.updateSettings { $0.permission = permission; $0.scope = scope }
        let raw = Data("From: sender@example.com\r\nTo: receiver@example.com\r\n\r\nLegacy source".utf8)
        let id = try f.pipeline.store.importCapture(InboundCapture(permissionID: permission.id, subject: "Legacy",
                                            messageID: "legacy@example.com", raw: raw))
        var item = try XCTUnwrap(f.pipeline.store.record(id))
        item.accountID = scope.accountID
        item.scopeID = scope.id
        item.localID = "legacy-local"
        let task = try ReplyDraftRequest(message: item.input)
        item.draftData = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "request_id": task.requestID,
            "triage_request_id": task.triageRequestID, "message_ref": id, "subject": "Re: Legacy", "body": "Draft"])
        item.state = .draftReady
        try f.pipeline.store.save(item)
        let identity = try XCTUnwrap(ComposeMessageIdentity(messageID: "legacy@example.com", subject: "Legacy",
            sender: "sender@example.com", to: ["receiver@example.com"], cc: []))
        for source in [nil, raw] {
            let pipeline = ReplyPipeline(store: f.pipeline.store, inbox: f.pipeline.inbox, resolve: { _, resolvedScope in
                XCTAssertEqual(resolvedScope, scope)
                return source.map { VerifiedMail(accountID: scope.accountID, localID: "legacy-local", source: $0) }
            }, model: { _ in f.model })
            let legacy = Fixture(pipeline: pipeline, model: f.model, item: item, identity: identity)
            let displayed = try await legacy.lookup()
            let result = await pipeline.handleComposePanelRequest(legacy.request(.regenerate(version: displayed.version))) { true }
            if source == nil {
                XCTAssertEqual(result, .failed)
            } else {
                guard case .ready = result else { return XCTFail("Verified original should regenerate") }
            }
        }
        let calls = await f.model.calls
        XCTAssertEqual(calls, 1)
    }

    func testOverlapAndRevocationDuringAConfirmedRun() async throws {
        let f = try fixture()
        let suggestion = try await f.lookup()
        let action = ComposePanelAction.regenerate(version: suggestion.version)
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
        XCTAssertEqual(item.composeRegenerationRuns?.last?.inputTokens, 10)
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
            item.composeRegenerationRuns = [PipelineRun(destination: dest, startedAt: Date())]
            try store.save(item)
        }
        let recovered = try PipelineStore(directory: root)
        let item = try XCTUnwrap(recovered.record(f.item.id))
        XCTAssertEqual(item.editedBody, "Workbench edit")
        XCTAssertEqual(item.state, .draftReady)
        XCTAssertFalse(item.isRegeneratingInCompose)
        XCTAssertEqual(item.composeRegenerationRuns?.last?.error, "interrupted")
        XCTAssertEqual(item.composeRegenerationRuns?.last?.destination.runID, runID)
    }

    func testFailureOrClosedPanelLeavesPreparedDraftUsable() async throws {
        let f = try fixture()
        let original = try await f.lookup()
        let request = f.request(.regenerate(version: original.version))
        let inactive = await f.pipeline.handleComposePanelRequest(request) { false }
        XCTAssertEqual(inactive, .unavailable)
        await f.model.setAfterRun { throw MailpipeError.timedOut }
        let failed = await f.pipeline.handleComposePanelRequest(request) { true }
        XCTAssertEqual(failed, .failed)
        let current = try await f.lookup()
        XCTAssertEqual(current, original)
        XCTAssertEqual(try f.pipeline.store.record(f.item.id)?.composeRegenerationRuns?.last?.error, "timedOut")
        let calls = await f.model.calls
        XCTAssertEqual(calls, 1)
    }
}

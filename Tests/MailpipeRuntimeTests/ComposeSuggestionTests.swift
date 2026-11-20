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

        @MainActor func choices(subject: String = "Example") async throws -> [ComposeDraftChoice] {
            let request = ComposePanelRequest(sessionID: session, identity: nil,
                action: .findDrafts(subjectDigest: ComposeMessageIdentity.digest(forSubject: subject)))
            let result = await pipeline.handleComposePanelRequest(request) { true }
            guard case let .draftChoices(choices) = result else { throw MailpipeError.invalidOutput }
            return choices
        }

        @MainActor func lookup() async throws -> ComposePanelSuggestion {
            var result = await pipeline.handleComposePanelRequest(request(.lookup)) { true }
            if result == .verifyOriginal {
                result = await pipeline.handleComposePanelRequest(request(.verifiedLookup)) { true }
            }
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

    func testRestoredWindowListsReadyDraftsAndOpensOnlyTheSelectedOriginal() async throws {
        let f = try fixture()
        let store = f.pipeline.store
        let raw = Data("From: another@example.com\r\nTo: receiver@example.com\r\n\r\nAnother private original".utf8)
        let id = try store.importCapture(InboundCapture(permissionID: f.item.permissionID, subject: "Example",
            messageID: "second@example.com", raw: raw))
        var second = try XCTUnwrap(store.record(id))
        let task = try ReplyDraftRequest(message: second.input)
        second.draftData = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "request_id": task.requestID,
            "triage_request_id": task.triageRequestID, "message_ref": id, "subject": "Re: Example", "body": "Second suggestion"])
        second.state = .draftReady
        try store.save(second)

        let choices = try await f.choices()
        XCTAssertEqual(choices.map(\.sender), ["another@example.com", "sender@example.com"])
        XCTAssertEqual(choices.map(\.capturedAt), [second.capturedAt, f.item.capturedAt])
        XCTAssertEqual(choices.last?.identity, f.identity)
        let wire = try XCTUnwrap(String(data: JSONEncoder().encode(choices), encoding: .utf8))
        for privateText in [f.item.input.body, f.item.displayedBody, second.input.body, second.displayedBody, "receiver@example.com"] {
            XCTAssertFalse(wire.contains(privateText))
        }
        let absent = try await f.choices(subject: "Other subject")
        XCTAssertTrue(absent.isEmpty)
        let choice = try XCTUnwrap(choices.first)
        let selected = ComposePanelRequest(sessionID: f.session, identity: choice.identity, action: .verifiedLookup)
        let response = await f.pipeline.handleComposePanelRequest(selected) { true }
        guard case let .ready(draft) = response else { return XCTFail("Expected chosen draft") }
        XCTAssertEqual(draft.body, second.displayedBody)
        try store.saveEdits(id, subject: "Re: Example", body: "Updated suggestion")
        let edited = await f.pipeline.handleComposePanelRequest(selected) { true }
        guard case let .ready(latest) = edited else { return XCTFail("Expected latest edit") }
        XCTAssertNotEqual(latest.version, draft.version)
        XCTAssertEqual(latest.body, "Updated suggestion")
        let stale = ComposePanelRequest(sessionID: f.session, identity: choice.identity, action: .regenerate(version: draft.version))
        let regenerated = await f.pipeline.handleComposePanelRequest(stale) { true }
        XCTAssertEqual(regenerated, .changed)
        try store.discard(id)
        let discarded = await f.pipeline.handleComposePanelRequest(selected) { true }
        XCTAssertEqual(discarded, .noDraft)
        let remaining = try await f.choices()
        XCTAssertEqual(remaining, Array(choices.suffix(1)))
        let calls = await f.model.calls
        XCTAssertEqual(calls, 0)
    }

    func testRestoredDraftChoiceRequiresCurrentAuthorizationAndReadyState() async throws {
        let f = try fixture()
        let available = try await f.choices()
        let choice = try XCTUnwrap(available.first)
        let request = ComposePanelRequest(sessionID: f.session, identity: choice.identity, action: .verifiedLookup)
        var changed = f.item
        changed.state = .noReply
        changed.editedBody = nil
        changed.draftData = nil
        try f.pipeline.store.save(changed)
        let noLongerReady = await f.pipeline.handleComposePanelRequest(request) { true }
        XCTAssertEqual(noLongerReady, .noDraft)
        let noChoices = try await f.choices()
        XCTAssertTrue(noChoices.isEmpty)
        try f.pipeline.store.save(f.item)
        try f.pipeline.updateSettings { $0.paused = true }
        let paused = try await f.choices()
        XCTAssertTrue(paused.isEmpty)
        try f.pipeline.updateSettings { $0.paused = false; $0.permission = nil }
        let revoked = try await f.choices()
        XCTAssertTrue(revoked.isEmpty)
        let stale = await f.pipeline.handleComposePanelRequest(request) { true }
        XCTAssertEqual(stale, .noDraft)
        let calls = await f.model.calls
        XCTAssertEqual(calls, 0)
    }

    func testOnlyReadyLookupRequestsOriginalVerificationAndRejectsDifferentBody() async throws {
        let f = try fixture()
        func lookup(_ action: ComposePanelAction, display: String? = nil) async throws -> ComposePanelResponse {
            let identity = try XCTUnwrap(ComposeMessageIdentity(messageID: "question@example.com", subject: "Example",
                sender: "sender@example.com", to: ["receiver@example.com"], cc: [], displayBody: display))
            return await f.pipeline.handleComposePanelRequest(.init(sessionID: f.session, identity: identity, action: action)) { true }
        }
        let initial = try await lookup(.lookup)
        XCTAssertEqual(initial, .verifyOriginal)
        let mismatch = try await lookup(.verifiedLookup, display: "Different source with the same envelope")
        XCTAssertEqual(mismatch, .noDraft)
        let verified = try await lookup(.verifiedLookup, display: f.item.displayBody)
        let unavailableBody = try await lookup(.verifiedLookup)
        guard case let .ready(suggestion) = verified else { return XCTFail("Expected verified draft") }
        XCTAssertEqual(suggestion.body, f.item.displayedBody)
        XCTAssertEqual(unavailableBody, verified)
        var duplicate = StoredReply(id: "other-capture", permissionID: f.item.permissionID, capturedAt: Date(),
            messageID: f.item.messageID, input: f.item.input, state: .noReply)
        duplicate.correspondents = f.item.correspondents
        duplicate.displayBody = "A distinct message reusing the same headers"
        try f.pipeline.store.save(duplicate)
        let ambiguous = try await lookup(.verifiedLookup)
        XCTAssertEqual(ambiguous, .noDraft)
        let canDisambiguate = try await lookup(.lookup)
        XCTAssertEqual(canDisambiguate, .verifyOriginal)
        let actual = try await lookup(.verifiedLookup, display: f.item.displayBody)
        XCTAssertEqual(actual, verified)
        let calls = await f.model.calls
        XCTAssertEqual(calls, 0)
    }

    func testFirstDraftFromStoredNoReplyIsPublishedOnceAndCanBeReopened() async throws {
        let f = try fixture(body: "Please review https://github.com/example/example/pull/7")
        var item = f.item
        item.state = .noReply
        item.draftData = nil
        item.editedBody = nil
        try f.pipeline.store.save(item)
        let metadata = try XCTUnwrap(ComposeMessageIdentity(messageID: "question@example.com", subject: item.input.subject,
            sender: "sender@example.com", to: ["receiver@example.com"], cc: []))
        let lookup = await f.pipeline.handleComposePanelRequest(.init(sessionID: f.session, identity: metadata, action: .lookup)) { true }
        guard case .canGenerate(let offer) = lookup else { return XCTFail("Expected generation offer") }
        XCTAssertFalse(offer.requiresOriginal)
        let wire = try JSONEncoder().encode(offer)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["version", "agentName", "requiresOriginal"])
        let callsBefore = await f.model.calls
        XCTAssertEqual(callsBefore, 0)
        let action = ComposePanelAction.generate(version: offer.version, original: nil)
        let request = f.request(action)
        await f.model.setAfterRun { @MainActor in
            let pending = await f.pipeline.handleComposePanelRequest(f.request(.lookup)) { true }
            XCTAssertEqual(pending, .preparing)
            let overlap = await f.pipeline.handleComposePanelRequest(f.request(action)) { true }
            XCTAssertEqual(overlap, .changed)
        }
        let result = await f.pipeline.handleComposePanelRequest(request) { true }
        guard case .ready(let first) = result else { return XCTFail("Expected first draft") }
        let requests = await f.model.draftRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.message, item.input)
        XCTAssertEqual(requests.first?.replyInstructions, "Use a custom sign-off.")
        XCTAssertEqual(requests.first?.allowsNoReply, false)
        XCTAssertNil(requests.first?.pullRequestReviewTarget)
        let stored = try XCTUnwrap(f.pipeline.store.record(item.id))
        XCTAssertEqual(stored.state, .draftReady)
        XCTAssertEqual(stored.displayedBody, first.body)
        XCTAssertEqual(stored.runs.last?.destination.runID, request.id.uuidString)
        XCTAssertNotNil(stored.runs.last?.finishedAt)
        XCTAssertNil(stored.regenerationCount)
        let reopen = try await f.lookup()
        XCTAssertEqual(first, reopen)
        let repeated = await f.pipeline.handleComposePanelRequest(request) { true }
        XCTAssertEqual(repeated, .changed)
    }

    func testUncapturedOriginalRequiresConfirmedPayloadAndCurrentScope() async throws {
        let f = try fixture()
        let subject = "An older question", body = "Could you reply?", display = "Could you reply? (quoted history)"
        func identity(_ subject: String, withBody: Bool) throws -> ComposeMessageIdentity {
            try XCTUnwrap(ComposeMessageIdentity(messageID: "<old@example.com>", subject: subject, sender: "a@example.com",
                to: ["b@example.com"], cc: [], displayBody: withBody ? display : nil, modelBody: withBody ? body : nil))
        }
        let original = try XCTUnwrap(ComposePanelOriginal(messageID: "<old@example.com>", subject: subject, sender: "a@example.com",
            to: ["b@example.com"], cc: [], body: body, displayBody: display))
        let session = UUID(), id = try identity(subject, withBody: true), metadata = try identity(subject, withBody: false)
        func request(_ action: ComposePanelAction) -> ComposePanelRequest {
            ComposePanelRequest(sessionID: session, identity: action == .lookup ? metadata : id, action: action)
        }
        try f.pipeline.updateSettings { $0.permission = CapturePermission(exactSubject: "Other", delivery: .mailKit) }
        let outside = await f.pipeline.handleComposePanelRequest(request(.lookup)) { true }
        XCTAssertEqual(outside, .noDraft)
        try f.pipeline.updateSettings { $0.permission = CapturePermission(exactSubject: subject, delivery: .mailKit) }
        let lookup = await f.pipeline.handleComposePanelRequest(request(.lookup)) { true }
        guard case .canGenerate(let offer) = lookup else { return XCTFail("Expected offer") }
        XCTAssertTrue(offer.requiresOriginal)
        XCTAssertEqual(try f.pipeline.store.records().count, 1)
        let missing = await f.pipeline.handleComposePanelRequest(request(.generate(version: offer.version, original: nil))) { true }
        XCTAssertEqual(missing, .changed)
        let substituted = try XCTUnwrap(ComposePanelOriginal(messageID: original.messageID, subject: subject, sender: original.sender,
            to: original.to, cc: [], body: "different", displayBody: display))
        let mismatch = await f.pipeline.handleComposePanelRequest(request(.generate(version: offer.version, original: substituted))) { true }
        XCTAssertEqual(mismatch, .changed)
        let action = ComposePanelAction.generate(version: offer.version, original: original)
        let otherSession = ComposePanelRequest(sessionID: UUID(), identity: id, action: action)
        let stale = await f.pipeline.handleComposePanelRequest(otherSession) { true }
        XCTAssertEqual(stale, .changed)
        let before = await f.model.calls
        XCTAssertEqual(before, 0)
        let firstRequest = request(action), doubleClick = request(action)
        let firstClick = Task { @MainActor in await f.pipeline.handleComposePanelRequest(firstRequest) { true } }
        let nextClick = Task { @MainActor in await f.pipeline.handleComposePanelRequest(doubleClick) { true } }
        let outcomes = [await firstClick.value, await nextClick.value]
        XCTAssertEqual(outcomes.filter { $0 == .changed }.count, 1)
        let result = try XCTUnwrap(outcomes.first { if case .ready = $0 { return true }; return false })
        guard case .ready(let draft) = result else { return XCTFail("Expected new draft") }
        let records = try f.pipeline.store.records()
        let stored = try XCTUnwrap(records.first(where: { $0.messageID == "old@example.com" }))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(stored.displayedBody, draft.body)
        XCTAssertEqual(stored.displayBody, display)
        let requests = await f.model.draftRequests
        XCTAssertEqual(requests.map(\.message.body), [body])
        let readyCheck = await f.pipeline.handleComposePanelRequest(request(.lookup)) { true }
        XCTAssertEqual(readyCheck, .verifyOriginal)
        let reopen = await f.pipeline.handleComposePanelRequest(request(.verifiedLookup)) { true }
        XCTAssertEqual(result, reopen)
        let replay = await f.pipeline.handleComposePanelRequest(request(action)) { true }
        XCTAssertEqual(replay, .changed)
        let calls = await f.model.calls
        XCTAssertEqual(calls, 1)
    }

    func testIneligibleOriginalCannotBeRecreatedAndRevocationPreventsPublishing() async throws {
        let f = try fixture()
        var item = f.item
        item.state = .noReply
        item.draftData = nil
        item.editedBody = nil
        let identity = try XCTUnwrap(ComposeMessageIdentity(messageID: "question@example.com", subject: item.input.subject,
            sender: "sender@example.com", to: ["receiver@example.com"], cc: [], displayBody: item.displayBody, modelBody: item.input.body))
        let session = UUID()
        func request(_ action: ComposePanelAction) -> ComposePanelRequest { .init(sessionID: session, identity: identity, action: action) }
        item.discardedAt = Date()
        try f.pipeline.store.save(item)
        let discarded = await f.pipeline.handleComposePanelRequest(request(.lookup)) { true }
        XCTAssertEqual(discarded, .noDraft)
        item.discardedAt = nil; item.state = .cancelled
        try f.pipeline.store.save(item)
        let cancelled = await f.pipeline.handleComposePanelRequest(request(.lookup)) { true }
        XCTAssertEqual(cancelled, .noDraft)
        item.state = .queued
        try f.pipeline.store.save(item)
        let queued = await f.pipeline.handleComposePanelRequest(request(.lookup)) { true }
        XCTAssertEqual(queued, .preparing)
        item.state = .needsReply
        try f.pipeline.store.save(item)
        let lookup = await f.pipeline.handleComposePanelRequest(request(.lookup)) { true }
        guard case .canGenerate(let offer) = lookup else { return XCTFail("Expected offer") }
        await f.model.setAfterRun { @MainActor in
            try f.pipeline.updateSettings { $0.permission = nil }
        }
        let revoked = await f.pipeline.handleComposePanelRequest(request(.generate(version: offer.version, original: nil))) { true }
        XCTAssertEqual(revoked, .changed)
        let stored = try XCTUnwrap(f.pipeline.store.record(item.id))
        XCTAssertNil(stored.draftData)
        XCTAssertNotNil(stored.runs.last?.error)
        XCTAssertNotNil(stored.runs.last?.finishedAt)
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

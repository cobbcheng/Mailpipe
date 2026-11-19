import XCTest
@testable import MailpipeRuntime
import MailpipeCore

@MainActor
final class OnboardingTests: XCTestCase {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testDraftRecoveryDoesNotAuthorizeOrResume() throws {
        let path = try root()
        var store: PipelineStore? = try PipelineStore(directory: path)
        var active = PipelineSettings(); active.paused = true
        try store!.saveSettings(active)
        var draft = OnboardingDraft(); draft.step = 4
        try store!.saveOnboarding(draft); store = nil
        let reopened = try PipelineStore(directory: path)
        XCTAssertEqual(try reopened.onboarding(), draft)
        XCTAssertNil(try reopened.settings().permission)
        XCTAssertTrue(try reopened.settings().paused)
    }
    func testOnlyFinalReviewCanCompleteInitialSetup() async throws {
        let store = try PipelineStore(directory: root())
        let session = try OnboardingSession(store: store, model: { _ in FakeReplyModel() })
        var draft = OnboardingDraft()
        draft.step = 5
        draft.executable = "/fake/dsh"
        draft.extensionAcknowledged = true
        draft.completed = true
        try session.save(draft)
        _ = try session.beginTest()
        try await session.testPipeline.pump()

        XCTAssertThrowsError(try session.activate(updatingConfiguration: true))
        XCTAssertFalse(try store.onboarding().completed)
        XCTAssertNil(try store.settings().executable)
        try session.activate()
        XCTAssertTrue(try store.onboarding().completed)

        draft = try store.onboarding()
        draft.completed = false
        draft.executable = "/fake/replacement"
        try session.save(draft)
        XCTAssertThrowsError(try session.activate(updatingConfiguration: true))
        XCTAssertTrue(try store.onboarding().completed)
        XCTAssertEqual(try store.settings().executable, "/fake/dsh")
        _ = try session.beginTest()
        try await session.testPipeline.pump()
        try session.activate(updatingConfiguration: true)
        XCTAssertTrue(try store.onboarding().completed)
        XCTAssertEqual(try store.settings().executable, "/fake/replacement")
    }
    func testSyntheticAndAtomicFinalConsent() async throws {
        let store = try PipelineStore(directory: root()), fake = FakeReplyModel()
        var active = PipelineSettings(); active.paused = true; try store.saveSettings(active)
        let session = try OnboardingSession(store: store, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.extensionAcknowledged = true
        try session.save(draft)
        let scope = try AccountScope(accountID: "synthetic", accountName: "Synthetic", mailboxName: "INBOX")
        let scopes = [scope, try AccountScope(accountID: "second", accountName: "Other", mailboxName: "INBOX")]
        draft.selectedScopes = scopes; try session.save(draft)
        XCTAssertThrowsError(try session.activate())
        _ = try session.beginTest()
        XCTAssertThrowsError(try session.beginTest())
        try await session.testPipeline.pump()
        XCTAssertEqual(try session.testResult()?.state, .draftReady)
        XCTAssertNil(try store.settings().permission)
        XCTAssertTrue(try store.settings().paused)
        try session.activate()
        let permission = try store.settings().permission
        XCTAssertNotNil(permission); XCTAssertTrue(try store.settings().paused)
        XCTAssertTrue(try store.settings().authorizedScopes.isEmpty)
        XCTAssertEqual(try store.settings().permission?.delivery, .mailKit)
        XCTAssertTrue(try store.onboarding().completed)
        try session.activate()
        XCTAssertEqual(try store.settings().permission, permission)
        let count = await fake.calls; XCTAssertEqual(count, 1)
    }
    func testLegacyMailboxSelectionsDoNotLimitMailKitConsent() async throws {
        let store = try PipelineStore(directory: root()), fake = FakeReplyModel()
        let session = try OnboardingSession(store: store, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.extensionAcknowledged = true
        let scopes = try ["INBOX", "Archive"].map { try AccountScope(accountID: "same-account", accountName: "Synthetic", mailboxName: $0) }
        draft.selectedScopes = scopes; try session.save(draft)
        _ = try session.beginTest(); try await session.testPipeline.pump()
        try session.activate()
        XCTAssertEqual(try store.settings().permission?.delivery, .mailKit)
        XCTAssertTrue(try store.settings().authorizedScopes.isEmpty)
    }
    func testChangingToolInvalidatesEvidence() async throws {
        let store = try PipelineStore(directory: root()), fake = FakeReplyModel()
        let session = try OnboardingSession(store: store, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; try session.save(draft)
        _ = try session.beginTest(); try await session.testPipeline.pump()
        draft = try store.onboarding(); draft.executable = "/fake/other"; try session.save(draft)
        XCTAssertNil(try store.onboarding().testID)
        XCTAssertNil(try store.settings().executable)
    }
    func testSwitchToClaudeRequiresNewTestAndGrantAndSkipsOldMail() async throws {
        let path = try root(), store = try PipelineStore(directory: path)
        let dsh = FakeReplyModel()
        let claude = FakeReplyModel(harness: .claude, actualModel: "fixture-flash")
        let session = try OnboardingSession(store: store, model: { $0.kind == .claude ? claude : dsh })
        var draft = OnboardingDraft()
        draft.executable = "/fake/dsh"; draft.extensionAcknowledged = true
        try session.save(draft)
        _ = try session.beginTest(); try await session.testPipeline.pump(); try session.activate()
        let oldGrant = try XCTUnwrap(store.settings().permission)
        let raw = Data("Content-Type: text/plain\r\n\r\nPlease reply.".utf8)
        let oldRecord = try store.importCapture(InboundCapture(permissionID: oldGrant.id, subject: "First",
            messageID: "first@example.com", raw: raw))
        draft = try store.onboarding(); draft.harnessKind = .claude
        try session.save(draft)
        XCTAssertNil(try session.testResult())
        XCTAssertThrowsError(try session.activate(updatingConfiguration: true))
        XCTAssertEqual(try store.settings().permission, oldGrant)
        draft.executable = "/fake/claude"; try session.save(draft)
        _ = try session.beginTest(); try await session.testPipeline.pump()
        try session.activate(updatingConfiguration: true)
        let active = try store.settings()
        XCTAssertEqual(active.harnessKind, .claude)
        let newGrant = try XCTUnwrap(active.permission)
        XCTAssertNotEqual(newGrant.id, oldGrant.id)
        let nextID = try store.importCapture(InboundCapture(permissionID: newGrant.id, subject: "Second",
            messageID: "second@example.com", raw: raw))
        let pipeline = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: path.appendingPathComponent("inbox")),
            resolve: { _, _ in XCTFail("Direct delivery cannot query Mail"); return nil }, model: { selection in
                XCTAssertEqual(selection.kind, .claude); XCTAssertEqual(selection.executable.path, "/fake/claude"); return claude
            })
        try await pipeline.pump()
        XCTAssertEqual(try store.record(oldRecord)?.state, .cancelled)
        let next = try XCTUnwrap(store.record(nextID))
        XCTAssertEqual(next.state, .draftReady)
        let run = try XCTUnwrap(next.runs.last)
        XCTAssertEqual(run.destination.harness, .claude)
        XCTAssertEqual(run.destination.model, "fixture-flash")
        XCTAssertNil(run.destination.vendor)
        XCTAssertEqual(run.destination.evidence, .detected)
        XCTAssertNil(run.actualCost)
        XCTAssertThrowsError(try pipeline.regenerate(nextID, approvedPullRequest: "https://github.com/example/example/pull/1"))
        let calls = await claude.calls
        XCTAssertEqual(calls, 2)
    }
    func testAbandonedTestDoesNotRunWithReplacement() async throws {
        let store = try PipelineStore(directory: root()), fake = FakeReplyModel()
        let session = try OnboardingSession(store: store, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; try session.save(draft)
        let abandoned = try session.beginTest()
        try session.resetTest()
        _ = try session.beginTest(); try await session.testPipeline.pump()
        XCTAssertEqual(try session.testPipeline.store.record(abandoned)?.state, .cancelled)
        let count = await fake.calls; XCTAssertEqual(count, 1)
    }
    func testReopenDoesNotRunPendingTest() async throws {
        let path = try root(), fake = FakeReplyModel()
        var store: PipelineStore? = try PipelineStore(directory: path)
        var session: OnboardingSession? = try OnboardingSession(store: store!, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; try session!.save(draft)
        _ = try session!.beginTest()
        session = nil; store = nil
        let reopened = try OnboardingSession(store: PipelineStore(directory: path), model: { _ in fake })
        XCTAssertNotNil(try reopened.testResult())
        let count = await fake.calls; XCTAssertEqual(count, 0)
        XCTAssertThrowsError(try reopened.beginTest())
    }
}

@MainActor
final class OnboardingCompletionTests: XCTestCase {
    func makeSession(_ fake: FakeReplyModel) throws -> OnboardingSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try OnboardingSession(store: PipelineStore(directory: root), model: { _ in fake })
    }
    func testEveryLevelCompletesWithoutHigherLevelCalls() async throws {
        for level in [ServiceLevel.l0, .l1, .l2] {
            let fake = FakeReplyModel(), isolated = try makeSession(fake)
            var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.level = level
            draft.extensionAcknowledged = true
            try isolated.save(draft); _ = try isolated.beginTest(); try await isolated.testPipeline.pump()
            XCTAssertTrue(OnboardingSession.testPassed(try isolated.testResult(), level: level))
            try isolated.activate()
            XCTAssertTrue(try isolated.store.onboarding().completed)
            XCTAssertEqual(try isolated.store.settings().permission?.delivery, .mailKit)
            XCTAssertTrue(try isolated.store.settings().authorizedScopes.isEmpty)
            let calls = await fake.calls; XCTAssertEqual(calls, 1)
        }
    }
    func testLevelChangeInvalidatesEvidenceAndDirectDraftPasses() async throws {
        let fake = FakeReplyModel(), session = try makeSession(fake)
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.level = .l1
        try session.save(draft); _ = try session.beginTest(); try await session.testPipeline.pump()
        draft = try session.store.onboarding(); draft.level = .l2; try session.save(draft)
        XCTAssertNil(try session.testResult())
        for decision in ["no", "unknown"] {
            let other = try makeSession(FakeReplyModel(shouldReply: decision))
            var input = OnboardingDraft(); input.executable = "/fake/dsh"; input.level = .l1; input.extensionAcknowledged = true
            try other.save(input); _ = try other.beginTest(); try await other.testPipeline.pump()
            try other.activate()
        }
    }
    func testLegacyManualPolicyRequiresNewMailKitConsentAndPreservesPause() async throws {
        let session = try makeSession(FakeReplyModel())
        var settings = PipelineSettings()
        settings.suggestionsOnly = true
        settings.paused = true
        settings.executable = "/fake/dsh"
        settings.permission = CapturePermission()
        settings.scope = try AccountScope(accountID: "synthetic", accountName: "Example", mailboxName: "INBOX")
        try session.store.saveSettings(settings)

        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"
        try session.save(draft); _ = try session.beginTest(); try await session.testPipeline.pump()
        draft = try session.store.onboarding()
        draft.step = 5
        draft.suggestionsOnly = true
        draft.extensionAcknowledged = true
        try session.store.saveOnboarding(draft)
        XCTAssertThrowsError(try session.store.activateOnboarding(draft))
        XCTAssertEqual(try session.store.onboarding().step, 3)
        XCTAssertThrowsError(try session.activate())

        draft.completed = true
        try session.store.saveOnboarding(draft)
        var recovered = try session.store.onboarding()
        XCTAssertTrue(recovered.completed)
        XCTAssertFalse(recovered.extensionAcknowledged)
        try session.activate()
        XCTAssertThrowsError(try session.activate(updatingConfiguration: true))
        XCTAssertNil(try session.store.settings().permission)
        XCTAssertTrue(try session.store.settings().authorizedScopes.isEmpty)

        recovered.extensionAcknowledged = true
        try session.save(recovered)
        XCTAssertNil(try session.store.settings().permission)
        try session.activate(updatingConfiguration: true)
        XCTAssertEqual(try session.store.settings().permission?.delivery, .mailKit)
        XCTAssertTrue(try session.store.settings().paused)
    }
}

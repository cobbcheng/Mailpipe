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
    func testSyntheticAndAtomicFinalConsent() async throws {
        let store = try PipelineStore(directory: root()), fake = FakeReplyModel()
        var active = PipelineSettings(); active.paused = true; try store.saveSettings(active)
        let session = try OnboardingSession(store: store, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.extensionAcknowledged = true
        try session.save(draft)
        let scope = try AccountScope(accountID: "synthetic", accountName: "Synthetic", mailboxName: "INBOX")
        let scopes = [scope, try AccountScope(accountID: "second", accountName: "Other", mailboxName: "INBOX")]
        draft.selectedScopes = scopes; try session.save(draft)
        XCTAssertThrowsError(try session.activate(scopes: scopes))
        _ = try session.beginTest()
        XCTAssertThrowsError(try session.beginTest())
        try await session.testPipeline.pump()
        XCTAssertEqual(try session.testResult()?.state, .draftReady)
        XCTAssertNil(try store.settings().permission)
        XCTAssertTrue(try store.settings().paused)
        try session.activate(scopes: scopes)
        let permission = try store.settings().permission
        XCTAssertNotNil(permission); XCTAssertTrue(try store.settings().paused)
        XCTAssertEqual(try store.settings().authorizedScopes, scopes)
        XCTAssertTrue(try store.onboarding().completed)
        try session.activate(scopes: scopes)
        XCTAssertEqual(try store.settings().permission, permission)
        let count = await fake.calls; XCTAssertEqual(count, 2)
    }
    func testOneInboxPerAccountAtConfirmation() async throws {
        let store = try PipelineStore(directory: root()), fake = FakeReplyModel()
        let session = try OnboardingSession(store: store, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.extensionAcknowledged = true
        let scopes = try ["INBOX", "Archive"].map { try AccountScope(accountID: "same-account", accountName: "Synthetic", mailboxName: $0) }
        draft.selectedScopes = scopes; try session.save(draft)
        _ = try session.beginTest(); try await session.testPipeline.pump()
        XCTAssertThrowsError(try session.activate(scopes: scopes))
        XCTAssertNil(try store.settings().permission)
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
    func testAbandonedTestDoesNotRunWithReplacement() async throws {
        let store = try PipelineStore(directory: root()), fake = FakeReplyModel()
        let session = try OnboardingSession(store: store, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; try session.save(draft)
        let abandoned = try session.beginTest()
        try session.resetTest()
        _ = try session.beginTest(); try await session.testPipeline.pump()
        XCTAssertEqual(try session.testPipeline.store.record(abandoned)?.state, .cancelled)
        let count = await fake.calls; XCTAssertEqual(count, 2)
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
            for manual in [false, true] {
                let fake = FakeReplyModel(), isolated = try makeSession(fake)
                let scope = try AccountScope(accountID: "synthetic", accountName: "Synthetic", mailboxName: "INBOX")
                var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.level = level
                draft.suggestionsOnly = manual; draft.extensionAcknowledged = !manual
                draft.selectedScopes = manual ? [] : [scope]
                try isolated.save(draft); _ = try isolated.beginTest(); try await isolated.testPipeline.pump()
                XCTAssertTrue(OnboardingSession.testPassed(try isolated.testResult(), level: level))
                try isolated.activate(scopes: draft.selections)
                XCTAssertTrue(try isolated.store.onboarding().completed)
                XCTAssertEqual(try isolated.store.settings().permission == nil, manual)
                XCTAssertEqual(try isolated.store.settings().authorizedScopes, draft.selections)
                let calls = await fake.calls; XCTAssertEqual(calls, level == .l2 ? 2 : 1)
            }
        }
    }
    func testLevelChangeInvalidatesEvidenceAndNonYesCannotPass() async throws {
        let fake = FakeReplyModel(), session = try makeSession(fake)
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.level = .l1
        try session.save(draft); _ = try session.beginTest(); try await session.testPipeline.pump()
        draft = try session.store.onboarding(); draft.level = .l2; try session.save(draft)
        XCTAssertNil(try session.testResult())
        for decision in ["no", "unknown"] {
            let other = try makeSession(FakeReplyModel(shouldReply: decision))
            var input = OnboardingDraft(); input.executable = "/fake/dsh"; input.level = .l1; input.suggestionsOnly = true
            try other.save(input); _ = try other.beginTest(); try await other.testPipeline.pump()
            XCTAssertThrowsError(try other.activate(scopes: []))
        }
    }
    func testSuggestionsRevokeAutomaticScopeAndPreservePause() async throws {
        let session = try makeSession(FakeReplyModel())
        var settings = PipelineSettings(); settings.paused = true; settings.permission = CapturePermission()
        settings.scope = try AccountScope(accountID: "synthetic", accountName: "Synthetic", mailboxName: "INBOX")
        try session.store.saveSettings(settings)
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.level = .l1; draft.suggestionsOnly = true
        try session.save(draft); _ = try session.beginTest(); try await session.testPipeline.pump()
        try session.activate(scopes: [])
        XCTAssertNil(try session.store.settings().permission)
        XCTAssertTrue(try session.store.settings().authorizedScopes.isEmpty)
        XCTAssertTrue(try session.store.settings().paused)
    }
}

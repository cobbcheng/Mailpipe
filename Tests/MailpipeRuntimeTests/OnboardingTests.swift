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
        var draft = OnboardingDraft(); draft.step = 4; draft.accountName = "Synthetic"; draft.mailboxName = "INBOX"
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
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.accountName = "Synthetic"; draft.mailboxName = "INBOX"; draft.extensionAcknowledged = true
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

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
    func testDraftRecoveryDoesNotAuthorizeOrResume() async throws {
        let path = try root()
        var store: PipelineStore? = try PipelineStore(directory: path)
        var active = PipelineSettings(); active.paused = true
        try await store!.saveSettings(active)
        var draft = OnboardingDraft(); draft.step = 4
        try await store!.saveOnboarding(draft); store = nil
        let reopened = try PipelineStore(directory: path)
        let savedDraft = try await reopened.onboarding()
        let savedSettings = try await reopened.settings()
        XCTAssertEqual(savedDraft, draft)
        XCTAssertNil(savedSettings.permission)
        XCTAssertTrue(savedSettings.paused)
    }
    func testResumesFormerSixthStepAtFinalReview() async throws {
        let store = try PipelineStore(directory: root())
        var draft = OnboardingDraft()
        draft.step = 6
        draft.exactSubject = "Project update"
        try await store.saveOnboarding(draft)
        draft.step = 5
        let loaded = try await store.onboarding()
        XCTAssertEqual(loaded, draft)
    }

    func testOnlyFinalReviewCanCompleteInitialSetup() async throws {
        let store = try PipelineStore(directory: root())
        let session = try OnboardingSession(store: store, model: { _ in FakeReplyModel() })
        var draft = OnboardingDraft()
        draft.step = 5
        draft.executable = "/fake/dsh"
        draft.extensionAcknowledged = true
        draft.completed = true
        try await session.save(draft)
        let stepAfterSave = try await store.onboarding().step
        XCTAssertEqual(stepAfterSave, 5)
        _ = try await session.beginTest()
        try await session.testPipeline.pump()

        do { try await session.activate(updatingConfiguration: true); XCTFail("must reject update before initial completion") } catch {}
        let completedBefore = try await store.onboarding().completed
        XCTAssertFalse(completedBefore)
        let executableBefore = try await store.settings().executable
        XCTAssertNil(executableBefore)
        try await session.activate()
        let completedAfter = try await store.onboarding().completed
        XCTAssertTrue(completedAfter)

        draft = try await store.onboarding()
        draft.completed = false
        draft.executable = "/fake/replacement"
        try await session.save(draft)
        do { try await session.activate(updatingConfiguration: true); XCTFail("must require fresh test") } catch {}
        let stillCompleted = try await store.onboarding().completed
        XCTAssertTrue(stillCompleted)
        let stillExecutable = try await store.settings().executable
        XCTAssertEqual(stillExecutable, "/fake/dsh")
        _ = try await session.beginTest()
        try await session.testPipeline.pump()
        try await session.activate(updatingConfiguration: true)
        let finalCompleted = try await store.onboarding().completed
        XCTAssertTrue(finalCompleted)
        let finalExecutable = try await store.settings().executable
        XCTAssertEqual(finalExecutable, "/fake/replacement")
    }
    func testSyntheticAndAtomicFinalConsent() async throws {
        let store = try PipelineStore(directory: root()), fake = FakeReplyModel()
        var active = PipelineSettings(); active.paused = true; try await store.saveSettings(active)
        let session = try OnboardingSession(store: store, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.extensionAcknowledged = true
        try await session.save(draft)
        let scope = try AccountScope(accountID: "synthetic", accountName: "Synthetic", mailboxName: "INBOX")
        let scopes = [scope, try AccountScope(accountID: "second", accountName: "Other", mailboxName: "INBOX")]
        draft.selectedScopes = scopes; try await session.save(draft)
        do { try await session.activate(); XCTFail("must require test") } catch {}
        _ = try await session.beginTest()
        do { _ = try await session.beginTest(); XCTFail("must reject duplicate test") } catch {}
        try await session.testPipeline.pump()
        let resultState = try await session.testResult()?.state
        XCTAssertEqual(resultState, .draftReady)
        let permBefore = try await store.settings().permission
        let pausedBefore = try await store.settings().paused
        XCTAssertNil(permBefore); XCTAssertTrue(pausedBefore)
        try await session.activate()
        let activeSettings = try await store.settings()
        let permission = activeSettings.permission
        XCTAssertNotNil(permission); XCTAssertTrue(activeSettings.paused)
        XCTAssertTrue(activeSettings.authorizedScopes.isEmpty)
        XCTAssertEqual(activeSettings.permission?.delivery, .mailKit)
        let completed = try await store.onboarding().completed
        XCTAssertTrue(completed)
        try await session.activate()
        let permAfter = try await store.settings().permission
        XCTAssertEqual(permAfter, permission)
        let count = await fake.calls; XCTAssertEqual(count, 1)
    }
    func testLegacyMailboxSelectionsDoNotLimitMailKitConsent() async throws {
        let store = try PipelineStore(directory: root()), fake = FakeReplyModel()
        let session = try OnboardingSession(store: store, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; draft.extensionAcknowledged = true
        let scopes = try ["INBOX", "Archive"].map { try AccountScope(accountID: "same-account", accountName: "Synthetic", mailboxName: $0) }
        draft.selectedScopes = scopes; try await session.save(draft)
        _ = try await session.beginTest(); try await session.testPipeline.pump()
        try await session.activate()
        let active = try await store.settings()
        XCTAssertEqual(active.permission?.delivery, .mailKit)
        XCTAssertTrue(active.authorizedScopes.isEmpty)
    }
    func testOlderAdapterEvidenceRequiresANewConnectionTest() async throws {
        let store = try PipelineStore(directory: root())
        let session = try OnboardingSession(store: store, model: { _ in FakeReplyModel(harness: .claude, actualModel: "fixture-claude") })
        var draft = OnboardingDraft()
        draft.harnessKind = .claude
        draft.executable = "/fake/claude"
        try await session.save(draft)
        _ = try await session.beginTest()
        try await session.testPipeline.pump()
        draft = try await store.onboarding()
        let result = try await session.testResult()
        XCTAssertTrue(OnboardingSession.testPassed(result, for: draft))
        draft.evidenceVersion = "claude-2.1.296/restricted-v1/reply-fixture-v1"
        try await store.saveOnboarding(draft)
        XCTAssertFalse(OnboardingSession.testPassed(result, for: draft))
        do { try await session.activate(); XCTFail("old evidence must be rejected") } catch {}
        try await session.save(draft)
        let clearedTestID = try await store.onboarding().testID
        XCTAssertNil(clearedTestID)
    }

    func testChangingToolInvalidatesEvidence() async throws {
        let store = try PipelineStore(directory: root()), fake = FakeReplyModel()
        let session = try OnboardingSession(store: store, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; try await session.save(draft)
        _ = try await session.beginTest(); try await session.testPipeline.pump()
        draft = try await store.onboarding(); draft.executable = "/fake/other"; try await session.save(draft)
        let testID = try await store.onboarding().testID
        let executable = try await store.settings().executable
        XCTAssertNil(testID)
        XCTAssertNil(executable)
    }
    func testSwitchFromDSHToClaudeRequiresNewGrantAndSkipsOldMail() async throws {
        try await checkSwitch(from: .deepseek, to: .claude)
    }
    func testSwitchFromClaudeToOpenCodeRequiresNewGrantAndSkipsOldMail() async throws {
        try await checkSwitch(from: .claude, to: .opencode)
    }
    func testChangingOpenCodeModelRequiresNewGrantAndSkipsOldMail() async throws {
        try await checkSwitch(from: .opencode, to: .opencode)
    }
    func testSwitchFromOpenCodeToOpenClawRequiresNewGrantAndSkipsOldMail() async throws {
        try await checkSwitch(from: .opencode, to: .openclaw)
    }

    func testSwitchFromOpenClawToHermesRequiresNewGrantAndSkipsOldMail() async throws {
        try await checkSwitch(from: .openclaw, to: .hermes)
    }

    private func checkSwitch(from original: HarnessKind, to replacement: HarnessKind) async throws {
        let path = try root(), store = try PipelineStore(directory: path)
        let ref = replacement == .opencode ? "fixture/flash" : "fixture-flash"
        let oldModel = FakeReplyModel(harness: original, actualModel: "fixture/original")
        let newModel = FakeReplyModel(harness: replacement, actualModel: ref)
        let session = try OnboardingSession(store: store, model: {
            if original == replacement { return $0.openCodeModel == ref ? newModel : oldModel }
            return $0.kind == replacement ? newModel : oldModel
        })
        var draft = OnboardingDraft()
        draft.harnessKind = original; draft.executable = "/fake/\(original.rawValue)"; draft.extensionAcknowledged = true
        try await session.save(draft)
        _ = try await session.beginTest(); try await session.testPipeline.pump(); try await session.activate()
        let oldGrant = try unwrap(try await store.settings().permission)
        let raw = Data("Content-Type: text/plain\r\n\r\nPlease reply.".utf8)
        let oldRecord = try await store.importCapture(InboundCapture(permissionID: oldGrant.id, subject: "First",
            messageID: "first@example.com", raw: raw))
        draft = try await store.onboarding(); draft.harnessKind = replacement
        if original == replacement { draft.openCodeModel = ref }
        try await session.save(draft)
        let missingResult = try await session.testResult()
        XCTAssertNil(missingResult)
        do { try await session.activate(updatingConfiguration: true); XCTFail("must test replacement") } catch {}
        let retainedGrant = try await store.settings().permission
        XCTAssertEqual(retainedGrant, oldGrant)
        draft.executable = "/fake/\(replacement.rawValue)"; try await session.save(draft)
        _ = try await session.beginTest(); try await session.testPipeline.pump()
        try await session.activate(updatingConfiguration: true)
        let active = try await store.settings()
        XCTAssertEqual(active.harnessKind, replacement)
        XCTAssertEqual(active.openCodeModel, replacement == .opencode ? ref : nil)
        let newGrant = try XCTUnwrap(active.permission)
        XCTAssertNotEqual(newGrant.id, oldGrant.id)
        let nextID = try await store.importCapture(InboundCapture(permissionID: newGrant.id, subject: "Second",
            messageID: "second@example.com", raw: raw))
        let pipeline = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: path.appendingPathComponent("inbox")),
            resolve: { _, _ in XCTFail("Direct delivery cannot query Mail"); return nil }, model: { selection in
                XCTAssertEqual(selection.kind, replacement)
                XCTAssertEqual(selection.executable.path, "/fake/\(replacement.rawValue)")
                XCTAssertEqual(selection.openCodeModel, active.openCodeModel)
                return newModel
            })
        try await pipeline.pump()
        let oldState = try await store.record(oldRecord)?.state
        XCTAssertEqual(oldState, .cancelled)
        let next = try unwrap(try await store.record(nextID))
        XCTAssertEqual(next.state, .draftReady)
        let run = try XCTUnwrap(next.runs.last)
        XCTAssertEqual(run.destination.harness, replacement)
        XCTAssertEqual(run.destination.model, ref)
        XCTAssertEqual(run.destination.vendor, [.openclaw, .hermes].contains(replacement) ? "deepseek-official" : nil)
        XCTAssertEqual(run.destination.evidence, .detected)
        XCTAssertNil(run.actualCost)
        do {
            try await pipeline.regenerate(nextID, approvedPullRequest: "https://github.com/example/example/pull/1")
            XCTFail("non-dsh PR review must fail")
        } catch {}
        let calls = await newModel.calls
        XCTAssertEqual(calls, 2)
    }
    func testOpenCodeCannotSubmitMailWithoutPinnedModel() async throws {
        let path = try root(), store = try PipelineStore(directory: path)
        var settings = PipelineSettings()
        settings.harnessKind = .opencode
        settings.executable = "/fake/opencode"
        let grant = CapturePermission(delivery: .mailKit)
        settings.permission = grant
        try await store.saveSettings(settings)
        let id = try await store.importCapture(InboundCapture(permissionID: grant.id, subject: "Sample",
            messageID: "sample@example.com", raw: Data("Content-Type: text/plain\r\n\r\nPlease reply.".utf8)))
        let pipeline = ReplyPipeline(store: store, inbox: try CaptureInbox(directory: path.appendingPathComponent("inbox")),
            resolve: { _, _ in nil }, model: { _ in XCTFail("unbound route reached model"); throw MailpipeError.routeNotAllowed })
        try await pipeline.pump()
        let saved = try unwrap(try await store.record(id))
        XCTAssertEqual(saved.state, .needsReview)
        XCTAssertEqual(saved.error, MailpipeError.routeNotAllowed.rawValue)
        XCTAssertTrue(saved.runs.isEmpty)
    }
    func testAbandonedTestDoesNotRunWithReplacement() async throws {
        let store = try PipelineStore(directory: root()), fake = FakeReplyModel()
        let session = try OnboardingSession(store: store, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; try await session.save(draft)
        let abandoned = try await session.beginTest()
        try await session.resetTest()
        _ = try await session.beginTest(); try await session.testPipeline.pump()
        let abandonedState = try await session.testPipeline.store.record(abandoned)?.state
        XCTAssertEqual(abandonedState, .cancelled)
        let count = await fake.calls; XCTAssertEqual(count, 1)
    }
    func testReopenDoesNotRunPendingTest() async throws {
        let path = try root(), fake = FakeReplyModel()
        var store: PipelineStore? = try PipelineStore(directory: path)
        var session: OnboardingSession? = try OnboardingSession(store: store!, model: { _ in fake })
        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"; try await session!.save(draft)
        _ = try await session!.beginTest()
        session = nil; store = nil
        let reopened = try OnboardingSession(store: PipelineStore(directory: path), model: { _ in fake })
        let result = try await reopened.testResult()
        XCTAssertNotNil(result)
        let count = await fake.calls; XCTAssertEqual(count, 0)
        do { _ = try await reopened.beginTest(); XCTFail("existing pending test must block beginTest") } catch {}
    }
}

@MainActor
final class OnboardingCompletionTests: XCTestCase {
    func makeSession(_ fake: FakeReplyModel) throws -> OnboardingSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try OnboardingSession(store: PipelineStore(directory: root), model: { _ in fake })
    }
    func testLegacyManualPolicyRequiresNewMailKitConsentAndPreservesPause() async throws {
        let session = try makeSession(FakeReplyModel())
        var settings = PipelineSettings()
        settings.suggestionsOnly = true
        settings.paused = true
        settings.executable = "/fake/dsh"
        settings.permission = CapturePermission()
        settings.scope = try AccountScope(accountID: "synthetic", accountName: "Example", mailboxName: "INBOX")
        try await session.store.saveSettings(settings)

        var draft = OnboardingDraft(); draft.executable = "/fake/dsh"
        try await session.save(draft); _ = try await session.beginTest(); try await session.testPipeline.pump()
        draft = try await session.store.onboarding()
        draft.step = 5
        draft.suggestionsOnly = true
        draft.extensionAcknowledged = true
        try await session.store.saveOnboarding(draft)
        do { try await session.store.activateOnboarding(draft); XCTFail("must reject suggestionsOnly") } catch {}
        let step = try await session.store.onboarding().step
        XCTAssertEqual(step, 3)
        do { try await session.activate(); XCTFail("must reject unacknowledged") } catch {}

        draft.completed = true
        try await session.store.saveOnboarding(draft)
        var recovered = try await session.store.onboarding()
        XCTAssertTrue(recovered.completed)
        XCTAssertFalse(recovered.extensionAcknowledged)
        try await session.activate()
        do { try await session.activate(updatingConfiguration: true); XCTFail("must require acknowledgement") } catch {}
        let settingsAfter = try await session.store.settings()
        XCTAssertNil(settingsAfter.permission)
        XCTAssertTrue(settingsAfter.authorizedScopes.isEmpty)

        recovered.extensionAcknowledged = true
        try await session.save(recovered)
        let permBefore = try await session.store.settings().permission
        XCTAssertNil(permBefore)
        try await session.activate(updatingConfiguration: true)
        let finalSettings = try await session.store.settings()
        XCTAssertEqual(finalSettings.permission?.delivery, .mailKit)
        XCTAssertTrue(finalSettings.paused)
    }
}

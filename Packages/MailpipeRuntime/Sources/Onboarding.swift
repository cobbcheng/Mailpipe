import Foundation
import MailpipeCore
import HarnessAdapters

public struct OnboardingDraft: Codable, Equatable, Sendable {
    public var id = UUID()
    public var step = 1
    public var selectedScopes: [AccountScope]?
    public var selections: [AccountScope] { selectedScopes ?? [] }
    public var exactSubject = ""
    private var selectedHarness: HarnessKind?
    public var harnessKind: HarnessKind {
        get { selectedHarness ?? .deepseek }
        set { selectedHarness = newValue }
    }
    public var executable = ""
    public var openCodeModel: String?
    public var testedOpenCodeModel: String?
    public var requestedModel: String? {
        guard harnessKind == .opencode,
              let model = openCodeModel?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        return model
    }
    public var automationDenied: Bool?
    var suggestionsOnly: Bool? // Decode progress saved by the retired manual intake mode.
    public var extensionAcknowledged = false
    public var completed = false
    public var testID: String?
    public var testedExecutable: String?
    public var evidenceVersion: String?
    public init() {}
}

/// Host-owned progress. Saving a draft never grants capture or changes active policy.
public actor OnboardingSession {
    private static func evidenceVersion(for kind: HarnessKind) -> String? {
        switch kind {
        case .deepseek: "dsh/restricted-v2/reply-fixture-v1"
        case .claude: "claude/restricted-v2/reply-fixture-v1"
        case .opencode: "opencode/restricted-v2/model-pin-v1/reply-fixture-v1"
        case .openclaw: "openclaw/restricted-v2/reply-fixture-v1"
        case .hermes: "hermes/restricted-v2/reply-fixture-v1"
        case .codex: "codex/restricted-v2/reply-fixture-v1"
        }
    }
    public nonisolated let store: PipelineStore
    public nonisolated let testPipeline: ReplyPipeline

    public init(store: PipelineStore, model: @escaping ReplyModelFactory = makeReplyModel) throws {
        self.store = store
        let root = store.directory.appendingPathComponent("onboarding-test")
        testPipeline = ReplyPipeline(store: try PipelineStore(directory: root),
            inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, _ in nil }, model: model)
    }

    private static func hasCurrentEvidence(_ draft: OnboardingDraft) -> Bool {
        draft.testedExecutable == draft.executable && draft.testedOpenCodeModel == draft.requestedModel &&
            draft.evidenceVersion == evidenceVersion(for: draft.harnessKind)
    }

    public func save(_ value: OnboardingDraft) async throws {
        var draft = value
        // Progress edits cannot complete initial setup or clear a prior consent receipt.
        draft.completed = try await store.onboarding().completed
        draft.step = min(5, max(1, draft.step))
        if !Self.hasCurrentEvidence(draft) {
            draft.testID = nil; draft.testedExecutable = nil; draft.testedOpenCodeModel = nil; draft.evidenceVersion = nil
        }
        try await store.saveOnboarding(draft)
    }

    public func testResult() async throws -> StoredReply? {
        guard let id = try await store.onboarding().testID else { return nil }
        return try await testPipeline.store.record(id)
    }

    /// Explicit click only; never pump this queue on launch or window reopening.
    public func beginTest() async throws -> String {
        var draft = try await store.onboarding()
        guard draft.executable.hasPrefix("/"), let evidence = Self.evidenceVersion(for: draft.harnessKind),
              draft.testID == nil else { throw MailpipeError.invalidInput }
        if let model = draft.requestedModel, !OpenCodeDialect.validModelReference(model) { throw MailpipeError.invalidInput }
        // Abandoned tests never join a later explicitly authorized test.
        for item in try await testPipeline.store.records() where [.awaitingAccount, .queued, .draftQueued].contains(item.state) {
            try await testPipeline.cancel(item.id)
        }
        let kind = draft.harnessKind, executable = draft.executable, requestedModel = draft.requestedModel
        try await testPipeline.updateSettings {
            $0.harnessKind = kind; $0.executable = executable
            $0.openCodeModel = requestedModel
        }
        let id = try await testPipeline.enqueueSynthetic()
        draft.testedOpenCodeModel = draft.requestedModel
        draft.testID = id; draft.testedExecutable = draft.executable; draft.evidenceVersion = evidence
        try await save(draft)
        return id
    }

    public func resetTest() async throws {
        if let item = try await testResult(), [.triaging, .drafting].contains(item.state) { throw MailpipeError.invalidInput }
        var draft = try await store.onboarding(); draft.testID = nil
        try await save(draft)
    }

    public static func testPassed(_ result: StoredReply?) -> Bool {
        guard let result, result.state == .draftReady, result.draft != nil,
              let run = result.runs.last else { return false }
        return run.destination.taskKind == .draft && run.finishedAt != nil && run.error == nil
    }

    public static func testPassed(_ result: StoredReply?, for draft: OnboardingDraft) -> Bool {
        hasCurrentEvidence(draft) && result?.id == draft.testID &&
            result?.runs.last?.destination.harness == draft.harnessKind && testPassed(result)
    }

    public func activate(updatingConfiguration: Bool = false) async throws {
        var draft = try await store.onboarding()
        if draft.completed && !updatingConfiguration { return }
        if updatingConfiguration && !draft.completed { throw MailpipeError.invalidInput }
        guard let test = try await testResult(), Self.testPassed(test, for: draft) else { throw MailpipeError.invalidInput }
        if draft.harnessKind == .opencode {
            guard draft.requestedModel == draft.testedOpenCodeModel,
                  let model = test.runs.last?.destination.model, OpenCodeDialect.validModelReference(model),
                  draft.requestedModel == nil || draft.requestedModel == model else { throw MailpipeError.invalidOutput }
            // A blank input authorizes only the sample. Bind future mail to its verified model.
            draft.openCodeModel = model
            draft.testedOpenCodeModel = model
        }
        try await store.activateOnboarding(draft)
    }
}

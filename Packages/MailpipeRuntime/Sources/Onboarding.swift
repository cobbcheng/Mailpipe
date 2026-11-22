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
    public var level: ServiceLevel = .default
    public var automationDenied: Bool?
    var suggestionsOnly: Bool? // Decode progress saved by the retired manual intake mode.
    public var testedLevel: ServiceLevel?
    public var extensionAcknowledged = false
    public var completed = false
    public var testID: String?
    public var testedExecutable: String?
    public var evidenceVersion: String?
    public init() {}
}

/// Host-owned progress. Saving a draft never grants capture or changes active policy.
@MainActor
public final class OnboardingSession {
    private static func evidenceVersion(for kind: HarnessKind) -> String? {
        switch kind {
        case .deepseek: "dsh-0.2.2-rc.1/restricted-v1/reply-fixture-v1"
        case .claude: "claude-2.1.296/restricted-v1/reply-fixture-v1"
        case .opencode: "opencode-2.3.0/restricted-v1/model-pin-v1/reply-fixture-v1"
        case .openclaw: "openclaw-2026.11.5/restricted-v1/reply-fixture-v1"
        case .hermes: "hermes-0.23.2/restricted-v1/reply-fixture-v1"
        case .codex: "codex-0.169.1/restricted-v1/reply-fixture-v1"
        }
    }
    public let store: PipelineStore
    public let testPipeline: ReplyPipeline
    public init(store: PipelineStore, model: @escaping ReplyModelFactory = makeReplyModel) throws {
        self.store = store
        let root = store.directory.appendingPathComponent("onboarding-test")
        testPipeline = ReplyPipeline(store: try PipelineStore(directory: root),
            inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, _ in nil }, model: model)
    }
    public func save(_ value: OnboardingDraft) throws {
        var draft = value
        // Progress edits cannot complete initial setup or clear a prior consent receipt.
        draft.completed = try store.onboarding().completed
        draft.step = min(6, max(1, draft.step))
        if draft.testedExecutable != draft.executable || draft.testedOpenCodeModel != draft.requestedModel || draft.evidenceVersion != Self.evidenceVersion(for: draft.harnessKind) || (draft.testedLevel ?? .l2) != draft.level {
            draft.testID = nil; draft.testedExecutable = nil; draft.testedOpenCodeModel = nil; draft.evidenceVersion = nil
        }
        try store.saveOnboarding(draft)
    }
    public func testResult() throws -> StoredReply? {
        guard let id = try store.onboarding().testID else { return nil }
        return try testPipeline.store.record(id)
    }
    /// Explicit click only; never pump this queue on launch or window reopening.
    public func beginTest() throws -> String {
        var draft = try store.onboarding()
        guard draft.executable.hasPrefix("/"), let evidence = Self.evidenceVersion(for: draft.harnessKind),
              draft.testID == nil else { throw MailpipeError.invalidInput }
        if let model = draft.requestedModel, !OpenCodeDialect.validModelReference(model) { throw MailpipeError.invalidInput }
        // Abandoned tests never join a later explicitly authorized test.
        for item in try testPipeline.store.records() where [.awaitingAccount, .queued, .draftQueued].contains(item.state) {
            try testPipeline.cancel(item.id)
        }
        try testPipeline.updateSettings {
            $0.harnessKind = draft.harnessKind; $0.executable = draft.executable; $0.level = draft.level
            $0.openCodeModel = draft.requestedModel
        }
        let id = try testPipeline.enqueueSynthetic()
        draft.testedOpenCodeModel = draft.requestedModel
        draft.testedLevel = draft.level
        draft.testID = id; draft.testedExecutable = draft.executable; draft.evidenceVersion = evidence
        try save(draft)
        return id
    }
    public func resetTest() throws {
        if let item = try testResult(), [.triaging, .drafting].contains(item.state) { throw MailpipeError.invalidInput }
        var draft = try store.onboarding(); draft.testID = nil
        try save(draft)
    }
    public static func testPassed(_ result: StoredReply?, level: ServiceLevel) -> Bool {
        guard let result, result.level == level, result.state == .draftReady, result.draft != nil,
              let run = result.runs.last else { return false }
        return run.destination.taskKind == .draft && run.finishedAt != nil && run.error == nil
    }
    public func activate(updatingConfiguration: Bool = false) throws {
        var draft = try store.onboarding()
        if draft.completed && !updatingConfiguration { return }
        if updatingConfiguration && !draft.completed { throw MailpipeError.invalidInput }
        guard draft.testedExecutable == draft.executable,
              let evidence = Self.evidenceVersion(for: draft.harnessKind), draft.evidenceVersion == evidence,
              let test = try testResult(), test.runs.last?.destination.harness == draft.harnessKind,
              Self.testPassed(test, level: draft.level) else { throw MailpipeError.invalidInput }
        if draft.harnessKind == .opencode {
            guard draft.requestedModel == draft.testedOpenCodeModel,
                  let model = test.runs.last?.destination.model, OpenCodeDialect.validModelReference(model),
                  draft.requestedModel == nil || draft.requestedModel == model else { throw MailpipeError.invalidOutput }
            // A blank input authorizes only the sample. Bind future mail to its verified model.
            draft.openCodeModel = model
            draft.testedOpenCodeModel = model
        }
        try store.activateOnboarding(draft)
    }
}

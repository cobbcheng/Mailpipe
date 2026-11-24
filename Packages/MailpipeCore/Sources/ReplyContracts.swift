import Foundation

/// Optional read-only external context granted explicitly by the host for a single draft run.
/// Adapters must reject any context they do not explicitly support.
public enum DraftExternalContext: Equatable, Sendable {
    case gitHubPullRequest(url: String, authenticated: Bool)
}

public enum GitHubPullRequestLink {
    public static func first(in body: String) -> String? {
        let pattern = #"https://github[.]com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*(?![A-Za-z0-9_/-])"#
        guard let range = body.range(of: pattern, options: .regularExpression) else { return nil }
        return String(body[range])
    }
}

public struct ReplyDraftRequest: Encodable, Sendable {
    public static let maxReplyInstructionLength = 4_000
    public let schemaVersion = 1
    public let taskKind = "reply_draft"
    public let requestID: String
    public let triageRequestID: String
    public let message: MailInput
    public let replyInstructions: String?
    /// Selects the output contract supplied by the host, independently of the mail content.
    public let allowsNoReply: Bool
    /// Host-only optional capability grant. Never decoded from model output or email.
    public var externalContext: DraftExternalContext?

    public static func normalizedReplyInstructions(_ value: String?) throws -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.unicodeScalars.count <= maxReplyInstructionLength else { throw MailpipeError.invalidInput }
        return text
    }

    public init(message: MailInput, allowsNoReply: Bool = false, replyInstructions: String? = nil,
                externalContext: DraftExternalContext? = nil) throws {
        requestID = message.messageRef + "-draft"
        // Schema v1 retains this correlation field for stored drafts and adapters.
        triageRequestID = message.messageRef + "-triage"
        self.message = message
        self.replyInstructions = try Self.normalizedReplyInstructions(replyInstructions)
        self.allowsNoReply = allowsNoReply
        self.externalContext = externalContext
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", taskKind = "task_kind", requestID = "request_id"
        case triageRequestID = "triage_request_id", message, replyInstructions = "reply_instructions"
    }

    public func validate() throws {
        guard !requestID.isEmpty, requestID.utf8.count <= 128, requestID != triageRequestID else {
            throw MailpipeError.invalidInput
        }
        try message.validate()
    }
}

/// Local pending content only. No recipients, executable actions, or send operation.
public struct ReplyDraft: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let triageRequestID: String
    public let messageRef: String
    public let subject: String
    public let body: String
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", requestID = "request_id", triageRequestID = "triage_request_id"
        case messageRef = "message_ref", subject, body
    }
    public static func validated(_ data: Data, for request: ReplyDraftRequest) throws -> Self {
        try request.validate()
        _ = try closedObject(data, keys: ["schema_version", "request_id", "triage_request_id", "message_ref", "subject", "body"])
        do {
            let draft = try JSONDecoder().decode(Self.self, from: data)
            guard draft.schemaVersion == 1, draft.requestID == request.requestID,
                  draft.triageRequestID == request.triageRequestID, draft.messageRef == request.message.messageRef,
                  !draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  draft.subject.utf8.count <= 2_048, draft.subject.rangeOfCharacter(from: .controlCharacters) == nil,
                  !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  draft.body.utf8.count <= 16_384 else { throw MailpipeError.invalidOutput }
            return draft
        } catch let error as MailpipeError { throw error }
        catch { throw MailpipeError.invalidOutput }
    }
}

public enum ReplyDraftOutcome: Equatable, Sendable {
    case draft(ReplyDraft)
    case noReply

    public static func validated(_ data: Data, for request: ReplyDraftRequest) throws -> Self {
        if request.allowsNoReply, (try? closedObject(data, keys: NoReply.fields)) != nil {
            try request.validate()
            guard let value = try? JSONDecoder().decode(NoReply.self, from: data),
                  value.schemaVersion == 1, value.disposition == "no_reply" else { throw MailpipeError.invalidOutput }
            guard value.requestID == request.requestID, value.triageRequestID == request.triageRequestID,
                  value.messageRef == request.message.messageRef else { throw MailpipeError.outputReference }
            return .noReply
        }
        return .draft(try ReplyDraft.validated(data, for: request))
    }

    private struct NoReply: Decodable {
        let schemaVersion: Int
        let requestID, triageRequestID, messageRef, disposition: String
        enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion = "schema_version", requestID = "request_id", triageRequestID = "triage_request_id"
            case messageRef = "message_ref", disposition
        }
        static let fields = Set(CodingKeys.allCases.map(\.rawValue))
    }
}

private func closedObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
    guard data.count <= 262_144 else { throw MailpipeError.outputLimit }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MailpipeError.outputJSON }
    guard Set(object.keys) == keys else { throw MailpipeError.outputFields }
    return object
}

public enum DestinationEvidence: String, Codable, Sendable { case detected, declared, unknown }
/// `.triage` is retained only so historical persisted runs remain decodable.
public enum ReplyTaskKind: String, Codable, Sendable { case triage, draft }

public struct DataDestination: Codable, Equatable, Sendable {
    public let messageRef: String
    public let runID: String
    public let taskKind: ReplyTaskKind
    public let harness: HarnessKind
    public let vendor: String?
    public let model: String?
    public let evidence: DestinationEvidence
    enum CodingKeys: String, CodingKey {
        case messageRef = "message_ref", runID = "run_id", taskKind = "task_kind", harness = "harness_id"
        case vendor, model, evidence
    }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(messageRef: fields.decode(String.self, forKey: .messageRef),
                      runID: fields.decode(String.self, forKey: .runID),
                      taskKind: fields.decode(ReplyTaskKind.self, forKey: .taskKind),
                      harness: fields.decode(HarnessKind.self, forKey: .harness),
                      vendor: fields.decodeIfPresent(String.self, forKey: .vendor),
                      model: fields.decodeIfPresent(String.self, forKey: .model),
                      evidence: fields.decode(DestinationEvidence.self, forKey: .evidence))
    }
    public init(messageRef: String, runID: String, taskKind: ReplyTaskKind, harness: HarnessKind,
                vendor: String? = nil, model: String? = nil, evidence: DestinationEvidence = .unknown) throws {
        guard !messageRef.isEmpty, !runID.isEmpty,
              evidence == .unknown ? (vendor == nil && model == nil) : (vendor != nil || model != nil),
              vendor == nil || vendor?.isEmpty == false,
              model == nil || model?.isEmpty == false else { throw MailpipeError.invalidInput }
        self.messageRef = messageRef; self.runID = runID; self.taskKind = taskKind
        self.harness = harness; self.vendor = vendor; self.model = model; self.evidence = evidence
    }
}

public enum ReplySchemas {
    public static let draft = #"{"type":"object","additionalProperties":false,"required":["schema_version","request_id","triage_request_id","message_ref","subject","body"],"properties":{"schema_version":{"type":"integer","enum":[1]},"request_id":{"type":"string"},"triage_request_id":{"type":"string"},"message_ref":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string"}}}"#
    private static let noReply = #"{"type":"object","additionalProperties":false,"required":["schema_version","request_id","triage_request_id","message_ref","disposition"],"properties":{"schema_version":{"type":"integer","enum":[1]},"request_id":{"type":"string"},"triage_request_id":{"type":"string"},"message_ref":{"type":"string"},"disposition":{"type":"string","enum":["no_reply"]}}}"#
    public static let automaticDraft = #"{"oneOf":[\#(draft),\#(noReply)]}"#
}

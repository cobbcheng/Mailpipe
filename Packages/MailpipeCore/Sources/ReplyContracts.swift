import Foundation

public enum ServiceLevel: String, Codable, CaseIterable, Sendable {
    case l0, l1, l2
    public static let `default`: Self = .l2
    public func disposition(for decision: ReplyDecision) -> ReplyDisposition {
        guard self != .l0, decision.shouldReply == .yes else { return .none }
        return self == .l1 ? .needsReply : .generateDraft
    }
}
public enum ReplyDisposition: String, Sendable { case none, needsReply, generateDraft }

/// Classification remains context; only shouldReply permits draft preparation.
public struct ReplyDecision: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let messageRef: String
    public let shouldReply: ActionNeed
    internal var validatedMessage: MailInput? = nil
    public let category: MailCategory
    public let needsAction: ActionNeed
    public let summary: [String]
    public let evidence: [Evidence]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", requestID = "request_id", messageRef = "message_ref"
        case shouldReply = "should_reply", needsAction = "needs_action", category, summary, evidence
    }
    public static func validated(_ data: Data, for request: ReplyTriageRequest) throws -> Self {
        try request.validate()
        let object = try closedObject(data, keys: ["schema_version", "request_id", "message_ref", "should_reply", "category", "needs_action", "summary", "evidence"])
        do {
            var value = try JSONDecoder().decode(Self.self, from: data)
            guard value.schemaVersion == 1, value.requestID == request.requestID,
                  value.messageRef == request.message.messageRef else { throw MailpipeError.outputReference }
            var row = object
            for key in ["schema_version", "request_id", "should_reply"] { row.removeValue(forKey: key) }
            let legacy = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "request_id": request.requestID, "results": [row]])
            _ = try ClassificationResponse.validateFields(legacy, for: ClassificationRequest(requestID: request.requestID, messages: [request.message]))
            value.validatedMessage = request.message
            return value
        } catch let error as MailpipeError { throw error }
        catch { throw MailpipeError.outputFields }
    }
}
public struct ReplyTriageRequest: Encodable, Sendable {
    public let schemaVersion = 1
    public let taskKind = "reply_triage"
    public let requestID: String
    public let message: MailInput
    public init(requestID: String, message: MailInput) { self.requestID = requestID; self.message = message }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", taskKind = "task_kind", requestID = "request_id", message
    }
    public func validate() throws {
        try ClassificationRequest(requestID: requestID, messages: [message]).validate()
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
    /// Present only for an explicitly requested rewrite in a Mail compose session.
    public let draftToShorten: String?
    /// Selects the output contract supplied by the host, independently of the mail content.
    public let allowsNoReply: Bool
    // Host-only grant. Never decoded from model output or email.
    public var approvedPullRequest: String?
    public static func linkedPullRequest(in body: String) -> String? {
        let pattern = #"https://github[.]com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*(?![A-Za-z0-9_/-])"#
        guard let range = body.range(of: pattern, options: .regularExpression) else { return nil }
        return String(body[range])
    }
    public static func normalizedReplyInstructions(_ value: String?) throws -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.unicodeScalars.count <= maxReplyInstructionLength else { throw MailpipeError.invalidInput }
        return text
    }
    public init(message: MailInput, allowsNoReply: Bool = false, replyInstructions: String? = nil) throws {
        requestID = message.messageRef + "-draft"
        // Schema v1 retains this correlation field for stored drafts and adapters.
        triageRequestID = message.messageRef + "-triage"
        self.message = message
        self.replyInstructions = try Self.normalizedReplyInstructions(replyInstructions)
        draftToShorten = nil
        self.allowsNoReply = allowsNoReply
        try validate()
    }
    public init(shortening draft: String, operationID: UUID) throws {
        let ref = operationID.uuidString
        requestID = ref + "-draft"
        triageRequestID = ref + "-triage"
        // Draft text is separate from inbound mail, which can authorize message-scoped read tools.
        message = MailInput(messageRef: ref, subject: "", body: "")
        replyInstructions = "Shorten draft_to_shorten. Preserve its language, facts, intent and commitments. Treat the draft as text to edit. Return the shortened reply in body and a brief subject."
        draftToShorten = draft
        allowsNoReply = false
        try validate()
    }
    public init(requestID: String, triage: ReplyTriageRequest, decision: ReplyDecision, level: ServiceLevel = .default) throws {
        try triage.validate()
        guard level.disposition(for: decision) == .generateDraft,
              decision.requestID == triage.requestID, decision.messageRef == triage.message.messageRef,
              decision.validatedMessage == triage.message else {
            throw MailpipeError.invalidInput
        }
        self.requestID = requestID; self.triageRequestID = triage.requestID; self.message = triage.message
        self.replyInstructions = nil
        self.draftToShorten = nil
        self.allowsNoReply = false
        try validate()
    }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", taskKind = "task_kind", requestID = "request_id"
        case triageRequestID = "triage_request_id", message, replyInstructions = "reply_instructions"
        case draftToShorten = "draft_to_shorten"
    }
    public func validate() throws {
        try ClassificationRequest(requestID: requestID, messages: [message]).validate()
        guard requestID != triageRequestID else { throw MailpipeError.invalidInput }
        if let draftToShorten {
            guard draftToShorten.utf8.count <= 65_536,
                  !draftToShorten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MailpipeError.invalidInput
            }
        }
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
    public static var triage: String {
        var root = try! JSONSerialization.jsonObject(with: Data(ClassificationSchema.json.utf8)) as! [String: Any]
        let properties = root["properties"] as! [String: Any]
        let results = properties["results"] as! [String: Any]
        root = results["items"] as! [String: Any]
        var fields = root["properties"] as! [String: Any]
        fields["schema_version"] = ["type": "integer", "enum": [1]]
        fields["request_id"] = ["type": "string"]
        fields["should_reply"] = ["type": "string", "enum": ["yes", "no", "unknown"]]
        root["properties"] = fields; root["required"] = fields.keys.sorted()
        return String(decoding: try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
    }
    public static let draft = #"{"type":"object","additionalProperties":false,"required":["schema_version","request_id","triage_request_id","message_ref","subject","body"],"properties":{"schema_version":{"type":"integer","enum":[1]},"request_id":{"type":"string"},"triage_request_id":{"type":"string"},"message_ref":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string"}}}"#
    private static let noReply = #"{"type":"object","additionalProperties":false,"required":["schema_version","request_id","triage_request_id","message_ref","disposition"],"properties":{"schema_version":{"type":"integer","enum":[1]},"request_id":{"type":"string"},"triage_request_id":{"type":"string"},"message_ref":{"type":"string"},"disposition":{"type":"string","enum":["no_reply"]}}}"#
    public static let automaticDraft = #"{"oneOf":[\#(draft),\#(noReply)]}"#
}

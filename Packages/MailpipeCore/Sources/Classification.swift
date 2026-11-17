import Foundation

public enum MailpipeError: String, Error, Sendable, LocalizedError {
    case invalidInput, invalidOutput, unsupportedVersion, unsafeCapability
    case notInstalled, launchFailed, processFailed, timedOut, outputLimit, cancelled
    case authRequired, rateLimited, quotaExhausted, unknownAccount, routeNotAllowed, paused
    case mailBridgeUnavailable

    public var errorDescription: String? { rawValue }
}

public enum HarnessKind: String, CaseIterable, Codable, Sendable {
    case deepseek = "dsh", codex
    public var displayName: String { self == .deepseek ? "DeepSeek Harness" : "Codex CLI" }
}

public struct MailInput: Codable, Equatable, Sendable {
    public let messageRef: String
    public let subject: String
    public let body: String
    public init(messageRef: String, subject: String, body: String) {
        self.messageRef = messageRef; self.subject = subject; self.body = body
    }
    enum CodingKeys: String, CodingKey { case messageRef = "message_ref", subject, body }
}

public struct ClassificationRequest: Encodable, Equatable, Sendable {
    public let schemaVersion = 1
    public let taskKind = "classify"
    public let requestID: String
    public let messages: [MailInput]
    public init(requestID: String, messages: [MailInput]) {
        self.requestID = requestID; self.messages = messages
    }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", taskKind = "task_kind", requestID = "request_id", messages
    }
    public func validate() throws {
        guard !requestID.isEmpty, requestID.utf8.count <= 128, (1...10).contains(messages.count),
              Set(messages.map(\.messageRef)).count == messages.count,
              messages.allSatisfy({ !$0.messageRef.isEmpty && $0.messageRef.utf8.count <= 128 &&
                  $0.subject.utf8.count <= 2_048 && $0.body.utf8.count <= 16_384 }) else {
            throw MailpipeError.invalidInput
        }
    }
}

public enum MailCategory: String, Codable, Sendable {
    case customer, billing, notification, newsletter, other, unknown
}
public enum ActionNeed: String, Codable, Sendable { case yes, no, unknown }
public struct Evidence: Codable, Equatable, Sendable {
    public let field: String
    public let text: String
}
public struct Classification: Codable, Equatable, Sendable {
    public let messageRef: String
    public let category: MailCategory
    public let needsAction: ActionNeed
    public let summary: [String]
    public let evidence: [Evidence]
    enum CodingKeys: String, CodingKey {
        case messageRef = "message_ref", needsAction = "needs_action", category, summary, evidence
    }
}
public struct ClassificationResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let results: [Classification]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", requestID = "request_id", results }

    /// Codable alone ignores unknown keys. Check the closed shape before decoding.
    public static func validated(_ data: Data, for request: ClassificationRequest) throws -> Self {
        try request.validate()
        guard data.count <= 262_144 else { throw MailpipeError.outputLimit }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let root = object as? [String: Any],
                  Set(root.keys) == ["schema_version", "request_id", "results"],
                  let rows = root["results"] as? [[String: Any]] else { throw MailpipeError.invalidOutput }
            for row in rows {
                guard Set(row.keys) == ["message_ref", "category", "needs_action", "summary", "evidence"],
                      let evidence = row["evidence"] as? [[String: Any]],
                      evidence.allSatisfy({ Set($0.keys) == ["field", "text"] }) else {
                    throw MailpipeError.invalidOutput
                }
            }
            let response = try JSONDecoder().decode(Self.self, from: data)
            guard response.schemaVersion == 1, response.requestID == request.requestID,
                  response.results.count == request.messages.count,
                  Set(response.results.map(\.messageRef)) == Set(request.messages.map(\.messageRef)) else {
                throw MailpipeError.invalidOutput
            }
            for row in response.results {
                guard let input = request.messages.first(where: { $0.messageRef == row.messageRef }),
                      (1...3).contains(row.summary.count),
                      row.summary.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 280 }),
                      row.evidence.count <= 5 else { throw MailpipeError.invalidOutput }
                for proof in row.evidence {
                    let source: String
                    switch proof.field {
                    case "subject": source = input.subject
                    case "body": source = input.body
                    default: throw MailpipeError.invalidOutput
                    }
                    guard !proof.text.isEmpty, proof.text.count <= 500, source.contains(proof.text) else {
                        throw MailpipeError.invalidOutput
                    }
                }
            }
            return response
        } catch let error as MailpipeError { throw error }
        catch { throw MailpipeError.invalidOutput }
    }
}

public enum ClassificationSchema {
    public static let json = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "schema_version",
        "request_id",
        "results"
      ],
      "properties": {
        "schema_version": {
          "type": "integer",
          "enum": [
            1
          ]
        },
        "request_id": {
          "type": "string"
        },
        "results": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": [
              "message_ref",
              "category",
              "needs_action",
              "summary",
              "evidence"
            ],
            "properties": {
              "message_ref": {
                "type": "string"
              },
              "category": {
                "type": "string",
                "enum": [
                  "customer",
                  "billing",
                  "notification",
                  "newsletter",
                  "other",
                  "unknown"
                ]
              },
              "needs_action": {
                "type": "string",
                "enum": [
                  "yes",
                  "no",
                  "unknown"
                ]
              },
              "summary": {
                "type": "array",
                "items": {
                  "type": "string"
                },
                "minItems": 1,
                "maxItems": 3
              },
              "evidence": {
                "type": "array",
                "items": {
                  "type": "object",
                  "additionalProperties": false,
                  "required": [
                    "field",
                    "text"
                  ],
                  "properties": {
                    "field": {
                      "type": "string",
                      "enum": [
                        "subject",
                        "body"
                      ]
                    },
                    "text": {
                      "type": "string"
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """#
}

public struct AccountRoute: Sendable {
    public let accountID: String?
    public let allowedHarnesses: Set<HarnessKind>
    public let paused: Bool
    public init(accountID: String?, allowedHarnesses: Set<HarnessKind>, paused: Bool = false) {
        self.accountID = accountID; self.allowedHarnesses = allowedHarnesses; self.paused = paused
    }
    public func authorize(_ harness: HarnessKind) throws {
        guard !paused else { throw MailpipeError.paused }
        guard let accountID, !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MailpipeError.unknownAccount
        }
        guard allowedHarnesses.contains(harness) else { throw MailpipeError.routeNotAllowed }
    }
}

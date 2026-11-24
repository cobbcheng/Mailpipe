import Foundation

public enum MailpipeError: String, Error, Sendable, LocalizedError {
    case invalidInput, invalidOutput, unsupportedVersion, unsafeCapability
    case notInstalled, launchFailed, processFailed, timedOut, outputLimit, cancelled
    case authRequired, rateLimited, quotaExhausted, unknownAccount, routeNotAllowed, paused
    case outputJSON, outputFields, outputReference, outputSummary, outputEvidence
    case mailBridgeUnavailable

    public var errorDescription: String? { rawValue }
}

public enum HarnessKind: String, CaseIterable, Codable, Sendable {
    case deepseek = "dsh", codex, claude, opencode, openclaw, hermes
    public var supportsReplyDrafts: Bool { true }

    public var displayName: String {
        switch self {
        case .deepseek: "DeepSeek Harness"
        case .codex: "Codex CLI"
        case .claude: "Claude Code"
        case .opencode: "OpenCode"
        case .openclaw: "OpenClaw"
        case .hermes: "Hermes Agent"
        }
    }
}

public struct MailInput: Codable, Equatable, Sendable {
    public let messageRef: String
    public let subject: String
    public let body: String
    public init(messageRef: String, subject: String, body: String) {
        self.messageRef = messageRef; self.subject = subject; self.body = body
    }
    enum CodingKeys: String, CodingKey { case messageRef = "message_ref", subject, body }

    public func validate() throws {
        guard !messageRef.isEmpty, messageRef.utf8.count <= 128,
              subject.utf8.count <= 2_048, body.utf8.count <= 16_384 else {
            throw MailpipeError.invalidInput
        }
    }
}

public struct AccountRoute: Sendable {
    public let accountID: String?
    private let capturePermission: UUID?
    public let allowedHarnesses: Set<HarnessKind>
    public let paused: Bool
    public init(accountID: String?, allowedHarnesses: Set<HarnessKind>, paused: Bool = false) {
        self.capturePermission = nil
        self.accountID = accountID; self.allowedHarnesses = allowedHarnesses; self.paused = paused
    }
    public init(mailKitPermission: UUID, allowedHarnesses: Set<HarnessKind>) {
        capturePermission = mailKitPermission; accountID = nil
        self.allowedHarnesses = allowedHarnesses; paused = false
    }
    public func authorize(_ harness: HarnessKind) throws {
        guard !paused else { throw MailpipeError.paused }
        guard capturePermission != nil || accountID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw MailpipeError.unknownAccount
        }
        guard allowedHarnesses.contains(harness) else { throw MailpipeError.routeNotAllowed }
    }
}

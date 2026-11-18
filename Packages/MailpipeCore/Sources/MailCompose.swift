import Foundation

public enum MailComposeError: String, Error, Sendable, LocalizedError {
    case unavailable, invalidRecipient, changedSinceConfirmation, alreadyAttempted, outcomeUnknown
    public var errorDescription: String? { rawValue }
}
/// A human-confirmed handoff only. Never a model tool or a send operation.
public struct MailComposeRequest: Codable, Equatable, Sendable {
    public let recordID: String
    public let accountID: String
    public let accountName: String
    public let sender: String
    public let recipients: [String]
    public let subject: String
    public let body: String
    public let originalSubject: String
    public let messageID: String
    public let localID: String
    public let sourceDigest: String
    public let settingsRevision: UUID
    public init(recordID: String, accountID: String, accountName: String, sender: String, recipients: [String], subject: String, body: String, originalSubject: String, messageID: String, localID: String, sourceDigest: String, settingsRevision: UUID) throws {
        guard !recordID.isEmpty, !accountID.isEmpty, !localID.isEmpty, !messageID.isEmpty,
              Self.validAddress(sender), (1...20).contains(recipients.count), recipients.allSatisfy(Self.validAddress),
              !subject.contains("\r"), !subject.contains("\n"), subject.utf8.count <= 2_048,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 65_536 else { throw MailComposeError.invalidRecipient }
        self.recordID = recordID; self.accountID = accountID; self.accountName = accountName
        self.sender = sender; self.recipients = recipients; self.subject = subject; self.body = body
        self.originalSubject = originalSubject; self.messageID = messageID; self.localID = localID
        self.sourceDigest = sourceDigest; self.settingsRevision = settingsRevision
    }
    public static func validAddress(_ value: String) -> Bool {
        value.utf8.count <= 998 && value.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
    }
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return contentDigest((try? encoder.encode(self)) ?? Data())
    }
}
public struct MailComposeReceipt: Codable, Equatable, Sendable {
    public let outgoingID: String
    public init(outgoingID: String) { self.outgoingID = outgoingID }
}
public struct MailComposeHandoff: Codable, Sendable {
    public let fingerprint: String
    public let startedAt: Date
    public var receipt: MailComposeReceipt?
    /// Nil receipt includes an interrupted/unknown outcome and must never auto-replay.
    public init(fingerprint: String) { self.fingerprint = fingerprint; startedAt = Date() }
}

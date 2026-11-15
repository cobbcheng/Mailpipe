import Foundation
import MailpipeCore

public struct MailLocator: Sendable, Equatable {
    public let accountID: String
    public let mailboxID: String
    public let localMessageID: String
    public init(accountID: String, mailboxID: String, localMessageID: String) {
        self.accountID = accountID; self.mailboxID = mailboxID; self.localMessageID = localMessageID
    }
}
public struct MailSnapshot: Sendable, Equatable {
    public let locator: MailLocator
    public let isRead: Bool
    public let flagIndex: Int
    public init(locator: MailLocator, isRead: Bool, flagIndex: Int) {
        self.locator = locator; self.isRead = isRead; self.flagIndex = flagIndex
    }
}
public enum MailResolution: Sendable, Equatable {
    case unique(MailLocator), missing, ambiguous
}
/// No sending operation, arbitrary AppleScript, or implicit account scan is exposed.
public protocol MailReading: Sendable {
    func resolve(messageID: String, accountID: String) async throws -> MailResolution
    func snapshot(at locator: MailLocator) async throws -> MailSnapshot
}
/// Production placeholder fails closed until signed Apple Events identity tests exist.
public struct UnavailableMailBridge: MailReading {
    public init() {}
    public func resolve(messageID: String, accountID: String) async throws -> MailResolution {
        throw MailpipeError.mailBridgeUnavailable
    }
    public func snapshot(at locator: MailLocator) async throws -> MailSnapshot {
        throw MailpipeError.mailBridgeUnavailable
    }
}

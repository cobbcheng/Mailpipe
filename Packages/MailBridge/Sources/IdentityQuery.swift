import Foundation

public enum IdentityQueryError: Error { case invalidScope, automation(Int), invalidResult }
public struct IdentityQuery: Sendable {
    public let accountName: String
    public let mailboxName: String
    public let messageID: String
    public init(accountName: String, mailboxName: String, messageID: String) throws {
        let values = [accountName, mailboxName, messageID]
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 998 && !$0.contains("\n") && !$0.contains("\r") }) else { throw IdentityQueryError.invalidScope }
        self.accountName = accountName; self.mailboxName = mailboxName
        self.messageID = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !self.messageID.isEmpty else { throw IdentityQueryError.invalidScope }
    }
}

/// Read-only evidence, never a locator authorized for a write operation.
public struct IdentityQueryResult: Sendable {
    public let status: String
    public let accountID: String?
    public let localMessageID: String?
}

@MainActor
public enum AppleMailIdentityProbe {
    // All external strings are Apple event arguments, never interpolated into source.
    public static let scriptSource = """
    on probe(accountName, mailboxName, targetID)
        with timeout of 15 seconds
            tell application id "com.apple.mail"
                set accountMatches to every account whose name is accountName
                if (count of accountMatches) is not 1 then return {"accountAmbiguous"}
                set chosenAccount to item 1 of accountMatches
                set mailboxMatches to every mailbox of chosenAccount whose name is mailboxName
                if (count of mailboxMatches) is not 1 then return {"mailboxAmbiguous"}
                set chosenMailbox to item 1 of mailboxMatches
                set hits to (every message of chosenMailbox whose message id is targetID)
                if (count of hits) is 0 then return {"missing"}
                if (count of hits) is not 1 then return {"ambiguous"}
                set hit to item 1 of hits
                if (message id of hit) is not targetID then return {"changed"}
                if (id of account of mailbox of hit) is not (id of chosenAccount) then return {"changed"}
                return {"uniqueInScope", id of chosenAccount as text, id of hit as text}
            end tell
        end timeout
    end probe
    """
    public static func run(_ query: IdentityQuery) throws -> IdentityQueryResult {
        guard let script = NSAppleScript(source: scriptSource) else { throw IdentityQueryError.invalidResult }
        var error: NSDictionary?
        let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272,
            targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: "probe"), forKeyword: 0x736E616D)
        let arguments = NSAppleEventDescriptor.list()
        for (index, value) in [query.accountName, query.mailboxName, query.messageID].enumerated() {
            arguments.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        event.setParam(arguments, forKeyword: 0x2D2D2D2D)
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw IdentityQueryError.automation((error[NSAppleScript.errorNumber] as? Int) ?? -1) }
        guard let status = result.atIndex(1)?.stringValue,
              ["accountAmbiguous", "mailboxAmbiguous", "missing", "ambiguous", "changed", "uniqueInScope"].contains(status),
              result.numberOfItems == (status == "uniqueInScope" ? 3 : 1) else { throw IdentityQueryError.invalidResult }
        return IdentityQueryResult(status: status, accountID: result.atIndex(2)?.stringValue,
                                   localMessageID: result.atIndex(3)?.stringValue)
    }
}

/// Production read-only identity resolution. A match includes full normalized RFC822 source,
/// so a Message-ID collision cannot authorize unrelated content.
@MainActor
public enum AppleMailReplyIdentity {
    public struct Match: Sendable { public let accountID: String; public let localID: String; public let source: String }
    public static let scriptSource = """
    on resolveReply(accountID, mailboxName, targetID, expectedSubject)
        with timeout of 15 seconds
            tell application id "com.apple.mail"
                set accountsFound to every account whose id is accountID
                if (count of accountsFound) is not 1 then return {"unresolved"}
                set chosenAccount to item 1 of accountsFound
                set folders to every mailbox of chosenAccount whose name is mailboxName
                if (count of folders) is not 1 then return {"unresolved"}
                set hits to every message of item 1 of folders whose message id is targetID
                if (count of hits) is not 1 then return {"unresolved"}
                set hit to item 1 of hits
                if (subject of hit) is not expectedSubject then return {"unresolved"}
                if (id of account of mailbox of hit) is not accountID then return {"unresolved"}
                set rawSource to source of hit
                if (count of characters of rawSource) > 65536 then return {"unresolved"}
                return {"unique", id of chosenAccount as text, id of hit as text, rawSource}
            end tell
        end timeout
    end resolveReply
    """
    public static func resolve(accountID: String, mailboxName: String, messageID: String, subject: String) throws -> Match? {
        let values = [accountID, mailboxName, messageID, subject]
        guard values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }) else { throw IdentityQueryError.invalidScope }
        let result = try call(source: scriptSource, handler: "resolveReply", arguments: values)
        guard result.atIndex(1)?.stringValue == "unique", result.numberOfItems == 4,
              let account = result.atIndex(2)?.stringValue, account == accountID,
              let local = result.atIndex(3)?.stringValue,
              let source = result.atIndex(4)?.stringValue, source.utf8.count <= 65_536 else { return nil }
        return Match(accountID: account, localID: local, source: source)
    }
    public static func accountID(named name: String, mailbox: String) throws -> String {
        let source = """
        on selectScope(accountName, mailboxName)
            with timeout of 15 seconds
                tell application id "com.apple.mail"
                    set candidates to every account whose name is accountName
                    if (count of candidates) is not 1 then return ""
                    set selectedAccount to item 1 of candidates
                    set boxes to every mailbox of selectedAccount whose name is mailboxName
                    if (count of boxes) is not 1 then return ""
                    return id of selectedAccount as text
                end tell
            end timeout
        end selectScope
        """
        guard let id = try call(source: source, handler: "selectScope", arguments: [name, mailbox]).stringValue, !id.isEmpty else { throw IdentityQueryError.invalidScope }
        return id
    }
    private static func call(source: String, handler: String, arguments: [String]) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw IdentityQueryError.invalidResult }
        let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272, targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: 0x736E616D)
        let list = NSAppleEventDescriptor.list()
        for (index, value) in arguments.enumerated() { list.insert(NSAppleEventDescriptor(string: value), at: index + 1) }
        event.setParam(list, forKeyword: 0x2D2D2D2D)
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw IdentityQueryError.automation((error[NSAppleScript.errorNumber] as? Int) ?? -1) }
        return result
    }
}

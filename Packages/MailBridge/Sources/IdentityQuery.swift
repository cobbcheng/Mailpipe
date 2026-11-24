import Foundation
import MailpipeCore

public enum IdentityQueryError: Error, Codable, Equatable, Sendable { case invalidScope, automation(Int), invalidResult }

/// Production read-only identity resolution. A match includes full normalized RFC822 source,
/// so a Message-ID collision cannot authorize unrelated content.
@MainActor
public enum AppleMailReplyIdentity {
    public struct Match: Sendable, Codable { public let accountID: String; public let localID: String; public let source: String }
    public struct MailboxChoice: Sendable, Codable {
        public let accountID: String
        public let accountName: String
        public let path: [String]
    }
    private static let mailboxPathScript = """
    on pathForBox(box)
        set parts to {}
        set currentBox to box
        tell application id "com.apple.mail"
            repeat 33 times
                set parts to {name of currentBox as text} & parts
                try
                    set parentBox to container of currentBox
                on error errorMessage number errorNumber
                    if errorNumber is -1728 then return parts
                    error errorMessage number errorNumber
                end try
                if parentBox is missing value then return parts
                set currentBox to parentBox
            end repeat
        end tell
        error "Mailbox hierarchy too deep" number -2700
    end pathForBox
    """
    public static let catalogScript = """
    \(mailboxPathScript)
    on listMailboxes()
        set rows to {}
        with timeout of 15 seconds
            tell application id "com.apple.mail"
                set inboxes to every mailbox of inbox
                repeat with box in inboxes
                    set acct to account of box
                    if acct is not missing value then
                        set end of rows to {id of acct as text, name of acct as text, my pathForBox(box)}
                    end if
                end repeat
            end tell
        end timeout
        return rows
    end listMailboxes
    """
    public static func inboxes() throws -> [MailboxChoice] {
#if !os(macOS)
        throw IdentityQueryError.invalidResult
#else
        let result = try call(source: catalogScript, handler: "listMailboxes", arguments: [])
        var choices: [MailboxChoice] = []
        guard result.numberOfItems <= 2000 else { throw IdentityQueryError.invalidResult }
        for index in 0..<result.numberOfItems {
            guard let row = result.atIndex(index + 1), row.numberOfItems == 3,
                  let accountID = row.atIndex(1)?.stringValue, !accountID.isEmpty,
                  let accountName = row.atIndex(2)?.stringValue,
                  let parts = row.atIndex(3), parts.numberOfItems > 0, parts.numberOfItems <= 33 else { throw IdentityQueryError.invalidResult }
            var path: [String] = []
            for i in 0..<parts.numberOfItems {
                guard let name = parts.atIndex(i + 1)?.stringValue, !name.isEmpty else { throw IdentityQueryError.invalidResult }
                path.append(name)
            }
            choices.append(MailboxChoice(accountID: accountID, accountName: accountName, path: path))
        }
        return choices
#endif
    }
    // 4194304 matches MailBodyLimits.rawCeiling.
    public static let scriptSource = """
    \(mailboxPathScript)
    on resolveReply(accountID, mailboxName, targetID, expectedSubject, firstMatch, mailboxPath)
        with timeout of 15 seconds
            tell application id "com.apple.mail"
                set accountsFound to every account whose id is accountID
                if (count of accountsFound) is not 1 then return {"unresolved"}
                set chosenAccount to item 1 of accountsFound
                set folders to {}
                if (count of mailboxPath) is 0 then
                    set folders to every mailbox of chosenAccount whose name is mailboxName
                else
                    repeat with candidate in every mailbox of chosenAccount
                        if (my pathForBox(candidate)) is mailboxPath then set end of folders to contents of candidate
                    end repeat
                end if
                if (count of folders) is not 1 then return {"unresolved"}
                set selectedBox to item 1 of folders
                set hits to every message of selectedBox whose message id is targetID
                if (count of hits) is 0 then return {"unresolved"}
                if firstMatch is not "yes" and (count of hits) is not 1 then return {"unresolved"}
                set hit to item 1 of hits
                if (subject of hit) is not expectedSubject then return {"unresolved"}
                if (id of account of mailbox of hit) is not accountID then return {"unresolved"}
                if (junk mail status of hit) then return {"unresolved"}
                set rawSource to source of hit
                if (count of characters of rawSource) > 4194304 then return {"messageTooLarge"}
                return {"unique", id of chosenAccount as text, id of hit as text, rawSource}
            end tell
        end timeout
    end resolveReply
    """
    public static func resolve(accountID: String, mailboxName: String, messageID: String, subject: String, mailboxPath: [String]? = nil, firstMatch: Bool = false) throws -> Match? {
#if !os(macOS)
        throw IdentityQueryError.invalidResult
#else
        let values = [accountID, mailboxName, messageID, subject]
        guard values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }) else { throw IdentityQueryError.invalidScope }
        let path = mailboxPath ?? []
        guard (mailboxPath == nil || !path.isEmpty), path.count <= 33, path.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }) else { throw IdentityQueryError.invalidScope }
        let result = try call(source: scriptSource, handler: "resolveReply", arguments: values + [firstMatch ? "yes" : "no"], path: path)
        return try decodeMatch(result, accountID: accountID)
#endif
    }
#if os(macOS)
    static func decodeMatch(_ result: NSAppleEventDescriptor, accountID: String) throws -> Match? {
        if result.atIndex(1)?.stringValue == MailBodyRejection.messageTooLarge.rawValue {
            guard result.numberOfItems == 1 else { throw IdentityQueryError.invalidResult }
            throw MailBodyRejection.messageTooLarge
        }
        guard result.atIndex(1)?.stringValue == "unique", result.numberOfItems == 4,
              let account = result.atIndex(2)?.stringValue, account == accountID,
              let local = result.atIndex(3)?.stringValue,
              let source = result.atIndex(4)?.stringValue else { return nil }
        guard source.utf8.count <= MailBodyLimits.rawCeiling else { throw MailBodyRejection.messageTooLarge }
        return Match(accountID: account, localID: local, source: source)
    }
    private static func call(source: String, handler: String, arguments: [String], path: [String]? = nil) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw IdentityQueryError.invalidResult }
        let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272, targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: 0x736E616D)
        let list = NSAppleEventDescriptor.list()
        for (index, value) in arguments.enumerated() { list.insert(NSAppleEventDescriptor(string: value), at: index + 1) }
        if let path {
            let parts = NSAppleEventDescriptor.list()
            for (index, value) in path.enumerated() { parts.insert(NSAppleEventDescriptor(string: value), at: index + 1) }
            list.insert(parts, at: arguments.count + 1)
        }
        event.setParam(list, forKeyword: 0x2D2D2D2D)
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw IdentityQueryError.automation((error[NSAppleScript.errorNumber] as? Int) ?? -1) }
        return result
    }
#endif
}

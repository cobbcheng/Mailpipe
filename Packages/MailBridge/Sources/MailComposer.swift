import Foundation
import MailpipeCore
#if os(macOS)
import OSLog
#endif

/// Fixed Apple Events handlers. Data is passed as descriptors, never evaluated as script.
/// Creates a new compose window, not a threaded reply, and never sends.
@MainActor
public enum AppleMailComposer {
    private static let uniqueSenderScript = """
    on verifiedSender(accountID, targetAddress)
        tell application id "com.apple.mail"
            set owners to 0
            repeat with candidate in every account
                if (email addresses of candidate) contains targetAddress then
                    if (id of candidate) is not accountID then error "Ambiguous sender account" number -2700
                    set owners to owners + 1
                end if
            end repeat
            if owners is not 1 then error "Sender unavailable" number -2700
        end tell
        return targetAddress as text
    end verifiedSender
    """
    public static let senderScript = """
    \(uniqueSenderScript)
    on chooseSender(accountID, preferred)
        with timeout of 15 seconds
            tell application id "com.apple.mail"
                set matches to every account whose id is accountID
                if (count of matches) is not 1 then error "Account unavailable" number -2700
                set addresses to email addresses of item 1 of matches
                if (count of addresses) is 0 then error "No sender" number -2700
                repeat with target in preferred
                    if addresses contains (contents of target) then return my verifiedSender(accountID, contents of target)
                end repeat
                return my verifiedSender(accountID, item 1 of addresses)
            end tell
        end timeout
    end chooseSender
    """
    public static let composeScript = """
    \(uniqueSenderScript)
    on openCompose(accountID, expectedSender, targets, draftSubject, draftBody)
        set stage to "account"
        try
        with timeout of 15 seconds
            tell application id "com.apple.mail"
                set matches to every account whose id is accountID
                if (count of matches) is not 1 then error "Account unavailable" number -2700
                if (email addresses of item 1 of matches) does not contain expectedSender then error "Sender changed" number -2700
                my verifiedSender(accountID, expectedSender)
                set stage to "create"
                set outgoing to make new outgoing message with properties {visible:true, subject:draftSubject, content:draftBody, sender:expectedSender}
                set stage to "recipients"
                tell outgoing
                    repeat with target in targets
                        make new to recipient at end of to recipients with properties {address:contents of target}
                    end repeat
                end tell
                set stage to "activate"
                activate
                set stage to "readback"
                set actualTargets to address of every to recipient of outgoing
                return {id of outgoing as text, sender of outgoing as text, subject of outgoing as text, content of outgoing as text, actualTargets, visible of outgoing}
            end tell
        end timeout
        on error errorMessage number errorNumber
            return {"error", stage, errorNumber}
        end try
    end openCompose
    """
    public static func senderAddress(accountID: String, preferredRecipients: [String]) throws -> String {
#if os(macOS)
        guard !accountID.isEmpty, accountID.utf8.count <= 2048, preferredRecipients.count <= 200 else { throw MailComposeError.unavailable }
        let result = try call(senderScript, handler: "chooseSender", arguments: [.init(string: accountID), strings(preferredRecipients)])
        guard let address = result.stringValue, MailComposeRequest.validAddress(address) else { throw MailComposeError.unavailable }
        return address
#else
        throw MailComposeError.unavailable
#endif
    }
    public static func open(_ request: MailComposeRequest) throws -> MailComposeReceipt {
#if os(macOS)
        // Reconstruct to validate even values obtained through Codable rather than its initializer.
        _ = try MailComposeRequest(recordID: request.recordID, accountID: request.accountID, accountName: request.accountName,
            sender: request.sender, recipients: request.recipients, subject: request.subject, body: request.body,
            originalSubject: request.originalSubject, messageID: request.messageID, localID: request.localID,
            sourceDigest: request.sourceDigest, settingsRevision: request.settingsRevision)
        let result = try call(composeScript, handler: "openCompose", arguments: [.init(string: request.accountID),
            .init(string: request.sender), strings(request.recipients), .init(string: request.subject), .init(string: request.body)])
        return try decodeReceipt(result, request: request)
#else
        throw MailComposeError.unavailable
#endif
    }
#if os(macOS)
    static func decodeReceipt(_ result: NSAppleEventDescriptor, request: MailComposeRequest) throws -> MailComposeReceipt {
        guard result.numberOfItems == 6, result.atIndex(6)?.booleanValue == true, let id = result.atIndex(1)?.stringValue, !id.isEmpty,
              let sender = result.atIndex(2)?.stringValue,
              MailCorrespondents(Data(("From: " + sender + "\n\nbody").utf8))?.sender == request.sender,
              result.atIndex(3)?.stringValue == request.subject,
              let body = result.atIndex(4)?.stringValue,
              matchesMailBody(body, expected: request.body),
              let recipients = result.atIndex(5), recipients.numberOfItems == request.recipients.count else { throw MailComposeError.outcomeUnknown }
        for (index, expected) in request.recipients.enumerated() {
            guard recipients.atIndex(index + 1)?.stringValue == expected else { throw MailComposeError.outcomeUnknown }
        }
        return MailComposeReceipt(outgoingID: id)
    }
    // Mail's editor appends one terminal space or newline on some versions.
    // Preserve user-authored leading/trailing whitespace and reject other changes.
    static func matchesMailBody(_ actual: String, expected: String) -> Bool {
        let a = actual.replacingOccurrences(of: "\r\n", with: "\n")
        let e = expected.replacingOccurrences(of: "\r\n", with: "\n")
        return a == e || a == e + " " || a == e + "\n"
    }
    private static func logFailure(stage: String, code: Int) {
        let known = ["account", "create", "recipients", "show", "activate", "readback", "sender", "execute"]
        let safeStage = known.contains(stage) ? stage : "unknown"
        Logger(subsystem: "com.mailpipe.app", category: "compose").error("compose stage=\(safeStage, privacy: .public) code=\(code, privacy: .public)")
    }
    private static func strings(_ values: [String]) -> NSAppleEventDescriptor {
        let result = NSAppleEventDescriptor.list()
        for (index, value) in values.enumerated() { result.insert(.init(string: value), at: index + 1) }
        return result
    }
    private static func call(_ source: String, handler: String, arguments: [NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw MailComposeError.unavailable }
        let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272, targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(.init(string: handler), forKeyword: 0x736E616D)
        let args = NSAppleEventDescriptor.list()
        for (index, value) in arguments.enumerated() { args.insert(value, at: index + 1) }
        event.setParam(args, forKeyword: 0x2D2D2D2D)
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            logFailure(stage: handler == "chooseSender" ? "sender" : "execute", code: (error[NSAppleScript.errorNumber] as? Int) ?? 0)
            throw MailComposeError.outcomeUnknown
        }
        if result.numberOfItems == 3, result.atIndex(1)?.stringValue == "error" {
            logFailure(stage: result.atIndex(2)?.stringValue ?? "unknown", code: Int(result.atIndex(3)?.int32Value ?? 0))
            throw MailComposeError.outcomeUnknown
        }
        return result
    }
#endif
}

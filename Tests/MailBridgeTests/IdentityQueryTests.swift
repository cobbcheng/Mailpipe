import XCTest
@testable import MailBridge
import MailpipeCore

final class IdentityQueryTests: XCTestCase {
    @MainActor func testResolveRejectsJunkAndMatchesBodyCeiling() {
        XCTAssertTrue(AppleMailReplyIdentity.scriptSource.contains("junk mail status of hit"))
        XCTAssertTrue(AppleMailReplyIdentity.scriptSource.contains(String(MailBodyLimits.rawCeiling)))
        XCTAssertFalse(AppleMailReplyIdentity.scriptSource.contains("65536"))
    }
#if os(macOS)
    @MainActor func testOversizeSourceResultPreservesReasonWithoutIdentity() throws {
        let result = NSAppleEventDescriptor.list()
        result.insert(NSAppleEventDescriptor(string: "messageTooLarge"), at: 1)
        XCTAssertThrowsError(try AppleMailReplyIdentity.decodeMatch(result, accountID: "test")) { error in
            XCTAssertEqual(error as? MailBodyRejection, .messageTooLarge)
        }
        result.insert(NSAppleEventDescriptor(string: "unexpected"), at: 2)
        XCTAssertThrowsError(try AppleMailReplyIdentity.decodeMatch(result, accountID: "test")) { error in
            XCTAssertTrue(error is IdentityQueryError)
        }
    }

    @MainActor func testSourceUTF8ByteLimitAndAccountValidation() throws {
        let result = NSAppleEventDescriptor.list()
        for (index, value) in ["unique", "test", "one", "Readable source"].enumerated() {
            result.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        XCTAssertEqual(try AppleMailReplyIdentity.decodeMatch(result, accountID: "test")?.localID, "one")
        XCTAssertNil(try AppleMailReplyIdentity.decodeMatch(result, accountID: "other"))
        result.remove(at: 4)
        // Below the AppleScript character bound but above the UTF-8 byte bound.
        result.insert(NSAppleEventDescriptor(string: String(repeating: "中", count: MailBodyLimits.rawCeiling / 3 + 1)), at: 4)
        XCTAssertThrowsError(try AppleMailReplyIdentity.decodeMatch(result, accountID: "test")) { error in
            XCTAssertEqual(error as? MailBodyRejection, .messageTooLarge)
        }
    }

    @MainActor func testFixedReadOnlyScriptCompilesWithoutExecuting() {
        for source in [AppleMailReplyIdentity.catalogScript, AppleMailReplyIdentity.scriptSource, AppleMailReplyIdentity.junkOrTrashScript] {
            let script = NSAppleScript(source: source)!
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
        }
    }

    @MainActor func testJunkOrTrashScriptChecksJunkTrashAndPropagatesAutomationErrors() throws {
        let script = AppleMailReplyIdentity.junkOrTrashScript
        XCTAssertTrue(script.contains("junk mailbox"))
        XCTAssertTrue(script.contains("trash mailbox"))
        XCTAssertTrue(script.contains("junk mail status"))
        XCTAssertTrue(script.contains("deleted status"))
        XCTAssertTrue(script.contains("-1743"))
        XCTAssertTrue(script.contains("-1712"))

        XCTAssertEqual(try AppleMailReplyIdentity.classifyJunkOrTrash([]), [])
        XCTAssertThrowsError(try AppleMailReplyIdentity.classifyJunkOrTrash([
            MailMessageLookup(messageID: "", subject: "Synthetic")
        ])) { error in
            XCTAssertEqual(error as? IdentityQueryError, .invalidScope)
        }
        XCTAssertThrowsError(try AppleMailReplyIdentity.classifyJunkOrTrash(
            (0..<201).map { MailMessageLookup(messageID: "id-\($0)@example.com", subject: "Synthetic") }
        )) { error in
            XCTAssertEqual(error as? IdentityQueryError, .invalidScope)
        }

        let valid = NSAppleEventDescriptor.list()
        for (index, value) in ["active", "junkOrTrash", "unknown"].enumerated() {
            valid.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        XCTAssertEqual(try AppleMailReplyIdentity.decodeDispositions(valid, expectedCount: 3),
                       [.active, .junkOrTrash, .unknown])
        XCTAssertThrowsError(try AppleMailReplyIdentity.decodeDispositions(valid, expectedCount: 2)) { error in
            XCTAssertEqual(error as? IdentityQueryError, .invalidResult)
        }
        let malformed = NSAppleEventDescriptor.list()
        malformed.insert(NSAppleEventDescriptor(string: "unexpected"), at: 1)
        XCTAssertThrowsError(try AppleMailReplyIdentity.decodeDispositions(malformed, expectedCount: 1)) { error in
            XCTAssertEqual(error as? IdentityQueryError, .invalidResult)
        }
    }
#endif
}

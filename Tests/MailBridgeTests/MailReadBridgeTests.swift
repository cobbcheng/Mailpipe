#if os(macOS)
import Foundation
import HarnessAdapters
import MailpipeCore
import XCTest
@testable import MailBridge

private struct FixedReadResult: ProcessRunning {
    let output: ProcessOutput
    func run(_ invocation: ProcessInvocation) async throws -> ProcessOutput { output }
}

final class MailReadBridgeTests: XCTestCase {
    func testHelperPreservesUnknownMembershipAndTypedFailures() async throws {
        let fake = URL(fileURLWithPath: "/unused-test-helper")
        func bridge(_ result: MailReadResponse) throws -> MailReadBridge {
            MailReadBridge(executable: fake, runner: FixedReadResult(output: ProcessOutput(
                stdout: try PropertyListEncoder().encode(result))))
        }
        let unknown = try await bridge(.membership(nil)).isInAuthorizedInbox(
            accountID: "sample", mailboxName: "INBOX", messageID: "sample@example.com", subject: "Synthetic")
        XCTAssertNil(unknown)
        do {
            _ = try await bridge(.error(.automation(-1743))).inboxes()
            XCTFail("Denied automation was accepted")
        } catch IdentityQueryError.automation(-1743) {}
        do {
            _ = try await bridge(.messageTooLarge).resolve(accountID: "sample", mailboxName: "INBOX",
                messageID: "sample@example.com", subject: "Synthetic")
            XCTFail("An oversized source was accepted")
        } catch MailBodyRejection.messageTooLarge {}
        let malformed = MailReadBridge(executable: fake, runner: FixedReadResult(output: ProcessOutput(
            stdout: Data("invalid response".utf8), stderr: Data("private synthetic diagnostic".utf8))))
        do {
            _ = try await malformed.inboxes()
            XCTFail("Malformed output was accepted")
        } catch IdentityQueryError.invalidResult {}
    }

    @MainActor func testDelayedHelperLeavesMainActorFreeAndSerializesReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fake-mail-read")
        // The first helper waits for a main-actor action. Any overlapping child fails.
        let script = """
        #!/bin/sh
        set -eu
        root=${0%/*}
        test "$#" = 1
        test "$1" = "--mailpipe-read-helper"
        mkdir "$root/active"
        trap 'rmdir "$root/active"' EXIT
        cat > "$root/input"
        touch "$root/started"
        for n in $(/usr/bin/jot 250); do
            test -f "$root/release" && break
            /bin/sleep .02
        done
        test -f "$root/release"
        cat "$root/result"
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        // A result larger than a pipe buffer also exercises concurrent stdout drainage.
        let source = String(repeating: "Synthetic mail example.com\r\n", count: 9_000)
        let reply = MailReadResponse.match(.init(accountID: "sample", localID: "42", source: source))
        try PropertyListEncoder().encode(reply).write(to: directory.appendingPathComponent("result"))

        let bridge = MailReadBridge(executable: helper)
        func lookup(_ subject: String) async throws -> String? {
            try await bridge.resolve(accountID: "sample", mailboxName: "INBOX", messageID: "sample@example.com",
                                     subject: subject, mailboxPath: ["INBOX"])?.source
        }
        let first = Task { try await lookup("synthetic one") }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path) {
            guard clock.now < deadline else { first.cancel(); XCTFail("Fake Mail read did not start"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = Task { try await lookup("synthetic two") }
        let cancelled = Task { try await lookup("cancelled") }
        try await Task.sleep(for: .milliseconds(60))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Queued read unexpectedly succeeded")
        } catch is CancellationError {}
        // This is precisely the event the UI could not service during a synchronous read.
        try Data().write(to: directory.appendingPathComponent("release"))
        let firstSource = try await first.value
        let secondSource = try await second.value
        XCTAssertEqual(firstSource, source)
        XCTAssertEqual(secondSource, source)
        let lastRequest = try Data(contentsOf: directory.appendingPathComponent("input"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: lastRequest, format: nil) as? [String: Any])
        let arguments = try XCTUnwrap(plist["resolve"] as? [String: Any])
        let query = try XCTUnwrap(arguments["_0"] as? [String: Any])
        XCTAssertEqual(query["subject"] as? String, "synthetic two")
        XCTAssertEqual(query["messageID"] as? String, "sample@example.com")
    }
}
#endif

import XCTest
@testable import MailpipeCore

final class IdentityProbeTests: XCTestCase {
    func testExactScopeExpiryAndRevocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityProbeStore(directory: root)
        let now = Date()
        let scope = try store.begin(now: now)
        XCTAssertFalse(scope.accepts(subject: "ordinary mail", now: now))
        XCTAssertFalse(scope.accepts(subject: scope.subject, now: now.addingTimeInterval(900)))
        try store.capture(subject: "ordinary mail", headers: [:], now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("receipt.json").path))
        try store.capture(subject: scope.subject, headers: ["Message-ID": ["<synthetic@example.com>"], "From": ["private@example.com"]], now: now)
        XCTAssertEqual(try store.receipt(now: now)?.messageIDs, ["<synthetic@example.com>"])
        let bytes = try String(contentsOf: root.appendingPathComponent("receipt.json"), encoding: .utf8)
        XCTAssertFalse(bytes.contains("private@example.com"))
        _ = try store.begin(now: now)
        XCTAssertNil(try store.receipt(now: now))
        try store.stop()
        XCTAssertThrowsError(try store.capture(subject: scope.subject, headers: [:], now: now))
    }
    func testDuplicateAndMissingHeadersRemainAmbiguous() {
        let scope = IdentityProbeScope()
        XCTAssertEqual(IdentityProbeReceipt(scope: scope, headers: [:]).messageIDs, [])
        XCTAssertEqual(IdentityProbeReceipt(scope: scope, headers: ["message-id": ["a", "b", "c"]]).messageIDs.count, 2)
    }
}

extension IdentityProbeTests {
    func testDiagnosticStages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = IdentityProbeStore(directory: root)
        let now = Date()
        func expect(_ failure: ProbeReadFailure, at time: Date) {
            XCTAssertThrowsError(try store.diagnosedReceipt(now: time)) { XCTAssertEqual($0 as? ProbeReadFailure, failure) }
        }
        expect(.scopeMissing, at: now)
        let scope = try store.begin(now: now)
        expect(.receiptMissing, at: now)
        expect(.scopeExpired, at: now.addingTimeInterval(901))
        try Data("bad".utf8).write(to: root.appendingPathComponent("receipt.json"))
        expect(.receiptInvalid, at: now)
        try store.capture(subject: scope.subject, headers: [:], now: now)
        XCTAssertEqual(try store.diagnosedReceipt(now: now).nonce, scope.nonce)
        _ = try store.begin(now: now)
        expect(.receiptStale, at: now)
        try Data("bad".utf8).write(to: root.appendingPathComponent("scope.json"))
        expect(.scopeInvalid, at: now)
        try store.stop()
        expect(.scopeMissing, at: now)
    }
}

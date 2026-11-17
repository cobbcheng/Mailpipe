import XCTest
@testable import MailpipeRuntime
import MailpipeCore

@MainActor
final class CaptureSourceRecoveryTests: XCTestCase {
    func raw(type: String, payload: String) -> Data {
        Data(("From: sender@example.com\r\nTo: recipient@example.com\r\nDate: Tue, 17 Nov 2026 08:00:00 +0000\r\n"
            + "Subject: Synthetic\r\nMessage-ID: <source@example.com>\r\nContent-Type: \(type)\r\n\r\n" + payload).utf8)
    }
    func testFullSourceIsParsedAfterUniqueAccountProofAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = "--b\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n请确认周五。\r\n--b--\r\n"
        let captured = raw(type: "multipart/alternative", payload: payload)
        let source = raw(type: "multipart/alternative; boundary=b", payload: payload)
        let fake = FakeReplyModel()
        var pipeline: ReplyPipeline? = ReplyPipeline(store: try PipelineStore(directory: root.appendingPathComponent("state")),
            inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, _ in nil }, model: { _ in fake })
        try pipeline!.updateSettings {
            $0.permission = CapturePermission(); $0.executable = "/fake/dsh"
            $0.scope = try? AccountScope(accountID: "test", accountName: "test", mailboxName: "INBOX")
        }
        let permission = try XCTUnwrap(pipeline!.store.settings().permission)
        try pipeline!.inbox.publish(InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "source@example.com", raw: nil))
        try pipeline!.importInbox()
        let id = try XCTUnwrap(pipeline!.store.records().first?.id)
        try pipeline!.inbox.publish(InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "source@example.com", raw: captured))
        try pipeline!.importInbox()
        XCTAssertEqual(try pipeline!.store.records().count, 1)
        XCTAssertEqual(try pipeline!.store.record(id)?.state, .awaitingAccount)
        XCTAssertNotNil(try pipeline!.store.record(id)?.sourceEvidence)
        pipeline = nil
        let resumed = ReplyPipeline(store: try PipelineStore(directory: root.appendingPathComponent("state")),
            inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, scope in
                VerifiedMail(accountID: scope.accountID, localID: "one", source: source)
            }, model: { _ in fake })
        try await resumed.pump()
        let item = try XCTUnwrap(resumed.store.record(id))
        XCTAssertEqual(item.input.body, "请确认周五。")
        XCTAssertEqual(item.state, .draftReady)
        let count = await fake.calls; XCTAssertEqual(count, 2)
        try await resumed.pump()
        let unchanged = await fake.calls; XCTAssertEqual(unchanged, 2)
    }
    func testChangedMissingAmbiguousOrRevokedSourcesNeverReachModel() async throws {
        for mode in ["changed", "missing", "ambiguous", "revoked", "malformed"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let capture = raw(type: "text/plain", payload: "请确认周五。")
            let source = raw(type: mode == "malformed" ? "text/plain; charset=unknown" : "text/plain; charset=utf-8",
                payload: mode == "changed" ? "DIFFERENT" : "请确认周五。")
            let fake = FakeReplyModel()
            let pipeline = ReplyPipeline(store: try PipelineStore(directory: root.appendingPathComponent("state")),
                inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, scope in
                    VerifiedMail(accountID: scope.accountID, localID: "one", source: mode == "missing" ? nil : source)
                }, model: { _ in fake })
            try pipeline.updateSettings {
                $0.permission = CapturePermission(); $0.executable = "/fake/dsh"
                $0.scopes = try? (mode == "ambiguous" ? ["a", "b"] : ["a"]).map { try AccountScope(accountID: $0, accountName: $0, mailboxName: "INBOX") }
            }
            let permission = try XCTUnwrap(pipeline.store.settings().permission)
            try pipeline.inbox.publish(InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "source@example.com", raw: capture))
            try pipeline.importInbox()
            if mode == "revoked" { try pipeline.updateSettings { $0.permission = nil } }
            try await pipeline.pump()
            let count = await fake.calls; XCTAssertEqual(count, 0, mode)
            XCTAssertEqual(try pipeline.store.records().first?.state, mode == "revoked" ? .cancelled : .needsReview, mode)
            if mode == "malformed" { XCTAssertEqual(try pipeline.store.records().first?.error, "unsupportedCharset") }
        }
    }
}

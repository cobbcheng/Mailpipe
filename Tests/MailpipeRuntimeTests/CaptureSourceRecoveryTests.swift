import XCTest
@testable import MailpipeRuntime
import MailpipeCore

@MainActor
final class CaptureSourceRecoveryTests: XCTestCase {
    func raw(type: String, payload: String) -> Data {
        Data(("From: sender@example.com\r\nTo: recipient@example.com\r\nDate: Tue, 17 Nov 2026 08:00:00 +0000\r\n"
            + "Subject: Synthetic\r\nMessage-ID: <source@example.com>\r\nContent-Type: \(type)\r\n\r\n" + payload).utf8)
    }
    func testMailKitUsesFirstReadableCallbackAcrossRestartWithoutMailLookup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeReplyModel()
        func open() throws -> ReplyPipeline {
            try ReplyPipeline(store: PipelineStore(directory: root.appendingPathComponent("state")),
                inbox: CaptureInbox(directory: root.appendingPathComponent("inbox")),
                resolve: { _, _ in XCTFail("Unexpected Mail read"); return nil },
                inAuthorizedInbox: { _, _, _ in XCTFail("Unexpected mailbox lookup"); return nil },
                model: { _ in fake })
        }
        var pipeline: ReplyPipeline? = try open()
        let grant = CapturePermission(delivery: .mailKit)
        try pipeline!.updateSettings { $0.permission = grant; $0.executable = "/fake/dsh" }
        func publish(_ subject: String, _ data: Data?) throws {
            try pipeline!.inbox.publish(InboundCapture(permissionID: grant.id, subject: subject,
                messageID: "first@example.com", raw: data))
        }
        try publish("header", nil)
        try await pipeline!.pump()
        XCTAssertEqual(try pipeline!.store.records().first?.state, .awaitingBody)
        try publish("invalid", Data("no headers".utf8))
        try await pipeline!.pump()
        try publish("first body", raw(type: "text/plain", payload: "First reply please"))
        try pipeline!.updateSettings { $0.paused = true }
        try await pipeline!.pump()
        let pausedCalls = await fake.calls
        XCTAssertEqual(pausedCalls, 0)
        try pipeline!.updateSettings { $0.paused = false }
        try await pipeline!.pump()
        let first = try XCTUnwrap(pipeline!.store.records().first)
        XCTAssertEqual(first.state, .draftReady)
        XCTAssertNil(first.accountID)
        XCTAssertNil(first.sourceEvidence)
        XCTAssertEqual(first.input.subject, "first body")
        pipeline = nil; pipeline = try open()
        try publish("later body", raw(type: "text/plain", payload: "Different copy"))
        try await pipeline!.pump()
        XCTAssertEqual(try pipeline!.store.records().map(\.id), [first.id])
        XCTAssertEqual(try pipeline!.store.record(first.id)?.input.body, "First reply please")
        let count = await fake.calls
        XCTAssertEqual(count, 2)
        try pipeline!.updateSettings { $0.permission = nil }
        XCTAssertThrowsError(try pipeline!.regenerate(first.id))
    }

    func testFullSourceIsParsedAfterUniqueAccountProofAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = "--b\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n请确认周五。\r\n--b--\r\n"
        let captured = Data(String(decoding: raw(type: "multipart/alternative", payload: payload), as: UTF8.self)
            .replacingOccurrences(of: "Subject: Synthetic", with: "Subject: =?utf-8?B?5L2g5aW9?=").utf8)
        let source = Data(String(decoding: raw(type: "multipart/alternative; boundary=b", payload: payload), as: UTF8.self)
            .replacingOccurrences(of: "Subject: Synthetic", with: "Subject: =?UTF-8?Q?=E4=BD=A0=E5=A5=BD?=").utf8)
        let fake = FakeReplyModel()
        var pipeline: ReplyPipeline? = ReplyPipeline(store: try PipelineStore(directory: root.appendingPathComponent("state")),
            inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, _ in nil }, inAuthorizedInbox: { _, _, _ in true }, model: { _ in fake })
        try pipeline!.updateSettings {
            $0.permission = CapturePermission(); $0.executable = "/fake/dsh"
            $0.scope = try? AccountScope(accountID: "test", accountName: "test", mailboxName: "INBOX")
        }
        let permission = try XCTUnwrap(pipeline!.store.settings().permission)
        try pipeline!.inbox.publish(InboundCapture(permissionID: permission.id, subject: "你好", messageID: "source@example.com", raw: nil))
        try await pipeline!.importInbox()
        let id = try XCTUnwrap(pipeline!.store.records().first?.id)
        try pipeline!.inbox.publish(InboundCapture(permissionID: permission.id, subject: "你好", messageID: "source@example.com", raw: captured))
        try await pipeline!.importInbox()
        XCTAssertEqual(try pipeline!.store.records().count, 1)
        XCTAssertEqual(try pipeline!.store.record(id)?.state, .awaitingAccount)
        XCTAssertNotNil(try pipeline!.store.record(id)?.sourceEvidence)
        // A failed lookup must remain manually recoverable even before MIME extraction.
        try await pipeline!.pump()
        XCTAssertTrue(try XCTUnwrap(pipeline!.store.record(id)).canRecheckIdentity)
        XCTAssertEqual(try pipeline!.store.record(id)?.input.body, "")
        try pipeline!.recheckIdentity(id)
        pipeline = nil
        let resumed = ReplyPipeline(store: try PipelineStore(directory: root.appendingPathComponent("state")),
            inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, scope in
                VerifiedMail(accountID: scope.accountID, localID: "one", source: source)
            }, inAuthorizedInbox: { _, _, _ in true }, model: { _ in fake })
        try await resumed.pump()
        let item = try XCTUnwrap(resumed.store.record(id))
        XCTAssertEqual(item.input.body, "请确认周五。")
        XCTAssertEqual(item.state, .draftReady)
        XCTAssertFalse(item.canRecheckIdentity)
        XCTAssertThrowsError(try resumed.recheckIdentity(id))
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
            try await pipeline.importInbox()
            if mode == "revoked" { try pipeline.updateSettings { $0.permission = nil } }
            try await pipeline.pump()
            let count = await fake.calls; XCTAssertEqual(count, 0, mode)
            XCTAssertEqual(try pipeline.store.records().first?.state, mode == "revoked" ? .cancelled : .needsReview, mode)
            if mode == "malformed" { XCTAssertEqual(try pipeline.store.records().first?.error, "unsupportedCharset") }
        }
    }
}

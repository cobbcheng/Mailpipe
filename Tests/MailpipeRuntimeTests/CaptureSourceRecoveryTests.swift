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
                model: { _ in fake })
        }
        var pipeline: ReplyPipeline? = try open()
        let grant = CapturePermission(delivery: .mailKit)
        try await pipeline!.updateSettings { $0.permission = grant; $0.executable = "/fake/dsh" }
        func publish(_ subject: String, _ data: Data?) throws {
            try pipeline!.inbox.publish(InboundCapture(permissionID: grant.id, subject: subject,
                messageID: "first@example.com", raw: data))
        }
        try publish("header", nil)
        try await pipeline!.pump()
        let waitingState = try await pipeline!.store.records().first?.state
        XCTAssertEqual(waitingState, .awaitingBody)
        try publish("invalid", Data("no headers".utf8))
        try await pipeline!.pump()
        try publish("first body", raw(type: "text/plain", payload: "First reply please"))
        try await pipeline!.updateSettings { $0.paused = true }
        try await pipeline!.pump()
        let pausedCalls = await fake.calls
        XCTAssertEqual(pausedCalls, 0)
        try await pipeline!.updateSettings { $0.paused = false }
        try await pipeline!.pump()
        let first = try unwrap(try await pipeline!.store.records().first)
        XCTAssertEqual(first.state, .draftReady)
        XCTAssertNil(first.accountID)
        XCTAssertNil(first.sourceEvidence)
        XCTAssertEqual(first.input.subject, "first body")
        pipeline = nil; pipeline = try open()
        try publish("later body", raw(type: "text/plain", payload: "Different copy"))
        try await pipeline!.pump()
        let ids = try await pipeline!.store.records().map(\.id)
        XCTAssertEqual(ids, [first.id])
        let savedBody = try await pipeline!.store.record(first.id)?.input.body
        XCTAssertEqual(savedBody, "First reply please")
        let count = await fake.calls
        XCTAssertEqual(count, 1)
        try await pipeline!.updateSettings { $0.permission = nil }
        do { try await pipeline!.regenerate(first.id); XCTFail("revoked") } catch {}
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
            inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, _ in nil }, model: { _ in fake })
        try await pipeline!.updateSettings {
            $0.permission = CapturePermission(); $0.executable = "/fake/dsh"
            $0.scope = try? AccountScope(accountID: "test", accountName: "test", mailboxName: "INBOX")
        }
        let permission = try unwrap(try await pipeline!.store.settings().permission)
        try pipeline!.inbox.publish(InboundCapture(permissionID: permission.id, subject: "你好", messageID: "source@example.com", raw: nil))
        try await pipeline!.importInbox()
        let id = try unwrap(try await pipeline!.store.records().first?.id)
        try pipeline!.inbox.publish(InboundCapture(permissionID: permission.id, subject: "你好", messageID: "source@example.com", raw: captured))
        try await pipeline!.importInbox()
        let countAfterCapture = try await pipeline!.store.records().count
        XCTAssertEqual(countAfterCapture, 1)
        let awaitingRecord = try await pipeline!.store.record(id)
        XCTAssertEqual(awaitingRecord?.state, .awaitingAccount)
        XCTAssertNotNil(awaitingRecord?.sourceEvidence)
        // A failed lookup must remain manually recoverable even before MIME extraction.
        try await pipeline!.pump()
        let afterFail = try unwrap(try await pipeline!.store.record(id))
        XCTAssertTrue(afterFail.canRecheckIdentity)
        XCTAssertEqual(afterFail.input.body, "")
        try await pipeline!.recheckIdentity(id)
        pipeline = nil
        let resumed = ReplyPipeline(store: try PipelineStore(directory: root.appendingPathComponent("state")),
            inbox: try CaptureInbox(directory: root.appendingPathComponent("inbox")), resolve: { _, scope in
                VerifiedMail(accountID: scope.accountID, localID: "one", source: source)
            }, model: { _ in fake })
        try await resumed.pump()
        let item = try unwrap(try await resumed.store.record(id))
        XCTAssertEqual(item.input.body, "请确认周五。")
        XCTAssertEqual(item.state, .draftReady)
        XCTAssertFalse(item.canRecheckIdentity)
        do { try await resumed.recheckIdentity(id); XCTFail("already resolved") } catch {}
        let count = await fake.calls; XCTAssertEqual(count, 1)
        try await resumed.pump()
        let unchanged = await fake.calls; XCTAssertEqual(unchanged, 1)
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
            try await pipeline.updateSettings {
                $0.permission = CapturePermission(); $0.executable = "/fake/dsh"
                $0.scopes = try? (mode == "ambiguous" ? ["a", "b"] : ["a"]).map { try AccountScope(accountID: $0, accountName: $0, mailboxName: "INBOX") }
            }
            let permission = try unwrap(try await pipeline.store.settings().permission)
            try pipeline.inbox.publish(InboundCapture(permissionID: permission.id, subject: "Synthetic", messageID: "source@example.com", raw: capture))
            try await pipeline.importInbox()
            if mode == "revoked" { try await pipeline.updateSettings { $0.permission = nil } }
            try await pipeline.pump()
            let count = await fake.calls; XCTAssertEqual(count, 0, mode)
            let saved = try await pipeline.store.records().first
            XCTAssertEqual(saved?.state, mode == "revoked" ? .cancelled : .needsReview, mode)
            if mode == "malformed" { XCTAssertEqual(saved?.error, "unsupportedCharset") }
        }
    }
}

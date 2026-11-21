import XCTest
@testable import MailpipeRuntime
import MailpipeCore

@MainActor final class MailComposePipelineTests: XCTestCase {
    let raw = Data("From: original@example.com\nReply-To: reply@example.com\nTo: me@example.com\n\nSynthetic body".utf8)
    func fixture() throws -> (PipelineStore, CaptureInbox, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try PipelineStore(directory: root)
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        var settings = PipelineSettings(); settings.permission = CapturePermission()
        settings.scope = try AccountScope(accountID: "a", accountName: "Test", mailboxName: "INBOX")
        try store.saveSettings(settings)
        let id = try store.importCapture(InboundCapture(permissionID: settings.permission!.id, subject: "Original", messageID: "test@example.com", raw: raw))
        var item = try XCTUnwrap(store.record(id)); item.state = .draftReady
        item.editedSubject = "Re: Original"; item.editedBody = "中文回复\n第二行"
        try store.save(item)
        return (store, inbox, id)
    }
    private let sender: @MainActor @Sendable (String, [String]) throws -> String = { _, _ in "me@example.com" }
    func testEachExplicitClickOpensCompose() async throws {
        let (store, inbox, id) = try fixture(); let raw = raw
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in VerifiedMail(accountID: "a", localID: "1", source: raw) })
        let request = try await pipeline.prepareMailCompose(id: id, subject: "Re: Original", body: "中文回复\n第二行", senderAddress: sender)
        XCTAssertEqual(request.recipients, ["reply@example.com"])
        var calls = 0
        for _ in 0..<2 {
            let receipt = try await pipeline.openMailCompose(confirmedRequest: request, senderAddress: sender) { request in
                XCTAssertNotNil(try store.record(id)?.composeHandoff)
                calls += 1
                return MailComposeReceipt(outgoingID: "42")
            }
            XCTAssertEqual(receipt.outgoingID, "42")
        }
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(try XCTUnwrap(store.record(id)).runs.isEmpty)
    }
    func testUnknownOutcomeAllowsAnotherExplicitClick() async throws {
        let (store, inbox, id) = try fixture(); let raw = raw
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in VerifiedMail(accountID: "a", localID: "1", source: raw) })
        let request = try await pipeline.prepareMailCompose(id: id, subject: "Re: Original", body: "中文回复\n第二行", senderAddress: sender)
        var calls = 0
        do { _ = try await pipeline.openMailCompose(confirmedRequest: request, senderAddress: sender) { _ in calls += 1; throw MailComposeError.outcomeUnknown }; XCTFail() }
        catch { XCTAssertEqual(error as? MailComposeError, .outcomeUnknown) }
        XCTAssertEqual(calls, 1)
        let receipt = try await pipeline.openMailCompose(confirmedRequest: request, senderAddress: sender) { _ in
            calls += 1
            return MailComposeReceipt(outgoingID: "second")
        }
        XCTAssertEqual(receipt.outgoingID, "second")
        XCTAssertEqual(calls, 2)
    }
    func testAsyncChangesPreventOpening() async throws {
        for change in ["pause", "discard", "cancel", "edit", "revoke"] {
            let (store, inbox, id) = try fixture(); let raw = raw
            let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in
                var settings = try store.settings(); var item = try XCTUnwrap(store.record(id))
                switch change {
                case "pause": settings.paused = true
                case "revoke": settings.permission = nil
                case "discard": item.discardedAt = Date()
                case "cancel": item.state = .cancelled
                default: item.editedBody = "newer edit"
                }
                try store.saveSettings(settings); try store.save(item)
                return VerifiedMail(accountID: "a", localID: "1", source: raw)
            })
            do { _ = try await pipeline.prepareMailCompose(id: id, subject: "Re: Original", body: "中文回复\n第二行", senderAddress: sender); XCTFail(change) }
            catch { }
            XCTAssertNil(try store.record(id)?.composeHandoff)
        }
    }
    func testChangedTargetOrEditedBodyRejectsConfirmedRequest() async throws {
        let (store, inbox, id) = try fixture(); let raw = raw
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in VerifiedMail(accountID: "a", localID: "1", source: raw) })
        let request = try await pipeline.prepareMailCompose(id: id, subject: "Re: Original", body: "中文回复\n第二行", senderAddress: sender)
        do { _ = try await pipeline.openMailCompose(confirmedRequest: request, senderAddress: { _, _ in "other@example.com" }) { _ in XCTFail("No Mail effect"); return MailComposeReceipt(outgoingID: "bad") }; XCTFail() }
        catch { XCTAssertEqual(error as? MailComposeError, .changedSinceConfirmation) }
        var item = try XCTUnwrap(store.record(id)); item.editedBody = "new"; try store.save(item)
        do { _ = try await pipeline.openMailCompose(confirmedRequest: request, senderAddress: sender) { _ in XCTFail("No Mail effect"); return MailComposeReceipt(outgoingID: "bad") }; XCTFail() }
        catch { }
        XCTAssertNil(try store.record(id)?.composeHandoff)
    }
}

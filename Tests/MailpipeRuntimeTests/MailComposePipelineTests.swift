import XCTest
@testable import MailpipeRuntime
import MailpipeCore

@MainActor final class MailComposePipelineTests: XCTestCase {
    let raw = Data("From: original@example.com\nReply-To: reply@example.com\nTo: me@example.com\n\nSynthetic body".utf8)
    func fixture() async throws -> (PipelineStore, CaptureInbox, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try PipelineStore(directory: root)
        let inbox = try CaptureInbox(directory: root.appendingPathComponent("inbox"))
        var settings = PipelineSettings(); settings.permission = CapturePermission()
        settings.scope = try AccountScope(accountID: "a", accountName: "Test", mailboxName: "INBOX")
        try await store.saveSettings(settings)
        let id = try await store.importCapture(InboundCapture(permissionID: settings.permission!.id, subject: "Original", messageID: "test@example.com", raw: raw))
        var item = try unwrap(try await store.record(id)); item.state = .draftReady
        item.editedSubject = "Re: Original"; item.editedBody = "中文回复\n第二行"
        try await store.save(item)
        return (store, inbox, id)
    }
    private let sender: @Sendable (String, [String]) async throws -> String = { _, _ in "me@example.com" }
    func testEachExplicitClickOpensCompose() async throws {
        let (store, inbox, id) = try await fixture(); let raw = raw
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in VerifiedMail(accountID: "a", localID: "1", source: raw) })
        let request = try await pipeline.prepareMailCompose(id: id, subject: "Re: Original", body: "中文回复\n第二行", senderAddress: sender)
        XCTAssertEqual(request.recipients, ["reply@example.com"])
        actor Counter { var value = 0; func inc() { value += 1 } }
        let calls = Counter()
        for _ in 0..<2 {
            let receipt = try await pipeline.openMailCompose(confirmedRequest: request, senderAddress: sender) { _ in
                let handoff = try await store.record(id)?.composeHandoff
                XCTAssertNotNil(handoff)
                await calls.inc()
                return MailComposeReceipt(outgoingID: "42")
            }
            XCTAssertEqual(receipt.outgoingID, "42")
        }
        let callCount = await calls.value
        XCTAssertEqual(callCount, 2)
        let runs = try await store.record(id)?.runs ?? []
        XCTAssertTrue(runs.isEmpty)
    }
    func testSinglePassComposeReplyResolvesOnceAndSavesReceipt() async throws {
        let (store, inbox, id) = try await fixture(); let raw = raw
        actor Counter { var value = 0; func inc() { value += 1 } }
        let resolves = Counter()
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in
            await resolves.inc()
            return VerifiedMail(accountID: "a", localID: "1", source: raw)
        })
        let receipt = try await pipeline.composeReply(id: id, subject: "Re: Original", body: "中文回复\n第二行", senderAddress: sender) { _ in
            MailComposeReceipt(outgoingID: "single-pass")
        }
        XCTAssertEqual(receipt.outgoingID, "single-pass")
        let resolveCount = await resolves.value
        XCTAssertEqual(resolveCount, 1)
        let saved = try await store.record(id)
        XCTAssertEqual(saved?.composeHandoff?.receipt?.outgoingID, "single-pass")
    }
    func testUnknownOutcomeAllowsAnotherExplicitClick() async throws {
        let (store, inbox, id) = try await fixture(); let raw = raw
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in VerifiedMail(accountID: "a", localID: "1", source: raw) })
        let request = try await pipeline.prepareMailCompose(id: id, subject: "Re: Original", body: "中文回复\n第二行", senderAddress: sender)
        actor Counter { var value = 0; func inc() { value += 1 } }
        let calls = Counter()
        do { _ = try await pipeline.openMailCompose(confirmedRequest: request, senderAddress: sender) { _ in await calls.inc(); throw MailComposeError.outcomeUnknown }; XCTFail() }
        catch { XCTAssertEqual(error as? MailComposeError, .outcomeUnknown) }
        let firstCount = await calls.value
        XCTAssertEqual(firstCount, 1)
        let receipt = try await pipeline.openMailCompose(confirmedRequest: request, senderAddress: sender) { _ in
            await calls.inc()
            return MailComposeReceipt(outgoingID: "second")
        }
        XCTAssertEqual(receipt.outgoingID, "second")
        let secondCount = await calls.value
        XCTAssertEqual(secondCount, 2)
    }
    func testAsyncChangesPreventOpening() async throws {
        for change in ["pause", "discard", "cancel", "edit", "revoke"] {
            let (store, inbox, id) = try await fixture(); let raw = raw
            let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in
                var settings = try await store.settings(); var item = try unwrap(try await store.record(id))
                switch change {
                case "pause": settings.paused = true
                case "revoke": settings.permission = nil
                case "discard": item.discardedAt = Date()
                case "cancel": item.state = .cancelled
                default: item.editedBody = "newer edit"
                }
                try await store.saveSettings(settings); try await store.save(item)
                return VerifiedMail(accountID: "a", localID: "1", source: raw)
            })
            do { _ = try await pipeline.prepareMailCompose(id: id, subject: "Re: Original", body: "中文回复\n第二行", senderAddress: sender); XCTFail(change) }
            catch { }
            let handoff = try await store.record(id)?.composeHandoff
            XCTAssertNil(handoff)
        }
    }
    func testChangedTargetOrEditedBodyRejectsConfirmedRequest() async throws {
        let (store, inbox, id) = try await fixture(); let raw = raw
        let pipeline = ReplyPipeline(store: store, inbox: inbox, resolve: { _, _ in VerifiedMail(accountID: "a", localID: "1", source: raw) })
        let request = try await pipeline.prepareMailCompose(id: id, subject: "Re: Original", body: "中文回复\n第二行", senderAddress: sender)
        do { _ = try await pipeline.openMailCompose(confirmedRequest: request, senderAddress: { _, _ in "other@example.com" }) { _ in XCTFail("No Mail effect"); return MailComposeReceipt(outgoingID: "bad") }; XCTFail() }
        catch { XCTAssertEqual(error as? MailComposeError, .changedSinceConfirmation) }
        var item = try unwrap(try await store.record(id)); item.editedBody = "new"; try await store.save(item)
        do { _ = try await pipeline.openMailCompose(confirmedRequest: request, senderAddress: sender) { _ in XCTFail("No Mail effect"); return MailComposeReceipt(outgoingID: "bad") }; XCTFail() }
        catch { }
        let handoff = try await store.record(id)?.composeHandoff
        XCTAssertNil(handoff)
    }
}

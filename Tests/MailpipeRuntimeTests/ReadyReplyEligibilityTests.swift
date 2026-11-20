import XCTest
import MailpipeCore
@testable import MailpipeRuntime

final class ReadyReplyEligibilityTests: XCTestCase {
    private let permission = CapturePermission(delivery: .mailKit)
    private let now = Date()

    private var settings: PipelineSettings {
        var settings = PipelineSettings()
        settings.permission = permission
        return settings
    }

    private func reply(messageID: String? = "ready@example.com") -> StoredReply {
        let input = MailInput(messageRef: "ready", subject: "Synthetic question", body: "Can we meet on Monday?")
        var reply = StoredReply(id: input.messageRef, permissionID: permission.id, capturedAt: now,
                                messageID: messageID, input: input, state: .draftReady)
        reply.mailKitBody = true
        reply.draftData = Data(#"{"schema_version":1,"request_id":"ready-draft","triage_request_id":"ready-triage","message_ref":"ready","subject":"Re: Synthetic question","body":"Monday works for me."}"#.utf8)
        return reply
    }

    func testReadyReviewedAndEditedDraftsCountWhileEmptyOrInvalidDraftsDoNot() {
        var item = reply()
        XCTAssertTrue(item.isReadyForReplyReminder(settings: settings, now: now))
        item.reviewedDraftVersion = item.draftVersion
        item.editedBody = "Tuesday would be better."
        XCTAssertTrue(item.isReadyForReplyReminder(settings: settings, now: now))
        item.editedBody = " \n "
        XCTAssertFalse(item.isReadyForReplyReminder(settings: settings, now: now))
        item.editedBody = nil
        item.draftData = Data("{}".utf8)
        XCTAssertFalse(item.isReadyForReplyReminder(settings: settings, now: now))
    }

    func testOnlyCurrentVisibleMailWithinComposeWindowCounts() {
        let item = reply()
        for state: ReplyState in [.awaitingBody, .awaitingAccount, .queued, .triaging, .draftQueued, .drafting, .needsReply, .needsReview, .noReply, .cancelled] {
            var other = item
            other.state = state
            XCTAssertFalse(other.isReadyForReplyReminder(settings: settings, now: now), state.rawValue)
        }
        let expiry = now.addingTimeInterval(7 * 86_400)
        XCTAssertTrue(item.isReadyForReplyReminder(settings: settings, now: expiry.addingTimeInterval(-1)))
        XCTAssertFalse(item.isReadyForReplyReminder(settings: settings, now: expiry))
        XCTAssertFalse(reply(messageID: nil).isReadyForReplyReminder(settings: settings, now: now))

        var paused = settings
        paused.paused = true
        XCTAssertFalse(item.isReadyForReplyReminder(settings: paused, now: now))
        var revoked = settings
        revoked.permission = nil
        XCTAssertFalse(item.isReadyForReplyReminder(settings: revoked, now: now))
        revoked.permission = CapturePermission(delivery: .mailKit)
        XCTAssertFalse(item.isReadyForReplyReminder(settings: revoked, now: now))

        var discarded = item
        discarded.discardedAt = now
        XCTAssertFalse(discarded.isReadyForReplyReminder(settings: settings, now: now))
        var excluded = item
        excluded.excludedFromAuthorizedInbox = true
        XCTAssertFalse(excluded.isReadyForReplyReminder(settings: settings, now: now))
        var sample = item
        sample.syntheticAuthorized = true
        XCTAssertFalse(sample.isReadyForReplyReminder(settings: settings, now: now))
        var archived = item
        archived.manualExecutable = "/fake/archived"
        XCTAssertFalse(archived.isReadyForReplyReminder(settings: settings, now: now))
    }

    func testLegacyRecordUsesCurrentMailboxScope() throws {
        var item = reply()
        item.mailKitBody = nil
        let scope = try AccountScope(accountID: "test", accountName: "Test", mailboxName: "INBOX")
        item.accountID = scope.accountID
        var settings = settings
        XCTAssertFalse(item.isReadyForReplyReminder(settings: settings, now: now))
        settings.scope = scope
        XCTAssertTrue(item.isReadyForReplyReminder(settings: settings, now: now))
        item.scopeID = scope.id
        XCTAssertTrue(item.isReadyForReplyReminder(settings: settings, now: now))
        settings.scopes = [try AccountScope(accountID: "test", accountName: "Test", mailboxName: "Archive")]
        XCTAssertFalse(item.isReadyForReplyReminder(settings: settings, now: now))
    }

    func testHandoffEndsRemindersUntilANewDraftCompletes() throws {
        var item = reply()
        let handoff = MailComposeHandoff(fingerprint: "synthetic")
        item.composeHandoff = handoff
        XCTAssertFalse(item.isReadyForReplyReminder(settings: settings, now: now))
        item.composeHandoff?.receipt = MailComposeReceipt(outgoingID: "synthetic")
        XCTAssertFalse(item.isReadyForReplyReminder(settings: settings, now: now))

        let destination = try DataDestination(messageRef: item.id, runID: "regeneration", taskKind: .draft, harness: .deepseek)
        let later = handoff.startedAt.addingTimeInterval(1)
        item.runs.append(PipelineRun(destination: destination, startedAt: later))
        XCTAssertFalse(item.isReadyForReplyReminder(settings: settings, now: later))
        item.runs[0].finishedAt = later
        XCTAssertTrue(item.isReadyForReplyReminder(settings: settings, now: later))
    }
}

import XCTest
import MailpipeCore
@testable import MailpipeRuntime

final class ReplyReminderScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func due(_ now: String, at minute: Int = ReplyReminderSchedule.defaultMinuteOfDay,
                     lastHandled: String? = nil) throws -> Bool {
        try ReplyReminderSchedule.dayDue(at: Date(now, strategy: .iso8601), minuteOfDay: minute,
                                         lastHandled: lastHandled.map { try Date($0, strategy: .iso8601) },
                                         calendar: calendar)
    }

    func testDueAtLocalTimeOrOnWakeLaterThatDay() throws {
        XCTAssertFalse(try due("2026-11-20T17:59:59Z"))
        XCTAssertTrue(try due("2026-11-20T18:00:00Z"))
        XCTAssertTrue(try due("2026-11-20T22:00:00Z", lastHandled: "2026-11-17T18:00:00Z"))
        XCTAssertTrue(try due("2026-11-20T08:00:00Z", at: 0))
    }

    func testRestartTimeChangeAndClockRollbackDoNotRepeatHandledDay() throws {
        let lastHandled = "2026-11-20T18:00:00Z"
        // This UTC instant is still November 20 locally.
        XCTAssertFalse(try due("2026-11-21T01:00:00Z", at: 16 * 60, lastHandled: lastHandled))
        XCTAssertFalse(try due("2026-11-19T22:00:00Z", lastHandled: lastHandled))
        XCTAssertTrue(try due("2026-11-21T18:00:00Z", lastHandled: lastHandled))
    }

    func testInvalidMinuteUsesDefaultTime() throws {
        for invalid in [-1, 1440] {
            XCTAssertFalse(try due("2026-11-20T17:59:59Z", at: invalid))
            XCTAssertTrue(try due("2026-11-20T18:00:00Z", at: invalid))
        }
    }

    func testMissingSpringHourUsesFirstAvailableMinute() throws {
        let twoThirty = 2 * 60 + 30
        XCTAssertFalse(try due("2026-03-08T09:59:59Z", at: twoThirty))
        XCTAssertTrue(try due("2026-03-08T10:00:00Z", at: twoThirty))
    }

    func testRepeatedAutumnHourUsesFirstOccurrence() throws {
        let oneThirty = 90
        let firstOccurrence = "2026-11-01T08:30:00Z"
        XCTAssertFalse(try due("2026-11-01T08:29:59Z", at: oneThirty))
        XCTAssertTrue(try due(firstOccurrence, at: oneThirty))
        XCTAssertTrue(try due("2026-11-01T09:15:00Z", at: oneThirty))
        XCTAssertFalse(try due("2026-11-01T09:30:00Z", at: oneThirty, lastHandled: firstOccurrence))
    }

    private let defaultsSuite = "ReplyReminderScheduleTests." + UUID().uuidString
    private let permission = CapturePermission(delivery: .mailKit)
    private var defaults: UserDefaults { UserDefaults(suiteName: defaultsSuite)! }
    private var settings: PipelineSettings {
        var settings = PipelineSettings()
        settings.permission = permission
        return settings
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private func readyReply(_ id: String, now: Date) throws -> StoredReply {
        let input = MailInput(messageRef: id, subject: "Example question", body: "Can we meet?")
        var item = StoredReply(id: id, permissionID: permission.id, capturedAt: now,
                               messageID: id + "@example.com", input: input, state: .draftReady)
        item.mailKitBody = true
        item.draftData = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "request_id": id + "-draft", "triage_request_id": id + "-triage",
            "message_ref": id, "subject": "Re: Example question", "body": "Yes, we can meet."
        ])
        return item
    }

    @MainActor private func claim(_ records: [StoredReply], at now: Date, using policy: PipelineSettings? = nil) -> Int? {
        ReplyReminderSchedule.claimCount(records: records, settings: policy ?? settings, now: now,
                                         defaults: defaults, calendar: calendar)
    }

    @MainActor func testClaimsOnlyReadyCountOnceAcrossRelaunchAndTimeChange() throws {
        let ten = try Date("2026-11-20T18:00:00Z", strategy: .iso8601)
        let first = try readyReply("first", now: ten)
        let second = try readyReply("second", now: ten)
        var discarded = try readyReply("discarded", now: ten)
        discarded.discardedAt = ten
        let records = [first, second, discarded]
        XCTAssertNil(claim(records, at: ten.addingTimeInterval(-1)))
        XCTAssertEqual(claim(records, at: ten), 2)
        XCTAssertNil(claim(records, at: ten))
        defaults.set(11 * 60, forKey: ReplyReminderSchedule.minuteKey)
        XCTAssertNil(claim(records, at: ten.addingTimeInterval(3600)))
        let tomorrow = try Date("2026-11-21T19:00:00Z", strategy: .iso8601)
        XCTAssertEqual(claim(records, at: tomorrow), 2)
    }

    @MainActor func testEmptySlotSkipsLaterArrivalsUntilNewLaterSlot() throws {
        let ten = try Date("2026-11-20T18:00:00Z", strategy: .iso8601)
        let records = [try readyReply("waiting", now: ten.addingTimeInterval(60))]
        XCTAssertNil(claim([], at: ten.addingTimeInterval(5 * 60)))
        XCTAssertNil(claim(records, at: ten.addingTimeInterval(6 * 60)))
        defaults.set(10 * 60 + 1, forKey: ReplyReminderSchedule.minuteKey)
        XCTAssertNil(claim(records, at: ten.addingTimeInterval(4 * 60)))
        defaults.set(9 * 60, forKey: ReplyReminderSchedule.minuteKey)
        XCTAssertNil(claim(records, at: ten.addingTimeInterval(6 * 60)))
        defaults.set(11 * 60, forKey: ReplyReminderSchedule.minuteKey)
        XCTAssertNil(claim(records, at: ten.addingTimeInterval(3599)))
        XCTAssertEqual(claim(records, at: ten.addingTimeInterval(3600)), 1)
    }

    @MainActor func testPauseAndRevocationDoNotClaimSlot() throws {
        let ten = try Date("2026-11-20T18:00:00Z", strategy: .iso8601)
        let records = [try readyReply("waiting", now: ten)]
        var paused = settings
        paused.paused = true
        XCTAssertNil(claim(records, at: ten, using: paused))
        var revoked = settings
        revoked.permission = nil
        XCTAssertNil(claim(records, at: ten, using: revoked))
        XCTAssertEqual(claim(records, at: ten), 1)
    }
}

import Foundation

public enum ReplyReminderSchedule {
    public static let defaultMinuteOfDay = 10 * 60
    public static let minuteKey = "replyReminder.minuteOfDay"
    private static let handledSlotKey = "replyReminder.lastHandledSlot"

    private static func validMinute(_ value: Int) -> Int {
        (0..<1440).contains(value) ? value : defaultMinuteOfDay
    }

    public static func dayDue(at now: Date, minuteOfDay: Int, lastHandled: Date?,
                              calendar: Calendar = .autoupdatingCurrent) -> Bool {
        if let lastHandled, calendar.compare(lastHandled, to: now, toGranularity: .day) != .orderedAscending {
            return false
        }
        let minute = validMinute(minuteOfDay)
        // A skipped local time fires at the first valid minute; a repeated time fires only once.
        guard let scheduled = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                                            of: now, matchingPolicy: .nextTime, repeatedTimePolicy: .first) else {
            return false
        }
        return now >= scheduled
    }

    private static func configuredMinute(_ defaults: UserDefaults) -> Int {
        validMinute(defaults.object(forKey: minuteKey) as? Int ?? defaultMinuteOfDay)
    }

    public static func isDue(at now: Date, defaults: UserDefaults = .standard,
                             calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let minute = configuredMinute(defaults)
        let slot = defaults.dictionary(forKey: handledSlotKey)
        var lastHandled = slot?["date"] as? Date
        // After an empty summary, moving the schedule later gives the new slot one check.
        if let date = lastHandled, date <= now, calendar.isDate(date, inSameDayAs: now),
           let emptyMinute = slot?["emptyMinute"] as? Int, minute > emptyMinute {
            lastHandled = nil
        }
        return dayDue(at: now, minuteOfDay: minute, lastHandled: lastHandled, calendar: calendar)
    }

    /// Claims today's summary before the host submits it to Notification Center.
    @MainActor public static func claimCount(records: [StoredReply], settings: PipelineSettings, now: Date,
                                            defaults: UserDefaults = .standard,
                                            calendar: Calendar = .autoupdatingCurrent) -> Int? {
        guard !settings.paused, settings.permission != nil,
              isDue(at: now, defaults: defaults, calendar: calendar) else { return nil }
        let count = records.lazy.filter { $0.isReadyForReplyReminder(settings: settings, now: now) }.count
        var handledSlot: [String: Any] = ["date": now]
        if count == 0 { handledSlot["emptyMinute"] = configuredMinute(defaults) }
        defaults.set(handledSlot, forKey: handledSlotKey)
        return count > 0 ? count : nil
    }
}

import SwiftUI
import UserNotifications
import MailpipeRuntime

@MainActor
final class ReadyReplyReminders: ObservableObject {
    nonisolated static let identifier = "mailpipe.ready-replies"
    @Published private(set) var authorization: UNAuthorizationStatus?
    @Published private(set) var deliveryIssue: String?
    private var lastScheduledPermissionCheck: Date?

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            deliveryIssue = nil
        } catch {
            deliveryIssue = L("Could not request notification permission. Try again in Settings.")
        }
        await refreshAuthorization()
    }

    func check(records: [StoredReply], settings: PipelineSettings) {
        guard !settings.paused, settings.permission != nil else { return }
        let now = Date()
        guard ReplyReminderSchedule.isDue(at: now) else { return }
        // Recheck system permission at the scheduled time, even if the app stayed open overnight.
        if lastScheduledPermissionCheck.map({ Calendar.autoupdatingCurrent.isDate($0, inSameDayAs: now) }) != true {
            lastScheduledPermissionCheck = now
            authorization = nil
            Task { await refreshAuthorization() }
            return
        }
        guard authorization == .authorized || authorization == .provisional,
              let count = ReplyReminderSchedule.claimCount(records: records, settings: settings, now: now) else { return }
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? L("1 reply draft is ready to review.") : L("%1$@ reply drafts are ready to review.", String(count))
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            let failed = error != nil
            Task { @MainActor in
                self.deliveryIssue = failed ? L("The last reminder could not be delivered. Check notification settings.") : nil
            }
        }
    }
}

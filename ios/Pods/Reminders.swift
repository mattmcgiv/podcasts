import Foundation
import UserNotifications

/// Local reminders before the free-account signature runs out, so the iPhone can be
/// brought within reach of the Mac in time. They are rebuilt from the installed
/// profile on every launch, foreground and background refresh, so a re-signed app
/// replaces the old reminders the next time it runs.
enum Reminders {
    static let identifiers = ["signing-expiry-early", "signing-expiry-late"]

    struct Reminder: Equatable {
        var id: String
        var at: Date
        var title: String
        var body: String
    }

    /// The reminders still ahead: 36 hours and 6 hours before the signature runs out.
    static func plan(expiry: Date, now: Date) -> [Reminder] {
        let when = expiry.formatted(.dateTime.weekday(.wide).hour().minute())
        return [
            Reminder(id: identifiers[0], at: expiry.addingTimeInterval(-36 * 3600), title: "Pods needs re-signing soon",
                     body: "Its signature runs out \(when). Unlock this iPhone on the Mac's Wi-Fi, or plug it in, so the Mac can re-sign it."),
            Reminder(id: identifiers[1], at: expiry.addingTimeInterval(-6 * 3600), title: "Pods stops opening in 6 hours",
                     body: "Unlock this iPhone on the Mac's Wi-Fi, or plug it in, before \(when). Downloaded episodes are kept."),
        ].filter { $0.at.timeIntervalSince(now) > 60 }
    }

    /// Replace the pending reminders. `ask` may show the permission prompt, so only the foreground passes it.
    static func reschedule(ask: Bool, expiry: Date? = Signing.expiry) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        guard let expiry else { return }
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined, ask {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else { return }
        for reminder in plan(expiry: expiry, now: Date()) {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: reminder.at.timeIntervalSinceNow, repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)) }
            catch { DeviceLog.write("reminder not scheduled: \(error.localizedDescription)") }
        }
    }
}

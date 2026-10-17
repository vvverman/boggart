import Foundation
import UserNotifications
import BoggartCore

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let defaults = UserDefaults.standard
    private let center = UNUserNotificationCenter.current()
    override init() { super.init(); center.delegate = self }
    func requestAfterExplicitSetup() {
        guard !defaults.bool(forKey: "notificationPermissionRequested.v3") else { return }
        defaults.set(true, forKey: "notificationPermissionRequested.v3")
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }
    func receive(_ status: ServiceStatus) {
        if status.phase == .recoveryRequired, let id = status.recoverySessionID {
            deliverOnce(id, body: status.message)
        }
        // После переподключения не отправляем пачку уведомлений о старой истории.
        if status.phase == .inactive, let entry = status.history.first, entry.reason.abnormal {
            deliverOnce(entry.id, body: "Удержание выключено: \(entry.reason.description).")
        }
    }
    private func deliverOnce(_ id: UUID, body: String) {
        let key = "notificationSessions.v3"
        var seen = defaults.stringArray(forKey: key) ?? []
        guard !seen.contains(id.uuidString) else { return }
        seen.append(id.uuidString); defaults.set(Array(seen.suffix(50)), forKey: key)
        center.getNotificationSettings { [center] settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Боггарт"; content.body = body
            center.add(UNNotificationRequest(identifier: "boggart.\(id.uuidString)", content: content, trigger: nil)) { _ in }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

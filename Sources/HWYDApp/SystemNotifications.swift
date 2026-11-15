import AppKit
import Foundation
@preconcurrency import UserNotifications
import HWYDCore

/// The app's system notifications: one delegate for the notification center, the categories each
/// feature registers, and the answers routed back to the feature that posted them. Only the
/// installed app uses it; previews, snapshots and checks never reach the notification center.
@MainActor final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// Handles an answer to a notification of one of the feature's categories.
    typealias Handler = @MainActor (_ action: String, _ userInfo: [AnyHashable: Any]) -> Void
    let enabled: Bool
    private var categories: [String: UNNotificationCategory] = [:]
    private var handlers: [String: Handler] = [:]
    /// Answers to notifications without a registered category, such as the calendar's test reminder.
    var fallback: Handler?
    private var center: UNUserNotificationCenter { .current() }

    init(enabled: Bool) {
        self.enabled = enabled
        super.init()
        if enabled { center.delegate = self }
    }
    /// Adds or replaces categories; answers to notifications of these categories go to `handler`.
    func register(_ categories: [UNNotificationCategory], handler: @escaping Handler) {
        guard enabled else { return }
        for category in categories { self.categories[category.identifier] = category; handlers[category.identifier] = handler }
        center.setNotificationCategories(Set(self.categories.values))
    }
    /// Asks once for the permission to show alerts. False when refused.
    func authorize() async -> Bool {
        guard enabled else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
    /// Shows `content` now, replacing a notification with the same identifier.
    func post(_ identifier: String, _ content: UNNotificationContent) {
        guard enabled else { return }
        Task { try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) }
    }
    func withdraw(_ identifiers: [String]) {
        guard enabled else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        // UserInfo values are property-list types; they cross to the main actor as such.
        nonisolated(unsafe) let info = userInfo
        await MainActor.run { (self.handlers[category] ?? self.fallback)?(action, info) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}

import AppKit
import Foundation
@preconcurrency import UserNotifications
import HWYDCore

/// The app's system notifications: one delegate for the notification center, the categories each
/// feature registers, and the answers routed back to the feature that posted them. Only the
/// installed app may use it, and only the instance that owns the system services (`claim`) does:
/// a `--demo` instance running next to the real app neither takes the delegate nor posts.
/// Previews, snapshots and checks never reach the notification center.
@MainActor final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// Handles an answer to a notification of one of the feature's categories.
    typealias Handler = @MainActor (_ action: String, _ userInfo: [AnyHashable: Any]) -> Void
    /// How a notification of a category shows while HWYD is frontmost.
    typealias Presentation = @MainActor () -> UNNotificationPresentationOptions
    /// The installed app: this instance may claim the notification center.
    let allowed: Bool
    /// This instance answers and posts notifications.
    private(set) var enabled = false
    private var categories: [String: UNNotificationCategory] = [:]
    private var handlers: [String: Handler] = [:]
    private var presentations: [String: Presentation] = [:]
    /// Posts and withdrawals, in the order asked: each waits for the permission to be decided.
    private var queue: Task<Void, Never>?
    /// Answers to notifications without a registered category, such as the calendar's test reminder.
    var fallback: Handler?
    private var center: UNUserNotificationCenter { .current() }

    init(allowed: Bool) {
        self.allowed = allowed
        super.init()
    }
    /// Takes the notification center's delegate: only the instance that owns the system services.
    func claim() {
        guard allowed, !enabled else { return }
        enabled = true
        center.delegate = self
        if !categories.isEmpty { center.setNotificationCategories(Set(categories.values)) }
    }
    /// Adds or replaces categories; answers to notifications of these categories go to `handler`.
    /// `presentation` decides how they show while HWYD is frontmost; a banner by default.
    func register(_ categories: [UNNotificationCategory], presentation: Presentation? = nil, handler: @escaping Handler) {
        guard allowed else { return }
        for category in categories {
            self.categories[category.identifier] = category; handlers[category.identifier] = handler
            presentations[category.identifier] = presentation
        }
        if enabled { center.setNotificationCategories(Set(self.categories.values)) }
    }
    /// Asks once for the permission to show alerts. False when refused.
    func authorize() async -> Bool {
        guard enabled else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }
    /// Shows `content` now, replacing a notification with the same identifier. The permission is
    /// asked the first time something is posted, in the context of that notification, never
    /// together with the microphone's permission when a capture starts.
    func post(_ identifier: String, _ content: UNNotificationContent) {
        guard enabled else { return }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        inOrder { [center] in
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }
    func withdraw(_ identifiers: [String]) {
        guard enabled else { return }
        inOrder { [center] in
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }
    private func inOrder(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        // UserInfo values are property-list types; they cross to the main actor as such.
        nonisolated(unsafe) let info = userInfo
        await MainActor.run { (self.handlers[category] ?? self.fallback)?(action, info) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        return await MainActor.run { self.presentations[category]?() ?? [.banner, .sound] }
    }
}

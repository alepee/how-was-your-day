import Combine
import Foundation
@preconcurrency import UserNotifications
import HWYDCore

/// « Vous avez fini ? » as a system notification: a forgotten capture runs while the user is in
/// another app, or away. It carries « Pas encore » and « Arrêter »; not answering lets the
/// countdown stop the capture, then a notice says so. Speech coming back or an answer in the app
/// withdraws it. While the capture screen or the notepad shows the question in the frontmost
/// HWYD, it only goes to the Notification Center, without a banner.
@MainActor final class InactivityAlerts {
    static let promptID = "hwyd.inactivity.prompt"
    static let stoppedID = "hwyd.inactivity.stopped"
    private static let category = "inactivity-prompt"
    private let notifications: SystemNotifications
    private var shown: InactivityPrompt?
    private var changes: AnyCancellable?
    /// Whether the frontmost HWYD shows the question (capture screen or notepad).
    var isShownInApp: @MainActor () -> Bool = { false }

    init(notifications: SystemNotifications) { self.notifications = notifications }

    /// Follows the questions of `capture`; answers go back to it.
    func follow(_ capture: CaptureSession, open: @escaping @MainActor () -> Void) {
        guard notifications.allowed else { return }
        let category = UNNotificationCategory(identifier: Self.category, actions: [
            UNNotificationAction(identifier: "keep", title: String(localized: "Pas encore"), options: []),
            UNNotificationAction(identifier: "stop", title: String(localized: "Arrêter"), options: [.destructive])
        ], intentIdentifiers: [], options: [])
        notifications.register([category], presentation: { [weak self] in
            self?.isShownInApp() == true ? [.list] : [.banner, .sound, .list]
        }) { [weak capture] action, userInfo in
            // Only the question still pending: an older notification answers nothing.
            guard let capture, capture.inactivity?.id.uuidString == userInfo["prompt"] as? String else { return }
            switch action {
            case "keep": capture.keepRecording()
            case "stop": Task { await capture.stop() }
            case UNNotificationDefaultActionIdentifier: open()
            default: break
            }
        }
        changes = capture.$inactivity.sink { [weak self] prompt in
            MainActor.assumeIsolated { self?.show(prompt) }
        }
    }
    private func show(_ prompt: InactivityPrompt?) {
        guard prompt != shown else { return }
        shown = prompt
        guard let prompt else { notifications.withdraw([Self.promptID]); return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Vous avez fini ?")
        content.body = InactivityText.prompt(prompt)
        content.categoryIdentifier = Self.category
        content.userInfo = ["prompt": prompt.id.uuidString]
        notifications.post(Self.promptID, content)
    }
    /// The capture stopped on its own: says so, in place of the question.
    func stopped(after silence: TimeInterval) {
        notifications.withdraw([Self.promptID])
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Enregistrement arrêté")
        content.body = InactivityText.stopped(after: silence)
        notifications.post(Self.stoppedID, content)
    }
}

/// What the capture screen and the notifications say about a capture in which nobody speaks.
enum InactivityText {
    static func minutes(_ seconds: TimeInterval) -> Int { max(1, Int((seconds / 60).rounded())) }
    static func prompt(_ prompt: InactivityPrompt) -> String {
        let time = prompt.stopsAt.formatted(date: .omitted, time: .shortened)
        return String(localized: "Personne n’a parlé depuis \(minutes(prompt.silence)) min. Sans réponse, l’enregistrement s’arrête à \(time).")
    }
    static func stopped(after silence: TimeInterval) -> String {
        String(localized: "Personne n’a parlé pendant \(minutes(silence)) min. L’audio et les notes sont conservés.")
    }
}

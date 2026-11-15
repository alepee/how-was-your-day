import Combine
import Foundation
@preconcurrency import UserNotifications
import HWYDCore

/// The capture's microphone questions and notices as system notifications: during a meeting the
/// user is in the meeting app, not in HWYD. The offer of a new microphone carries « Basculer » and
/// « Garder <micro> »; dismissing it or not answering keeps the microphone. A newer offer replaces
/// the notification, and an offer answered in the app, or gone, withdraws it. While the capture
/// screen or the notepad shows the offer in the frontmost HWYD, the notification only goes to the
/// Notification Center, without a banner: the question is not asked twice.
///
/// The permission to notify is asked with the first notice, not when a capture starts: the
/// microphone's permission is asked then, and two prompts at once would leave the user to guess
/// which one matters. When it is refused, the offer still shows in the capture screen.
@MainActor final class MicrophoneAlerts {
    static let offerID = "hwyd.microphone.offer"
    static let noticeID = "hwyd.microphone.notice"
    private static let category = "microphone-offer"
    private let notifications: SystemNotifications
    private var shown: MicrophoneOffer?
    private var changes: AnyCancellable?
    /// Whether the frontmost HWYD shows the pending offer (capture screen or notepad).
    var isShownInApp: @MainActor () -> Bool = { false }

    init(notifications: SystemNotifications) { self.notifications = notifications }

    /// Follows the offers of `capture`; answers go back to it.
    func follow(_ capture: CaptureSession, open: @escaping @MainActor () -> Void) {
        guard notifications.allowed else { return }
        changes = capture.$offer.sink { [weak self, weak capture] offer in
            MainActor.assumeIsolated {
                guard let self, let capture else { return }
                self.show(offer, answeredBy: capture, open: open)
            }
        }
        capture.onForcedSwitch = { [weak self] lost, next in self?.notice(lost: lost, next: next) }
    }
    private func show(_ offer: MicrophoneOffer?, answeredBy capture: CaptureSession, open: @escaping @MainActor () -> Void) {
        guard offer != shown else { return }
        shown = offer
        guard let offer else { notifications.withdraw([Self.offerID]); return }
        let keep = offer.current.map { String(localized: "Garder \($0)") } ?? String(localized: "Garder le micro actuel")
        let category = UNNotificationCategory(identifier: Self.category, actions: [
            UNNotificationAction(identifier: "switch", title: String(localized: "Basculer"), options: []),
            UNNotificationAction(identifier: "keep", title: keep, options: [])
        ], intentIdentifiers: [], options: [.customDismissAction])
        let id = offer.id.uuidString
        notifications.register([category], presentation: { [weak self] in
            self?.isShownInApp() == true ? [.list] : [.banner, .sound, .list]
        }) { [weak capture] action, userInfo in
            // Only the offer still pending: an older notification answers nothing.
            guard let capture, capture.offer?.id.uuidString == userInfo["offer"] as? String else { return }
            switch action {
            case "switch": Task { await capture.acceptOffer() }
            case "keep", UNNotificationDismissActionIdentifier: capture.declineOffer()
            case UNNotificationDefaultActionIdentifier: open()
            default: break
            }
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Nouveau micro disponible : \(offer.device.name)")
        content.body = MicrophoneText.offer(offer)
        content.categoryIdentifier = Self.category
        content.userInfo = ["offer": id]
        notifications.post(Self.offerID, content)
    }
    private func notice(lost: MicrophoneDevice, next: MicrophoneDevice) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Micro changé")
        content.body = String(localized: "Le micro \(lost.name) n’est plus disponible. L’enregistrement continue sur \(next.name).")
        notifications.post(Self.noticeID, content)
    }
}

/// What the capture screen and the notifications say about microphones.
enum MicrophoneText {
    /// The question, and for a Bluetooth headset what its microphone does to what the user hears.
    static func offer(_ offer: MicrophoneOffer) -> String {
        [String(localized: "Basculer l’enregistrement sur ce micro ?"), bluetooth(offer.device)].compactMap { $0 }.joined(separator: "\n")
    }
    static func bluetooth(_ device: MicrophoneDevice) -> String? {
        device.transport == .bluetooth ? String(localized: "Utiliser le micro de ce casque le fait passer en mode appel : le son que vous entendez sera de moindre qualité.") : nil
    }
}

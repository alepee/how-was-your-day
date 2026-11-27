import Combine
import Foundation
@preconcurrency import UserNotifications
import HWYDCore

/// The proposal to record a conversation another application seems to hold, as a system
/// notification: the user is in that application, not in HWYD. It carries « Enregistrer » and
/// « Pas cette fois »; clicking it records, dismissing it declines, and not answering leaves it
/// until the application went quiet. Nothing is recorded without one of these answers.
@MainActor final class ConversationAlerts {
    static let proposalID = "hwyd.conversation.proposal"
    private static let category = "conversation-proposal"
    private let notifications: SystemNotifications
    private var shown: ConversationProposal?
    private var changes: AnyCancellable?

    init(notifications: SystemNotifications) { self.notifications = notifications }

    /// Follows the proposals of `detector`; `record` starts the capture the user accepted.
    func follow(_ detector: ConversationDetector, record: @escaping @MainActor () -> Void) {
        guard notifications.allowed else { return }
        let category = UNNotificationCategory(identifier: Self.category, actions: [
            UNNotificationAction(identifier: "record", title: String(localized: "Enregistrer"), options: []),
            UNNotificationAction(identifier: "decline", title: String(localized: "Pas cette fois"), options: [])
        ], intentIdentifiers: [], options: [.customDismissAction])
        notifications.register([category]) { [weak detector] action, userInfo in
            // Only the proposal still pending: an older notification answers nothing.
            guard let detector, detector.proposal?.id.uuidString == userInfo["proposal"] as? String else { return }
            switch action {
            case "record", UNNotificationDefaultActionIdentifier: detector.answer(); record()
            case "decline", UNNotificationDismissActionIdentifier: detector.answer()
            default: break
            }
        }
        changes = detector.$proposal.sink { [weak self] proposal in
            MainActor.assumeIsolated { self?.show(proposal) }
        }
    }
    private func show(_ proposal: ConversationProposal?) {
        guard proposal != shown else { return }
        shown = proposal
        guard let proposal else { notifications.withdraw([Self.proposalID]); return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Une conversation semble en cours")
        content.body = String(localized: "\(proposal.app.name) utilise le micro. Cliquez pour l’enregistrer avec HWYD.")
        content.categoryIdentifier = Self.category
        content.userInfo = ["proposal": proposal.id.uuidString]
        notifications.post(Self.proposalID, content)
    }
}

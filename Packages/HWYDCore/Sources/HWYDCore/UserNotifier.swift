import Foundation

/// A place of the app the user can be taken to, from a notice or a link.
/// The app decides how to get there; reporters only name the destination.
public enum NavigationIntent: Hashable, Sendable {
    /// One session, on one of its tabs or on the default one.
    case session(UUID, SessionLink.Artifact?)
    /// The session's language choice, to process it again in another language.
    case languageChoice(UUID)
    /// The summary provider settings.
    case summarySettings
}

/// A short message for the user: what happened, and what they can do about it.
public struct UserNotice: Sendable {
    public enum Style: Sendable { case info, success, error }

    /// One answer offered with the notice.
    public struct Action: Identifiable, Sendable {
        public enum Effect: Sendable {
            /// Takes the user somewhere; the app resolves the destination.
            case navigate(NavigationIntent)
            /// Does something the reporter owns, such as a retry or an undo.
            case perform(@MainActor @Sendable () -> Void)
        }
        public let id = UUID()
        public var title: String
        public var effect: Effect

        public init(title: String, effect: Effect) { self.title = title; self.effect = effect }
        public static func navigate(_ title: String, to intent: NavigationIntent) -> Action { Action(title: title, effect: .navigate(intent)) }
        public static func perform(_ title: String, _ run: @escaping @MainActor @Sendable () -> Void) -> Action { Action(title: title, effect: .perform(run)) }
    }

    public var style: Style
    public var message: String
    public var actions: [Action]
    /// Stays until closed, even without actions.
    public var sticky: Bool
    /// Leaves on its own even with actions: an offer such as « Annuler » that does not need an answer.
    public var optional: Bool

    public init(style: Style, message: String, actions: [Action] = [], sticky: Bool = false, optional: Bool = false) {
        self.style = style; self.message = message; self.actions = actions; self.sticky = sticky; self.optional = optional
    }
    public static func info(_ message: String, actions: [Action] = [], sticky: Bool = false) -> UserNotice {
        UserNotice(style: .info, message: message, actions: actions, sticky: sticky)
    }
    public static func success(_ message: String, actions: [Action] = [], optional: Bool = false) -> UserNotice {
        UserNotice(style: .success, message: message, actions: actions, optional: optional)
    }
    public static func error(_ message: String, actions: [Action] = []) -> UserNotice {
        UserNotice(style: .error, message: message, actions: actions)
    }

    /// A notice that asks for a decision, or was made sticky, waits for the user; information leaves on its own.
    public var waitsForUser: Bool { sticky || (!actions.isEmpty && !optional) }
}

/// Port through which use cases and services tell the user what happened, without knowing how it is shown.
/// The app shows notices as toasts (`ToastCenter`); tests record them.
@MainActor public protocol UserNotifier: AnyObject {
    func notify(_ notice: UserNotice)
}

/// In-memory notifier for tests and headless runs: keeps every notice, in order.
@MainActor public final class RecordingNotifier: UserNotifier {
    public private(set) var notices: [UserNotice] = []
    public init() {}
    public func notify(_ notice: UserNotice) { notices.append(notice) }
    public var messages: [String] { notices.map(\.message) }
    public func clear() { notices = [] }
}

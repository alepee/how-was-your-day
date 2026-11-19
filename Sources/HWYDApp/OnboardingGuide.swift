import Combine
import HWYDCore

/// The welcome tour shown over the app: which step shows, and whether it is open. It opens on its own once, on the
/// first launch; the settings and the Help menu open it again.
@MainActor final class OnboardingGuide: ObservableObject {
    @Published private(set) var isPresented = false
    @Published var step: OnboardingStep = .record
    private let progress: OnboardingProgress

    init(settings: SettingsStore) { progress = OnboardingProgress(settings: settings) }

    /// Called once the user's library is loaded. Someone who already has sessions is not
    /// interrupted, and the tour is recorded as seen for them.
    func presentOnLaunch(hasSessions: Bool) {
        if progress.presentsOnLaunch(hasSessions: hasSessions) { present() }
        else if progress.seenVersion < OnboardingProgress.currentVersion { progress.markSeen() }
    }
    func present(at step: OnboardingStep = .record) { self.step = step; isPresented = true }
    func advance() { if let next = step.next { step = next } else { finish() } }
    func goBack() { if let previous = step.previous { step = previous } }
    /// Completed or skipped: it will not open on its own again.
    func finish() { progress.markSeen(); isPresented = false }
    /// The user went elsewhere from a menu or a shortcut: the open tour ends.
    func leave() { if isPresented { finish() } }
}

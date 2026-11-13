import Foundation
import HWYDCore

extension AppModel {
    /// Opens the recording addressed by a `hwyd://` link. Unknown links leave the current view untouched.
    func open(_ link: SessionLink) async {
        while isLoading { try? await Task.sleep(for: .milliseconds(100)) }
        guard let item = recordings.first(where: { $0.id == link.recordingID }) else {
            notifier.notify(.info(String(localized: "Session introuvable sur ce Mac.")))
            return
        }
        navigate(to: .session(item.id, link.artifact))
    }
}

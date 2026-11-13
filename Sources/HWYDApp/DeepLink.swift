import Foundation
import HWYDCore

extension AppModel {
    /// Opens the recording addressed by a `hwyd://` link. Unknown links leave the current view untouched.
    func open(_ link: SessionLink) async {
        while isLoading { try? await Task.sleep(for: .milliseconds(100)) }
        guard let item = recordings.first(where: { $0.id == link.recordingID }) else {
            notice = String(localized: "Session introuvable sur ce Mac.")
            return
        }
        select(item)
        switch link.artifact {
        case .notes: activeTab = .notes
        case .summary: activeTab = .summary
        case .transcript: activeTab = .transcript
        case nil: break
        }
    }
}

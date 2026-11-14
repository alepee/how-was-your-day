import HWYDCore
import SwiftUI

/// A notice shown as a short message stacked in the corner of the main window. Information leaves
/// on its own; a toast that offers a decision stays until it is answered or closed.
struct Toast: Identifiable {
    let id = UUID()
    let notice: UserNotice
    var style: UserNotice.Style { notice.style }
    var message: String { notice.message }
    var actions: [UserNotice.Action] { notice.actions }
    var staysOnScreen: Bool { notice.waitsForUser }
    /// Long enough to read a sentence; errors and optional actions get more time.
    var lifetime: Duration { style == .error || !actions.isEmpty ? .seconds(8) : .seconds(5) }
}

/// Shows the notices reported through `UserNotifier` as toasts: at most four, the same message
/// once, each announced to VoiceOver. Owns their timers. Actions that navigate are handed to `navigate`.
@Observable @MainActor final class ToastCenter: UserNotifier {
    private(set) var toasts: [Toast] = []
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]
    /// Resolves a navigation intent; set by the owner of the screens.
    @ObservationIgnored var navigate: (NavigationIntent) -> Void = { _ in }

    func notify(_ notice: UserNotice) {
        let toast = Toast(notice: notice)
        // The same message twice replaces the first one instead of stacking.
        toasts.removeAll { $0.message == toast.message && $0.style == toast.style }
        toasts.append(toast)
        while toasts.count > 4, let oldest = toasts.firstIndex(where: { !$0.staysOnScreen }) ?? toasts.indices.first {
            dismiss(toasts[oldest].id)
        }
        scheduleDismissal(toast)
        AccessibilityNotification.Announcement(toast.message).post()
    }
    func dismiss(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        toasts.removeAll { $0.id == id }
    }
    func run(_ action: UserNotice.Action, of toast: Toast) {
        dismiss(toast.id)
        switch action.effect {
        case .navigate(let intent): navigate(intent)
        case .perform(let run): run()
        }
    }
    /// Hovering keeps a toast on screen; leaving it gives a short delay before it goes.
    func hold(_ id: UUID, _ held: Bool) {
        guard let toast = toasts.first(where: { $0.id == id }), !toast.staysOnScreen else { return }
        timers.removeValue(forKey: id)?.cancel()
        if !held { scheduleDismissal(toast, after: .seconds(2)) }
    }
    private func scheduleDismissal(_ toast: Toast, after delay: Duration? = nil) {
        guard !toast.staysOnScreen else { return }
        timers[toast.id] = Task { [weak self] in
            try? await Task.sleep(for: delay ?? toast.lifetime)
            guard !Task.isCancelled else { return }
            self?.toasts.removeAll { $0.id == toast.id }
            self?.timers[toast.id] = nil
        }
    }
}

struct ToastStack: View {
    let center: ToastCenter
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.toasts) { toast in
                ToastView(center: center, toast: toast)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(20)
        .animation(.spring(duration: 0.3), value: center.toasts.map(\.id))
    }
}

private struct ToastView: View {
    let center: ToastCenter
    let toast: Toast
    @State private var hovering = false
    private var color: Color { toast.style == .error ? Studio.copper : Studio.mint }
    private var symbol: String {
        switch toast.style {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: Studio.Size.heading)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 10) {
                Text(toast.message).font(.system(size: Studio.Size.body)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if !toast.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(toast.actions.enumerated()), id: \.element.id) { index, action in
                            Button(action.title) { center.run(action, of: toast) }
                                .buttonStyle(StudioButtonStyle(primary: index == 0, destructive: toast.style == .error && index == 0, compact: true))
                        }
                    }
                }
            }
            Button { center.dismiss(toast.id) } label: {
                Image(systemName: "xmark").font(.system(size: Studio.Size.caption, weight: .semibold)).frame(width: 18, height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Studio.muted).accessibilityLabel("Fermer")
        }
        .padding(14).frame(width: 360, alignment: .leading)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(toast.style == .error ? Studio.copper.opacity(0.5) : Studio.line))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .foregroundStyle(Studio.text)
        // Clicking the toast runs its main action, when it has one.
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { if let first = toast.actions.first { center.run(first, of: toast) } }
        .onHover { inside in hovering = inside; center.hold(toast.id, inside) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(toast.style == .error ? .isStaticText : [])
    }
}

import AppKit
import Combine
import SwiftUI
import HWYDCore

struct RecordingOverlayView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let paused = model.isCapturePaused
        HStack(spacing: 10) {
            Button(action: openNotes) {
                HStack(spacing: 8) {
                    Image(systemName: paused ? "pause.circle.fill" : "record.circle").foregroundStyle(paused ? Studio.muted : Studio.copper)
                    Text(verbatim: "00:00:00").hidden().overlay(alignment: .leading) { Text(timeLabel(model.elapsed)) }
                        .monospacedDigit().font(.system(size: Studio.Size.body, weight: .medium))
                    VStack(spacing: 2) {
                        WaveformView(level: paused ? 0 : model.micLevel, color: Studio.copper).frame(width: 44, height: 12)
                        WaveformView(level: paused ? 0 : model.systemLevel).frame(width: 44, height: 12)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Ouvrir les notes")
            iconButton(paused ? "record.circle" : "pause.fill", help: paused ? "Reprendre" : "Pause") { model.toggleCapturePause() }
            iconButton("stop.fill", color: Studio.copper, help: "Terminer la session") { model.stopCapture() }
        }
        .font(.system(size: Studio.Size.body))
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
        .foregroundStyle(Studio.text)
        .background(Capsule().fill(Studio.surface).strokeBorder(Studio.line))
        .gesture(WindowDragGesture())
        .fixedSize()
        .preferredColorScheme(model.appearancePreference.colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(paused ? "En pause" : "Enregistrement")
    }
    private func iconButton(_ symbol: String, color: Color = Studio.text, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help)
    }
    private func openNotes() {
        guard let active = model.activeCapture else { return }
        model.select(active); model.showWindow?()
    }
}

@MainActor final class RecordingOverlayPanel {
    private let model: AppModel
    private var panel: NSPanel?
    private var visibility: AnyCancellable?
    init(model: AppModel) {
        self.model = model
        visibility = model.showsRecordingOverlay.sink { [weak self] visible in
            MainActor.assumeIsolated { if visible { self?.show() } else { self?.panel?.orderOut(nil) } }
        }
    }
    private func show() {
        if panel == nil {
            let host = FirstClickHostingView(rootView: RecordingOverlayView().environmentObject(model))
            let size = host.fittingSize
            let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
            panel.contentView = host
            let restored = panel.setFrameUsingName("HWYDRecordingOverlay") && NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
            if !restored, let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12))
            }
            panel.setFrameAutosaveName("HWYDRecordingOverlay")
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

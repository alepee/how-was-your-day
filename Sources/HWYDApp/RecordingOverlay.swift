import AppKit
import Combine
import SwiftUI
import HWYDCore

struct RecordingOverlayView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let paused = model.isCapturePaused, vertical = model.recordingOverlayOrientation == .vertical
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        stack {
            Image(systemName: "line.3.horizontal").rotationEffect(.degrees(vertical ? 0 : 90))
                .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).frame(width: 12, height: 18).overlay(WindowDragArea()).help("Déplacer")
            Button(action: openNotes) {
                stack {
                    Circle().fill(paused ? Studio.muted : Studio.copper).frame(width: 7, height: 7)
                    Text(timeLabel(model.elapsed)).monospacedDigit().font(.system(size: Studio.Size.body, weight: .medium))
                    VStack(spacing: 1) {
                        WaveformView(level: paused ? 0 : model.micLevel, color: Studio.copper).frame(width: 30, height: 9)
                        WaveformView(level: paused ? 0 : model.systemLevel).frame(width: 30, height: 9)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("Ouvrir les notes")
            iconButton(paused ? "play.fill" : "pause.fill", help: paused ? "Reprendre" : "Pause") { model.toggleCapturePause() }
            iconButton("stop.fill", color: Studio.copper, help: "Terminer la session") { model.stopCapture() }
        }
        .font(.system(size: Studio.Size.body))
        .padding(.horizontal, vertical ? 5 : 8).padding(.vertical, vertical ? 8 : 3)
        .foregroundStyle(Studio.text)
        .background(WindowDragArea())
        .background(RoundedRectangle(cornerRadius: 16).fill(Studio.surface).strokeBorder(Studio.line))
        .fixedSize()
        .preferredColorScheme(model.appearancePreference.colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(paused ? "En pause" : "Enregistrement")
    }
    private func iconButton(_ symbol: String, color: Color = Studio.text, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: Studio.Size.caption)).foregroundStyle(color).frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help)
    }
    private func openNotes() {
        guard let active = model.activeCapture else { return }
        model.select(active); model.showWindow?()
    }
}

extension RecordingOverlayOrientation {
    var title: String {
        switch self {
        case .horizontal: String(localized: "Horizontale")
        case .vertical: String(localized: "Verticale")
        }
    }
}

@MainActor final class RecordingOverlayPanel {
    private let model: AppModel
    private var panel: NSPanel?
    private var changes: Set<AnyCancellable> = []
    init(model: AppModel) {
        self.model = model
        model.showsRecordingOverlay.sink { [weak self] visible in
            MainActor.assumeIsolated { if visible { self?.show() } else { self?.panel?.orderOut(nil) } }
        }.store(in: &changes)
    }
    private func show() {
        if panel == nil {
            let host = FirstClickHostingView(rootView: RecordingOverlayView().environmentObject(model))
            host.onResize = { [weak self] in self?.fitContent() }
            let size = host.fittingSize
            let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false; panel.isMovable = false
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
    private func fitContent() {
        guard let panel, let size = panel.contentView?.fittingSize, size != panel.frame.size else { return }
        var frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
        if let screen = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private var grab: NSPoint?
        override func mouseDown(with event: NSEvent) { grab = event.locationInWindow }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let grab else { return }
            let pointer = NSPoint(x: window.frame.minX + event.locationInWindow.x, y: window.frame.minY + event.locationInWindow.y)
            window.setFrameOrigin(NSPoint(x: pointer.x - grab.x, y: pointer.y - grab.y))
        }
        override func mouseUp(with event: NSEvent) { grab = nil }
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    var onResize: (@MainActor () -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
}

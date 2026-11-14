import AppKit
import Combine
import SwiftUI
import HWYDCore

@main struct HWYDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppRoot.model
    @ObservedObject private var updater = AppRoot.updater
    var body: some Scene {
        MenuBarExtra {
            MenuContentView().environmentObject(model)
        } label: {
            if model.activeCaptureID != nil { Label(timeLabel(model.elapsed), systemImage: model.isCapturePaused ? "pause.circle" : "record.circle") }
            else { Image(systemName: "waveform") }
        }.menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                if updater.isAvailable {
                    Button("Rechercher les mises à jour…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Réglages…") { model.showSettings = true; model.showWindow?() }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Nouvelle session") { model.requestNewSession() }.keyboardShortcut("n")
                Button("Ouvrir les sessions") { model.showWindow?() }.keyboardShortcut("o")
            }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var notepad: NSPanel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        func check(_ run: @escaping @MainActor () async throws -> Void) {
            Task {
                do { try await run(); exit(0) }
                catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
            }
        }
        // The mode was read once, by the root. Synthetic modes return here and touch no user data.
        switch AppRoot.mode {
        case .asrTest(let directory): check { try await InteractionChecks.runTranscription(directory: directory) }; return
        case .uiTest(let directory): check { try await InteractionChecks.run(directory: directory) }; return
        case .selfTest(let directory, let seconds):
            do {
                guard seconds >= 2, seconds <= 14400 else { throw CaptureFailure(message: "Test duration must be between 2 and 14400 seconds") }
                try CoreAudioCapture.verifySyntheticCapture(directory: directory, seconds: seconds)
                FileHandle.standardOutput.write(Data("Synthetic two-track capture: PASS\n".utf8))
                try CoreAudioCapture.verifySyntheticSplitCapture(directory: directory)
                FileHandle.standardOutput.write(Data("Synthetic split-clock capture: PASS\n".utf8))
                exit(0)
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        case .snapshot(let directory): Snapshotter.run(into: directory); NSApp.terminate(nil); return
        case .preview, .app: break
        }
        let model = AppRoot.model
        model.showWindow = { [weak self] in self?.openWindow() }
        model.openNotepad = { [weak self] in self?.openNotepad() }
        // Only the installed app on its own data takes the shortcut, follows the calendar and
        // checks for updates: a `--demo` instance must not take them from a real one running alongside.
        let ownsSystem = AppRoot.mode == .app(examples: false)
        if ownsSystem { model.enableRecordingShortcut() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppRoot.model.systemWillSleep() }
        }
        model.calendar.onAction = { [weak model] event, join in
            Task { @MainActor in
                guard let model else { return }
                await model.sessionLibrary.ready
                model.showWindow?()
                if let event { model.joinMeeting(event, openLink: join) }
            }
        }
        if ownsSystem {
            model.calendar.start()
            AppRoot.updater.start(isBusy: { [weak model] in model?.isBusy ?? false },
                                  busyChanges: model.$isBusy.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
        }
        openWindow()
        // Loads the user's store; the examples have nothing to load.
        Task { await model.load() }
    }
    func openWindow() {
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            let host = NSHostingView(rootView: RootView().environmentObject(AppRoot.model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "How Was Your Day"; window.titlebarAppearsTransparent = true
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            window.minSize = NSSize(width: 860, height: 690); window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("HWYDMainWindow"); window.center(); window.delegate = self
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        FileHandle.standardError.write(Data("HWYD window visible=\(mainWindow?.isVisible ?? false), frame=\(String(describing: mainWindow?.frame))\n".utf8))
    }
    func openNotepad() {
        if notepad == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 650), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = String(localized: "Notes de session"); panel.isFloatingPanel = true; panel.level = .floating
            panel.isReleasedWhenClosed = false; panel.minSize = NSSize(width: 460, height: 500)
            panel.contentView = NSHostingView(rootView: NotepadWindow().environmentObject(AppRoot.model))
            panel.center(); notepad = panel
        }
        notepad?.makeKeyAndOrderFront(nil)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        // Snapshot and test modes never act on external links.
        guard !AppRoot.mode.isSynthetic, let link = urls.lazy.compactMap(SessionLink.init).first else { return }
        openWindow()
        Task { await AppRoot.model.open(link) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppRoot.model
        if case .snapshot = AppRoot.mode { return .terminateNow }
        // The capture ends first, so its transcription request is cancelled with the rest.
        let stopping = model.stopCapture()
        Task {
            await stopping.value
            model.cancelProcessing(); model.cancelSummary()
            await model.idle()
            await model.flush()
            if model.hasUnsavedChanges { openWindow(); NSApp.reply(toApplicationShouldTerminate: false) }
            else { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openWindow(); return true }
}
struct NotepadWindow: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if let recording = model.activeCapture { CaptureView(recording: recording, compact: true) }
            else { EmptyPanel(symbol: "checkmark.circle", title: String(localized: "Session terminée"), detail: String(localized: "Vos notes sont disponibles dans la bibliothèque.")) }
        }.foregroundStyle(Studio.text).background(Studio.background).preferredColorScheme(model.appearancePreference.colorScheme)
    }
}

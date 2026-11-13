import AppKit
import Combine
import SwiftUI
import HWYDCore

@MainActor enum AppEnvironment {
    static let model = AppModel(preview: CommandLine.arguments.contains("--asr-test") || CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--ui-test"))
    static let updater = AppUpdater()
}
@main struct HWYDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppEnvironment.model
    @ObservedObject private var updater = AppEnvironment.updater
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
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--asr-test"), args.count > index + 1 {
            Task {
                do { try await InteractionChecks.runTranscription(directory: URL(fileURLWithPath: args[index + 1])); exit(0) }
                catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
            }
            return
        }
        if let index = args.firstIndex(of: "--ui-test"), args.count > index + 1 {
            Task {
                do { try await InteractionChecks.run(directory: URL(fileURLWithPath: args[index + 1])); exit(0) }
                catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
            }
            return
        }
        if let index = args.firstIndex(of: "--self-test"), args.count > index + 1 {
            do {
                let seconds = args.count > index + 2 ? Double(args[index + 2]) ?? 2 : 2
                guard seconds >= 2, seconds <= 14400 else { throw CaptureFailure(message: "Test duration must be between 2 and 14400 seconds") }
                try CoreAudioCapture.verifySyntheticCapture(directory: URL(fileURLWithPath: args[index + 1]), seconds: seconds)
                FileHandle.standardOutput.write(Data("Synthetic two-track capture: PASS\n".utf8))
                try CoreAudioCapture.verifySyntheticSplitCapture(directory: URL(fileURLWithPath: args[index + 1]))
                FileHandle.standardOutput.write(Data("Synthetic split-clock capture: PASS\n".utf8))
                exit(0)
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        if let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 {
            Snapshotter.run(into: URL(fileURLWithPath: args[index + 1])); NSApp.terminate(nil); return
        }
        let model = AppEnvironment.model
        if args.contains("--demo") { model.enterDemo() }
        model.showWindow = { [weak self] in self?.openWindow() }
        model.openNotepad = { [weak self] in self?.openNotepad() }
        // A demo instance must not take the shortcut from a real one running alongside.
        if !args.contains("--demo") { model.enableRecordingShortcut() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppEnvironment.model.systemWillSleep() }
        }
        model.calendar.onAction = { [weak model] event, join in
            Task { @MainActor in
                guard let model else { return }
                await model.sessionLibrary.ready
                model.showWindow?()
                if let event { model.joinMeeting(event, openLink: join) }
            }
        }
        if !model.isDemoMode { model.calendar.start() }
        // Synthetic modes returned above; a `--demo` instance makes no network request either.
        if !args.contains("--demo") {
            AppEnvironment.updater.start(isBusy: { [weak model] in model?.isBusy ?? false },
                                         busyChanges: model.$isBusy.removeDuplicates().map { _ in () }.eraseToAnyPublisher())
        }
        openWindow()
        Task { if !model.isDemoMode { await model.load() } }
    }
    func openWindow() {
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            let host = NSHostingView(rootView: RootView().environmentObject(AppEnvironment.model))
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
            panel.contentView = NSHostingView(rootView: NotepadWindow().environmentObject(AppEnvironment.model))
            panel.center(); notepad = panel
        }
        notepad?.makeKeyAndOrderFront(nil)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        // Snapshot and test modes never act on external links.
        guard !CommandLine.arguments.contains(where: { ["--asr-test", "--snapshot", "--self-test", "--ui-test"].contains($0) }),
              let link = urls.lazy.compactMap(SessionLink.init).first else { return }
        openWindow()
        Task { await AppEnvironment.model.open(link) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppEnvironment.model
        if CommandLine.arguments.contains("--snapshot") { return .terminateNow }
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

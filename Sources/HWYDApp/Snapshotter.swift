import AppKit
import SwiftUI
import HWYDCore

@MainActor enum Snapshotter {
    static func run(into directory: URL) {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { print(error); return }
        for preference in [AppearancePreference.light, .dark] {
            let destination = directory.appendingPathComponent(preference.rawValue)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            runTheme(into: destination, preference: preference)
        }
    }
    private static func runTheme(into directory: URL, preference: AppearancePreference) {
        let model = AppModel(preview: true)
        model.appearancePreference = preference
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 770), to: directory.appendingPathComponent("studio-library.png"))
        var playerExample = Recording(title: "Aperçu synthétique du lecteur")
        playerExample.duration = 120
        playerExample.audioChunks = [.init(source: .mic, relativePath: "preview-mic.caf", start: 0, duration: 120), .init(source: .system, relativePath: "preview-system.caf", start: 0, duration: 120)]
        model.playbackTime = 43
        for (source, shift) in [(AudioSource.mic, 0), (.system, 37)] {
            model.trackEnvelopes[source] = TrackEnvelope(peaks: (0..<600).map { index in
                let phrase = (index + shift) % 140
                return phrase < 85 ? Float(abs(sin(Double(index + shift) * 0.21)) * 0.5 + 0.02) : 0
            }, available: true)
        }
        render(SessionPlayerView(recording: playerExample).environmentObject(model), size: .init(width: 730, height: 220), to: directory.appendingPathComponent("studio-player.png"))
        model.trackEnvelopes = [:]; model.playbackTime = 0
        model.selectedID = model.recordings.first?.id
        model.activeTab = .transcript
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-transcript.png"))
        var splitExample = TranscriptSegment(start: 12, end: 16, speakerID: nil, source: .mic, text: "Oui. Bonjour à tous.")
        splitExample.words = [.init(text: "Oui.", start: 12, end: 12.5), .init(text: " Bonjour", start: 13, end: 14), .init(text: " à", start: 14, end: 14.5), .init(text: " tous.", start: 14.5, end: 16)]
        render(SegmentSplitView(recordingID: model.selectedID!, segment: splitExample).environmentObject(model), size: .init(width: 580, height: 490), to: directory.appendingPathComponent("studio-split.png"))
        model.activeTab = .notes
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-notes.png"))
        model.activeTab = .summary
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-summary.png"))
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 1500), to: directory.appendingPathComponent("studio-summary-full.png"))
        render(VoiceIdentityView().environmentObject(model), size: .init(width: 610, height: 700), to: directory.appendingPathComponent("studio-voice-identity.png"))
        model.activeCaptureID = model.selectedID; model.elapsed = 1122; model.micLevel = 0.65; model.systemLevel = 0.35
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 850), to: directory.appendingPathComponent("studio-capture.png"))
        render(NotepadWindow().environmentObject(model), size: .init(width: 500, height: 650), to: directory.appendingPathComponent("studio-notepad.png"))
        model.editingSpeakerID = model.selected?.speakers.first?.id
        render(SpeakerEditor().environmentObject(model), size: .init(width: 440, height: 300), to: directory.appendingPathComponent("studio-speaker.png"))
        model.editingSpeakerID = nil
        render(MenuContentView().environmentObject(model), size: .init(width: 340, height: 350), to: directory.appendingPathComponent("studio-menu.png"))
        model.calendar.enabled = true
        model.calendar.calendars = [.init(id: "preview", title: "Travail", account: "Google")]
        model.calendar.selectedCalendars = ["preview"]
        model.calendar.status = "1 réunion dans les 7 prochains jours"
        model.calendar.notificationStatus = "Aperçu synthétique, aucune notification envoyée"
        model.calendar.upcoming = [.init(id: "preview-meeting", title: "Point produit", start: Date().addingTimeInterval(600), end: Date().addingTimeInterval(2400), calendarTitle: "Travail")]
        render(CalendarSettingsView(calendar: model.calendar), size: .init(width: 500, height: 760), to: directory.appendingPathComponent("studio-calendar-settings.png"))
        render(UpcomingMeetingsView(calendar: model.calendar).environmentObject(model), size: .init(width: 780, height: 130), to: directory.appendingPathComponent("studio-calendar-upcoming.png"))
        model.calendar.enabled = false; model.calendar.upcoming = []; model.calendar.calendars = []
        model.showSettings = true
        for category in SettingsCategory.allCases {
            model.settingsCategory = category
            render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-settings-\(category.id == SettingsCategory.general.id ? "general" : String(describing: category)).png"))
        }
        model.settingsCategory = .summary
        render(RootView().environmentObject(model), size: .init(width: 860, height: 660), to: directory.appendingPathComponent("studio-settings-compact.png"))
        model.showSettings = false
        model.activeCaptureID = nil; model.isDemoMode = false
        var pending = Recording(title: "Préparer le prototype")
        pending.transcriptState = .pending
        model.recordings = [pending]; model.selectedID = pending.id; model.processingID = pending.id; model.activeTab = .transcript
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-processing.png"))
        pending.transcriptState = .ready
        pending.segments = [.init(start: 0.12, end: 6.17, speakerID: nil, source: .mic, text: "Bonjour Antoine, la réunion commence à 9h. Nous devons préparer le prototype pour vendredi.")]
        pending.transcriptVersion = 1
        model.processingID = nil; model.recordings = [pending]
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-asr.png"))
        model.recordings = []; model.activeCaptureID = nil; model.selectedID = nil; model.isDemoMode = false
        render(RootView().environmentObject(model), size: .init(width: 900, height: 700), to: directory.appendingPathComponent("studio-empty.png"))
        print("Snapshots: \(directory.path)")
    }
    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Studio.background))
        host.appearance = NSApp.appearance; host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSApp.appearance; window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35)); host.layoutSubtreeIfNeeded(); host.display()
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            bitmap.size = size; host.cacheDisplay(in: host.bounds, to: bitmap)
            do { try bitmap.representation(using: .png, properties: [:])?.write(to: url) } catch { print(error) }
        }
        window.orderOut(nil)
    }
}

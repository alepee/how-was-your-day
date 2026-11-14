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
        var playerExample = Recording(title: "Aperçu synthétique du lecteur") // l10n:ignore
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
        // Playback follow: the passage heard at 0:25 is highlighted. No audio is played.
        model.playbackTime = 25; model.updatePlaybackFocus()
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-transcript-follow.png"))
        model.playbackTime = 0; model.playback.activeSegmentIDs = []
        renderVoiceTiles(model: model, to: directory.appendingPathComponent("studio-voices.png"))
        var splitExample = TranscriptSegment(start: 12, end: 16, speakerID: nil, source: .mic, text: "Oui. Bonjour à tous.") // l10n:ignore
        splitExample.words = [.init(text: "Oui.", start: 12, end: 12.5), .init(text: " Bonjour", start: 13, end: 14), .init(text: " à", start: 14, end: 14.5), .init(text: " tous.", start: 14.5, end: 16)] // l10n:ignore
        render(SegmentSplitView(recordingID: model.selectedID!, segment: splitExample).environmentObject(model), size: .init(width: 580, height: 490), to: directory.appendingPathComponent("studio-split.png"))
        model.activeTab = .notes
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-notes.png"))
        model.activeTab = .summary
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-summary.png"))
        // Summary export of the demo session, laid out as the user would receive it. No real data.
        if let item = model.selected, item.summary != nil {
            try? SummaryPDF.write(item, to: directory.appendingPathComponent("summary-export.pdf"))
            // A long synthetic summary checks pagination, assignees and due dates.
            if var long = item.summaryProvenance, let firstAction = long.structured.action_items.first {
                let sample = long.structured
                long.structured.decisions = Array(repeating: sample.decisions, count: 6).flatMap { $0 }
                long.structured.action_items = (0..<6).map { index in
                    var action = firstAction
                    action.assignee_name = ["Camille Durand", nil, "Léa"][index % 3]; action.due_date = index.isMultiple(of: 2) ? "vendredi" : nil // l10n:ignore
                    return action
                }
                long.structured.details = (0..<9).compactMap { index in
                    guard var topic = sample.details?[index % (sample.details?.count ?? 1)] else { return nil }
                    topic.text = Array(repeating: topic.text, count: index == 4 ? 40 : 1 + index % 3).joined(separator: "\n")
                    return topic
                }
                var copy = item; copy.summaryProvenance = long
                try? SummaryPDF.write(copy, to: directory.appendingPathComponent("summary-export-long.pdf"))
            }
            try? SummaryExport.markdown(item)?.write(to: directory.appendingPathComponent("summary-export.md"), atomically: true, encoding: .utf8)
        }
        model.notifier.notify(.error(String(localized: "Synthèse : \(SummaryFailure.outputTruncated.localizedDescription)"),
                                     actions: [.perform(String(localized: "Réessayer")) {}, .navigate(String(localized: "Réglages"), to: .summarySettings)]))
        let sampleTitle = "Point produit" // l10n:ignore
        model.notifier.notify(.success(String(localized: "Synthèse prête : \(sampleTitle)"), actions: [.perform(String(localized: "Afficher")) {}]))
        let sampleName = "Camille"
        model.notifier.notify(.info(String(localized: "Voix nommée \(sampleName) dans toute cette session.") + " " + String(localized: "Nommer une voix ne crée pas d’empreinte vocale.")))
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-toasts.png"))
        model.toastCenter.dismissAll()
        let previousSelection = model.selectedID
        model.requestNewSession(); model.newSessionKind = .meeting
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-new-session.png"))
        model.showNewSession = false; model.selectedID = previousSelection
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 1500), to: directory.appendingPathComponent("studio-summary-full.png"))
        // Wide window: the outline appears beside the reading column.
        render(RootView().environmentObject(model), size: .init(width: 1440, height: 1500), to: directory.appendingPathComponent("studio-summary-wide.png"))
        model.activeCaptureID = model.selectedID; model.elapsed = 1122; model.micLevel = 0.65; model.systemLevel = 0.35
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 850), to: directory.appendingPathComponent("studio-capture.png"))
        model.isCapturePaused = true; model.micLevel = 0; model.systemLevel = 0
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 850), to: directory.appendingPathComponent("studio-capture-paused.png"))
        model.isCapturePaused = false
        render(NotepadWindow().environmentObject(model), size: .init(width: 500, height: 650), to: directory.appendingPathComponent("studio-notepad.png"))
        model.editingSpeakerID = model.selected?.speakers.first?.id
        render(SpeakerEditor().environmentObject(model), size: .init(width: 600, height: 360), to: directory.appendingPathComponent("studio-speaker.png"))
        model.editingSpeakerID = nil
        render(MenuContentView().environmentObject(model), size: .init(width: 340, height: 350), to: directory.appendingPathComponent("studio-menu.png"))
        model.calendar.enabled = true
        model.calendar.calendars = [.init(id: "preview", title: "Travail", account: "Google")] // l10n:ignore
        model.calendar.selectedCalendars = ["preview"]
        let upcomingCount = 1
        model.calendar.status = String(localized: "\(upcomingCount) réunion(s) dans les 7 prochains jours")
        model.calendar.notificationStatus = String(localized: "Notifications autorisées")
        model.calendar.upcoming = [.init(id: "preview-meeting", title: "Point produit", start: Date().addingTimeInterval(600), end: Date().addingTimeInterval(2400), calendarTitle: "Travail", meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")), .init(id: "preview-room", title: "Atelier en salle", start: Date().addingTimeInterval(4200), end: Date().addingTimeInterval(6000), calendarTitle: "Travail")] // l10n:ignore
        render(CalendarSettingsView(calendar: model.calendar), size: .init(width: 500, height: 760), to: directory.appendingPathComponent("studio-calendar-settings.png"))
        render(UpcomingMeetingsView(calendar: model.calendar).environmentObject(model), size: .init(width: 780, height: 210), to: directory.appendingPathComponent("studio-calendar-upcoming.png"))
        model.calendar.enabled = false; model.calendar.upcoming = []; model.calendar.calendars = []
        model.showSettings = true
        for category in SettingsCategory.allCases {
            model.settingsCategory = category
            render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-settings-\(category.id == SettingsCategory.general.id ? "general" : String(describing: category)).png"))
        }
        renderVoicePeople(model: model, to: directory.appendingPathComponent("studio-settings-voice-people.png"))
        model.settingsCategory = .summary
        render(RootView().environmentObject(model), size: .init(width: 860, height: 660), to: directory.appendingPathComponent("studio-settings-compact.png"))
        // Preview models never read the keychain or persist this choice.
        model.summarySettings.select(.anthropic)
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-settings-summary-remote.png"))
        model.summarySettings.select(.agent)
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-settings-summary-agent.png"))
        model.summarySettings.select(.local)
        model.showSettings = false
        model.activeCaptureID = nil; model.isDemoMode = false
        var pending = Recording(title: "Préparer le prototype") // l10n:ignore
        pending.transcriptState = .pending
        model.recordings = [pending]; model.selectedID = pending.id; model.work = WorkSnapshot(running: .transcription(session: pending.id)); model.activeTab = .transcript
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-processing.png"))
        // A transcription requested while other work runs says it waits its turn.
        var waiting = pending; waiting.transcriptState = .unavailable
        model.recordings = [waiting]; model.work = WorkSnapshot(running: .summary(session: UUID()), queued: [.transcription(session: pending.id)])
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-processing-queued.png"))
        pending.transcriptState = .ready
        pending.segments = [.init(start: 0.12, end: 6.17, speakerID: nil, source: .mic, text: "Bonjour Antoine, la réunion commence à 9h. Nous devons préparer le prototype pour vendredi.")] // l10n:ignore
        pending.transcriptVersion = 1
        model.work = WorkSnapshot(); model.recordings = [pending]
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-asr.png"))
        // The summary button explains why it is unavailable: a hosted provider without a key. Preview models never read the keychain.
        model.summarySettings.enabled = true; model.summarySettings.select(.anthropic); model.activeTab = .summary
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-summary-unavailable.png"))
        model.summarySettings.enabled = false; model.summarySettings.select(.local); model.activeTab = .transcript
        model.recordings = []; model.activeCaptureID = nil; model.selectedID = nil; model.isDemoMode = false
        render(RootView().environmentObject(model), size: .init(width: 900, height: 700), to: directory.appendingPathComponent("studio-empty.png"))
        print("Snapshots: \(directory.path)")
    }
    /// Synthetic voices covering the three states. Audio chunks are references only; nothing is read or played.
    private static func renderVoiceTiles(model: AppModel, to url: URL) {
        let lea = VoicePerson(name: "Léa") // l10n:ignore
        var proposed = Speaker(label: "Léa", source: .system) // l10n:ignore
        proposed.proposedIdentity = VoiceMatch(personID: lea.id, score: 0.81, margin: 0.14, channel: .remote)
        let room = Speaker(label: "Voix 1"), named = Speaker(label: "Camille", confirmed: true, source: .system) // l10n:ignore
        var duplicate = Speaker(label: "Voix 4"); duplicate.ignored = true // l10n:ignore
        var example = Recording(title: "Voix synthétiques", speakers: [room, proposed, named, duplicate], segments: [ // l10n:ignore
            .init(start: 0, end: 48, speakerID: room.id, source: .mic, text: "a"),
            .init(start: 50, end: 61, speakerID: proposed.id, source: .system, text: "b"),
            .init(start: 62, end: 140, speakerID: named.id, source: .system, text: "c"),
            .init(start: 141, end: 150, speakerID: duplicate.id, source: .mic, text: "d")])
        example.audioChunks = [.init(source: .mic, relativePath: "preview-mic.caf", start: 0, duration: 150)]
        let previousPeople = model.people, previousSelection = model.selectedID
        model.people = [lea]; model.recordings.append(example); model.selectedID = example.id; model.playback.voiceID = room.id
        render(VoiceTilesView(recording: example).environmentObject(model).padding(16), size: .init(width: 1040, height: 110), to: url)
        model.playback.voiceID = nil; model.people = previousPeople; model.recordings.removeAll { $0.id == example.id }; model.selectedID = previousSelection
    }
    /// Remembered people with their samples per session. Synthetic: the keychain is never read.
    private static func renderVoicePeople(model: AppModel, to url: URL) {
        var brice = VoicePerson(name: "Brice"); brice.enrollmentRequestedAt = Date(); brice.enrolledChannels = [.mic, .remote]
        var lea = VoicePerson(name: "Léa"); lea.enrollmentRequestedAt = Date(); lea.enrolledChannels = [.mic] // l10n:ignore
        var opposed = VoicePerson(name: "Jordan"); opposed.opposed = true
        let session = Recording(title: "Point produit", isDemo: true)
        let previousPeople = model.people
        model.people = [brice, lea, opposed]; model.recordings.append(session)
        model.voiceContributions[brice.id] = [
            .init(recordingID: session.id, channel: .mic, count: 1, addedAt: Date()),
            .init(recordingID: session.id, channel: .remote, count: 1, addedAt: Date()),
            .init(recordingID: nil, channel: .mic, count: 3, addedAt: nil)]
        render(VStack(spacing: 0) { VoicePersonRow(person: brice, expanded: true); VoicePersonRow(person: lea); VoicePersonRow(person: opposed) }
            .environmentObject(model).padding(24), size: .init(width: 720, height: 300), to: url)
        model.people = previousPeople; model.recordings.removeAll { $0.id == session.id }; model.voiceContributions = [:]
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

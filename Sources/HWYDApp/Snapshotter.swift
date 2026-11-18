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
    /// A session of the user's, ended an hour ago, where recording resumed once: the header offers
    /// to resume again and the transcript marks where it did. No capture can start.
    private static func renderResumedSession(preferences: SettingsStore, to url: URL) {
        let alice = Speaker(label: "Alice", confirmed: true), you = Speaker(label: "Vous", confirmed: true) // l10n:ignore
        var item = Recording(title: "Point d’équipe", kind: .meeting, startedAt: Date().addingTimeInterval(-5400), duration: 1260, speakers: [alice, you], segments: [ // l10n:ignore
            .init(start: 14, end: 22, speakerID: alice.id, source: .system, text: "On fait le point sur la livraison de jeudi."), // l10n:ignore
            .init(start: 25, end: 31, speakerID: you.id, source: .mic, text: "Il reste la relecture des textes."), // l10n:ignore
            .init(start: 742, end: 750, speakerID: you.id, source: .mic, text: "On reprend : la relecture est faite."), // l10n:ignore
            .init(start: 753, end: 760, speakerID: alice.id, source: .system, text: "Parfait, je prépare l’annonce.")]) // l10n:ignore
        item.audioChunks = [.init(source: .mic, relativePath: "preview-mic.caf", start: 0, duration: 1260)]
        item.endedAt = Date().addingTimeInterval(-3600)
        item.boundaries = [CaptureBoundary(offset: 735, at: Date().addingTimeInterval(-4200), reason: .resumed, microphone: "MacBook Pro Microphone")]
        let model = AppModel(environment: .preview(recordings: [item], preferences: preferences, capture: .unavailable("Snapshots never record."))) // l10n:ignore
        model.select(item); model.activeTab = .transcript
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: url)
    }
    /// A capture clock the snapshots set by hand.
    @MainActor private final class ManualClock { var time: TimeInterval = 0 }
    /// Lets the tasks of the main actor run until `condition` holds, at most five seconds.
    /// A fictional slide, as a screenshot pasted into the notes would look.
    private static func syntheticSlide() -> Data? {
        let width = 1600, height = 900
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(red: 0.96, green: 0.97, blue: 0.96, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.15, green: 0.41, blue: 0.32, alpha: 1); context.fill(CGRect(x: 120, y: 700, width: 900, height: 70))
        context.setFillColor(red: 0.6, green: 0.65, blue: 0.68, alpha: 1)
        for (row, length) in [1100, 980, 1200, 760].enumerated() { context.fill(CGRect(x: 120, y: 560 - row * 90, width: length, height: 34)) }
        context.setFillColor(red: 0.6, green: 0.29, blue: 0.18, alpha: 1); context.fill(CGRect(x: 1250, y: 140, width: 230, height: 330))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
    private static func settle(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    /// Every scene gets its own preview model: fictional sessions, simulated capture, in-memory
    /// preferences holding the theme. Nothing real is read or written, and no state is forced
    /// into a model: each one reaches its state through its own requests and doubles.
    private static func runTheme(into directory: URL, preference: AppearancePreference) {
        let preferences = InMemorySettings()
        preferences.set(preference.rawValue, for: .appearance)
        let model = AppModel(environment: .preview(preferences: preferences))
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
        renderResumedSession(preferences: preferences, to: directory.appendingPathComponent("studio-transcript-resumed.png"))
        renderVoiceTiles(preferences: preferences, to: directory.appendingPathComponent("studio-voices.png"))
        var splitExample = TranscriptSegment(start: 12, end: 16, speakerID: nil, source: .mic, text: "Oui. Bonjour à tous.") // l10n:ignore
        splitExample.words = [.init(text: "Oui.", start: 12, end: 12.5), .init(text: " Bonjour", start: 13, end: 14), .init(text: " à", start: 14, end: 14.5), .init(text: " tous.", start: 14.5, end: 16)] // l10n:ignore
        render(SegmentSplitView(recordingID: model.selectedID!, segment: splitExample).environmentObject(model), size: .init(width: 580, height: 490), to: directory.appendingPathComponent("studio-split.png"))
        if let example = model.selected,
           let pivot = example.segments.last(where: { segment in example.speakers.first { $0.id == segment.speakerID }?.confirmed == true && example.voiceSplit(at: segment.id)?.before.isEmpty == false }) {
            render(VoiceSplitSheet(recording: example, segment: pivot) { _ in }.environmentObject(model), size: .init(width: 600, height: 470), to: directory.appendingPathComponent("studio-voice-split.png"))
        }
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
            // Agent summary with a synthetic context note: the export sheet, and an export that keeps the note but not the details.
            if var agent = item.summaryProvenance {
                agent.structured.context = [SummaryContextNote(title: "Projet exemple", text: "Prolonge une décision fictive du mois précédent.", sources: ["notes/exemple.md"])] // l10n:ignore
                var copy = item; copy.summaryProvenance = agent; copy.summary = agent.markdown
                render(SummaryExportSheet(recording: copy, format: .pdf) { _ in }, size: .init(width: 440, height: 420), to: directory.appendingPathComponent("studio-summary-export-sheet.png"))
                let chosen = SummarySection.exportDefault.union([.context]).subtracting([.details])
                try? SummaryPDF.write(copy, sections: chosen, to: directory.appendingPathComponent("summary-export-context.pdf"))
                try? SummaryExport.markdown(copy, sections: chosen)?.write(to: directory.appendingPathComponent("summary-export-context.md"), atomically: true, encoding: .utf8)
            }
        }
        // Toasts come from their own model, so the other scenes show none.
        let toasts = AppModel(environment: .preview(preferences: preferences))
        toasts.selectedID = toasts.recordings.first?.id; toasts.activeTab = .summary
        toasts.notifier.notify(.error(String(localized: "Synthèse : \(SummaryFailure.outputTruncated.localizedDescription)"),
                                      actions: [.perform(String(localized: "Réessayer")) {}, .navigate(String(localized: "Réglages"), to: .summarySettings)]))
        let sampleTitle = "Point produit" // l10n:ignore
        toasts.notifier.notify(.success(String(localized: "Synthèse prête : \(sampleTitle)"), actions: [.perform(String(localized: "Afficher")) {}]))
        let sampleName = "Camille"
        toasts.notifier.notify(.info(String(localized: "Voix nommée \(sampleName) dans toute cette session.") + " " + String(localized: "Nommer une voix ne crée pas d’empreinte vocale.")))
        render(RootView().environmentObject(toasts), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-toasts.png"))
        let previousSelection = model.selectedID
        model.requestNewSession(); model.newSessionKind = .meeting
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-new-session.png"))
        model.newSessionConsentAt = Date()
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-new-session-stamped.png"))
        model.newSessionConsentAt = nil
        model.showNewSession = false; model.selectedID = previousSelection
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 1500), to: directory.appendingPathComponent("studio-summary-full.png"))
        // Wide window: the outline appears beside the reading column.
        render(RootView().environmentObject(model), size: .init(width: 1440, height: 1500), to: directory.appendingPathComponent("studio-summary-wide.png"))
        renderCapture(of: model.selected, preferences: preferences, into: directory)
        // Processing: a transcription runs, held by its job, then waits behind a summary.
        var pending = Recording(title: "Préparer le prototype") // l10n:ignore
        pending.transcriptState = .pending
        let running = WorkCoordinator()
        let processing = AppModel(environment: .preview(recordings: [pending], preferences: preferences, coordinator: running))
        processing.selectedID = pending.id; processing.activeTab = .transcript
        hold(.transcription(session: pending.id), on: running)
        settle { processing.processingID == pending.id }
        render(RootView().environmentObject(processing), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-processing.png"))
        // A transcription requested while other work runs says it waits its turn.
        var waiting = pending; waiting.transcriptState = .unavailable
        let busy = WorkCoordinator()
        let queued = AppModel(environment: .preview(recordings: [waiting], preferences: preferences, coordinator: busy))
        queued.selectedID = waiting.id; queued.activeTab = .transcript
        hold(.summary(session: UUID()), on: busy); hold(.transcription(session: pending.id), on: busy)
        settle { queued.work.isQueued(.transcription(session: pending.id)) }
        render(RootView().environmentObject(queued), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-processing-queued.png"))
        pending.transcriptState = .ready
        pending.segments = [.init(start: 0.12, end: 6.17, speakerID: nil, source: .mic, text: "Bonjour Antoine, la réunion commence à 9h. Nous devons préparer le prototype pour vendredi.")] // l10n:ignore
        pending.transcriptVersion = 1
        let transcribed = AppModel(environment: .preview(recordings: [pending], preferences: preferences))
        transcribed.selectedID = pending.id; transcribed.activeTab = .transcript
        render(RootView().environmentObject(transcribed), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-asr.png"))
        // The summary button explains why it is unavailable: a hosted provider without a key. Preview models never read the keychain.
        transcribed.summarySettings.enabled = true; transcribed.summarySettings.select(.anthropic); transcribed.activeTab = .summary
        render(RootView().environmentObject(transcribed), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-summary-unavailable.png"))
        // Summary tab of the user's own session with a voice left unidentified: before a summary,
        // then above an existing one; then a summary the transcript outgrew after a correction.
        var reviewed = DemoContent.recordings()[0]; reviewed.isDemo = false; reviewed.state = .sealed
        var unsummarized = reviewed; unsummarized.summary = nil; unsummarized.summaryProvenance = nil
        var corrected = reviewed
        if let unknown = corrected.speakers.first(where: { !$0.confirmed }) { try? corrected.renameSpeaker(unknown.id, to: "Léa") } // l10n:ignore
        for (item, name) in [(unsummarized, "studio-summary-voices-pending"), (reviewed, "studio-summary-voices"), (corrected, "studio-summary-stale")] {
            let summary = AppModel(environment: .preview(recordings: [item], preferences: preferences))
            summary.summarySettings.enabled = true; summary.summarySettings.localModel = "fixture" // l10n:ignore
            summary.selectedID = item.id; summary.activeTab = .summary
            render(RootView().environmentObject(summary), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent(name + ".png"))
        }
        let empty = AppModel(environment: .preview(recordings: [], preferences: preferences))
        render(RootView().environmentObject(empty), size: .init(width: 900, height: 700), to: directory.appendingPathComponent("studio-empty.png"))
        print("Snapshots: \(directory.path)")
    }
    /// Starts a job on the coordinator that runs until the process ends: the views show what the
    /// coordinator reports, as they do for real work.
    private static func hold(_ job: WorkJob, on coordinator: WorkCoordinator) {
        Task { await coordinator.request(job) { try? await Task.sleep(for: .seconds(3600)) } }
    }
    /// A simulated capture of the example `shown`, at 18:42 on a clock the snapshot sets, with
    /// fixed levels, then paused; the settings and the menu are rendered while it runs.
    private static func renderCapture(of shown: Recording?, preferences: InMemorySettings, into directory: URL) {
        guard let shown else { return }
        let clock = ManualClock(), capture = SimulatedCapture(animatesLevels: false)
        // The example being recorded is not listed among the recent sessions.
        let model = AppModel(environment: .preview(examples: DemoContent.recordings().filter { $0.title != shown.title }, preferences: preferences,
                                                   capture: .simulated { capture }, clock: { clock.time }))
        model.startCapture(kind: shown.kind, title: shown.title)
        settle { model.activeCaptureID != nil }
        guard let id = model.activeCaptureID else { return }
        model.update(id) { $0.notes = shown.notes; $0.noteEntries = shown.noteEntries; $0.consentAnnounced = shown.consentAnnounced }
        clock.time = 1122; capture.emit(.levels(mic: 0.65, system: 0.35))
        settle { model.elapsed == 1122 && model.micLevel == 0.65 }
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 850), to: directory.appendingPathComponent("studio-capture.png"))
        model.toggleCapturePause()
        settle { model.isCapturePaused }
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 850), to: directory.appendingPathComponent("studio-capture-paused.png"))
        model.toggleCapturePause()
        settle { !model.isCapturePaused }
        render(NotepadWindow().environmentObject(model), size: .init(width: 500, height: 650), to: directory.appendingPathComponent("studio-notepad.png"))
        // A pasted screenshot, drawn here: the examples keep it in memory.
        if let slide = syntheticSlide() {
            model.addNoteImage(slide)
            settle { model.activeCapture?.noteEntries.contains { $0.image != nil } == true }
            render(NotepadWindow().environmentObject(model), size: .init(width: 500, height: 900), to: directory.appendingPathComponent("studio-notepad-image.png"))
        }
        // AirPods connect and become the system default input: the capture only offers them.
        let airpods = MicrophoneDevice(uid: "preview.airpods", name: "AirPods de Camille", transport: .bluetooth) // l10n:ignore
        Task { await capture.offer(airpods) }
        settle { model.microphoneOffer != nil }
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 980), to: directory.appendingPathComponent("studio-capture-microphone-offer.png"))
        render(NotepadWindow().environmentObject(model), size: .init(width: 500, height: 650), to: directory.appendingPathComponent("studio-notepad-microphone-offer.png"))
        model.declineMicrophoneOffer()
        render(SpeakerEditor().environmentObject(model), size: .init(width: 600, height: 360), to: directory.appendingPathComponent("studio-speaker.png"))
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
        renderVoicePeople(preferences: preferences, to: directory.appendingPathComponent("studio-settings-voice-people.png"))
        model.settingsCategory = .summary
        render(RootView().environmentObject(model), size: .init(width: 860, height: 660), to: directory.appendingPathComponent("studio-settings-compact.png"))
        // Preview models never read the keychain or persist this choice.
        model.summarySettings.select(.anthropic)
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-settings-summary-remote.png"))
        model.summarySettings.select(.agent)
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("studio-settings-summary-agent.png"))
    }
    /// Synthetic voices covering the three states. Audio chunks are references only; nothing is read or played.
    private static func renderVoiceTiles(preferences: InMemorySettings, to url: URL) {
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
        let model = AppModel(environment: .preview(examples: DemoContent.recordings() + [example], preferences: preferences))
        model.people = [lea]; model.selectedID = example.id; model.playback.voiceID = room.id
        render(VoiceTilesView(recording: example).environmentObject(model).padding(16), size: .init(width: 1040, height: 110), to: url)
    }
    /// Remembered people with their samples per session. Synthetic: the keychain is never read.
    private static func renderVoicePeople(preferences: InMemorySettings, to url: URL) {
        var brice = VoicePerson(name: "Brice"); brice.enrollmentRequestedAt = Date(); brice.enrolledChannels = [.mic, .remote]
        var lea = VoicePerson(name: "Léa"); lea.enrollmentRequestedAt = Date(); lea.enrolledChannels = [.mic] // l10n:ignore
        var opposed = VoicePerson(name: "Jordan"); opposed.opposed = true
        let session = Recording(title: "Point produit", isDemo: true)
        let model = AppModel(environment: .preview(examples: DemoContent.recordings() + [session], preferences: preferences))
        model.people = [brice, lea, opposed]
        model.voiceContributions[brice.id] = [
            .init(recordingID: session.id, channel: .mic, count: 1, addedAt: Date()),
            .init(recordingID: session.id, channel: .remote, count: 1, addedAt: Date()),
            .init(recordingID: nil, channel: .mic, count: 3, addedAt: nil)]
        render(VStack(spacing: 0) { VoicePersonRow(person: brice, expanded: true); VoicePersonRow(person: lea); VoicePersonRow(person: opposed) }
            .environmentObject(model).padding(24), size: .init(width: 720, height: 300), to: url)
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

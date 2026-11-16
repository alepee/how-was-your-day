import AVFoundation
import AppKit
import SwiftUI
import HWYDCore

/// `--snapshot <dir> --site`: the screens of the public website. The sessions are shown as the
/// user's own, in English, so the pages read as the app in use rather than its examples. They are
/// still synthetic: the voices are system speech synthesis written to a temporary folder, the
/// capture is simulated, nothing real is read and the microphone is never opened.
@MainActor enum SiteShots {
    static func run(into directory: URL) {
        let audioRoot = FileManager.default.temporaryDirectory.appendingPathComponent("hwyd-site-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: audioRoot) }
        let meeting: Recording
        do { meeting = try Meeting.make(audioRoot: audioRoot) } catch { print("Site screenshots: \(error)"); return }
        for preference in [AppearancePreference.light, .dark] {
            let destination = directory.appendingPathComponent(preference.rawValue)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let preferences = InMemorySettings()
            preferences.set(preference.rawValue, for: .appearance)
            renderTheme(meeting: meeting, audio: DataDirectoryAudio(directory: audioRoot), preferences: preferences, into: destination)
        }
        print("Site screenshots: \(directory.path)")
    }

    private static func renderTheme(meeting: Recording, audio: DataDirectoryAudio, preferences: InMemorySettings, into directory: URL) {
        func model(_ recordings: [Recording], capture: CaptureSource = .unavailable("Site screenshots never record.")) -> AppModel {
            var environment = AppEnvironment.preview(recordings: recordings, preferences: preferences, capture: capture)
            environment.user.audio = audio
            return AppModel(environment: environment)
        }
        func file(_ name: String) -> URL { directory.appendingPathComponent(name + ".png") }
        let library = model(Library.sessions(meeting: meeting))
        render(RootView().environmentObject(library), size: .init(width: 1080, height: 700), to: file("library"))

        let session = model(Library.sessions(meeting: meeting))
        session.selectedID = meeting.id; session.activeTab = .summary
        render(RootView().environmentObject(session), size: .init(width: 1080, height: 790), to: file("session"), waitingFor: { !session.trackEnvelopes.isEmpty })
        render(RootView().environmentObject(session), size: .init(width: 1440, height: 1240), to: file("summary-wide"), waitingFor: { !session.trackEnvelopes.isEmpty })
        session.activeTab = .transcript
        session.playbackTime = meeting.segments[1].start + 1; session.updatePlaybackFocus()
        render(RootView().environmentObject(session), size: .init(width: 1080, height: 790), to: file("transcript"), waitingFor: { !session.trackEnvelopes.isEmpty })
        session.playbackTime = 0; session.playback.activeSegmentIDs = []

        renderVoiceTiles(meeting: meeting, model: model([meeting]), to: file("voices"))

        // The export sheet of an agent summary that brought a context note.
        if var agent = meeting.summaryProvenance {
            agent.structured.context = [SummaryContextNote(title: "Beta roadmap", text: "The two-wave rollout follows the plan agreed in the October planning notes.", sources: ["notes/beta-roadmap.md"])]
            var copy = meeting; copy.summaryProvenance = agent; copy.summary = agent.structured.markdown
            render(SummaryExportSheet(recording: copy, format: .pdf) { _ in }, size: .init(width: 440, height: 420), to: file("export-sheet"))
        }

        let start = model(Library.sessions(meeting: meeting))
        start.requestNewSession(); start.newSessionKind = .meeting; start.newSessionTitle = "Design review"
        start.newSessionConsentAt = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600 + 59 * 60)
        render(RootView().environmentObject(start), size: .init(width: 1080, height: 790), to: file("new-session"))

        renderCapture(meeting: meeting, others: Library.sessions(meeting: meeting).filter { $0.id != meeting.id }, preferences: preferences, into: directory)
    }

    /// The meeting being recorded, two minutes in, then the AirPods connecting.
    private static func renderCapture(meeting: Recording, others: [Recording], preferences: InMemorySettings, into directory: URL) {
        let clock = ManualClock(), capture = SimulatedCapture(animatesLevels: false)
        let model = AppModel(environment: .preview(recordings: others, preferences: preferences, capture: .simulated { capture }, clock: { clock.time }))
        model.startCapture(kind: .meeting, title: meeting.title)
        settle { model.activeCaptureID != nil }
        guard let id = model.activeCaptureID else { print("Site screenshots: the simulated capture did not start."); return }
        model.update(id) { $0.notes = meeting.notes; $0.noteEntries = meeting.noteEntries; $0.consentAnnounced = true }
        clock.time = 128; capture.emit(.levels(mic: 0.62, system: 0.4))
        settle { model.elapsed == 128 && model.micLevel == 0.62 }
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 850), to: directory.appendingPathComponent("capture.png"))
        let airpods = MicrophoneDevice(uid: "site.airpods", name: "AirPods Pro", transport: .bluetooth)
        Task { await capture.offer(airpods) }
        settle { model.microphoneOffer != nil }
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 980), to: directory.appendingPathComponent("capture-microphone.png"))
        model.declineMicrophoneOffer()

        model.calendar.enabled = true
        model.calendar.upcoming = [.init(id: "site-review", title: "Design review", start: Date().addingTimeInterval(120), end: Date().addingTimeInterval(1920), calendarTitle: "Work", meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")),
                                   .init(id: "site-workshop", title: "Pricing workshop, room 4", start: Date().addingTimeInterval(5400), end: Date().addingTimeInterval(9000), calendarTitle: "Work")]
        render(UpcomingMeetingsView(calendar: model.calendar).environmentObject(model), size: .init(width: 780, height: 210), to: directory.appendingPathComponent("calendar-upcoming.png"))
        model.calendar.enabled = false; model.calendar.upcoming = []
        model.showSettings = true; model.settingsCategory = .summary
        model.summarySettings.select(.agent)
        render(RootView().environmentObject(model), size: .init(width: 1080, height: 790), to: directory.appendingPathComponent("settings-summary-agent.png"))
    }

    /// The meeting's voices in the three states, plus the echo of the speakers, ignored.
    private static func renderVoiceTiles(meeting: Recording, model: AppModel, to url: URL) {
        var example = meeting
        if let sam = example.speakers.firstIndex(where: { $0.label == Meeting.sam }) {
            example.speakers[sam].confirmed = false
            example.speakers[sam].proposedIdentity = VoiceMatch(personID: UUID(), score: 0.82, margin: 0.15, channel: .remote)
        }
        var echo = Speaker(label: "Voice 4"); echo.ignored = true
        example.speakers.append(echo)
        example.segments.append(.init(start: meeting.duration - 4, end: meeting.duration - 1, speakerID: echo.id, source: .mic, text: "…"))
        model.selectedID = nil
        render(VoiceTilesView(recording: example).environmentObject(model).padding(16), size: .init(width: 1040, height: 110), to: url)
    }

    @MainActor private final class ManualClock { var time: TimeInterval = 0 }
    private static func settle(seconds: Double = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    private static func render<V: View>(_ view: V, size: CGSize, to url: URL, waitingFor ready: () -> Bool = { true }) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Studio.background))
        host.appearance = NSApp.appearance; host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSApp.appearance; window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000)); window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35)); settle(ready)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded(); host.display()
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            bitmap.size = size; host.cacheDisplay(in: host.bounds, to: bitmap)
            do { try bitmap.representation(using: .png, properties: [:])?.write(to: url) } catch { print(error) }
        }
        window.orderOut(nil)
    }
}

/// The other sessions of the day, around the meeting.
@MainActor private enum Library {
    static func sessions(meeting: Recording) -> [Recording] {
        let today = Calendar.current.startOfDay(for: Date())
        let you = Speaker(label: Meeting.you, confirmed: true)
        var memo = Recording(title: "An idea on the walk in", kind: .voiceMemo, startedAt: today.addingTimeInterval(8 * 3600 + 42 * 60), duration: 248,
                             notes: "What if the best summary is the sentence you wrote down yourself?", speakers: [you],
                             segments: [.init(start: 2, end: 12, speakerID: you.id, source: .mic, text: "An interface that disappears while you talk. One button to start, one page for what matters.")])
        memo.speechLanguage = "en-US"
        let coffee = Recording(title: "Coffee with Léa", kind: .conversation, startedAt: today.addingTimeInterval(8 * 3600 + 15 * 60), duration: 1102, notes: "Pick up the Thursday workshop.") // l10n:ignore
        let oneOnOne = Recording(title: "1:1 with Sam", kind: .call, startedAt: today.addingTimeInterval(14 * 3600), duration: 1510)
        let prototype = Recording(title: "Prototype feedback", kind: .call, startedAt: today.addingTimeInterval(-7.5 * 3600), duration: 1462)
        return [oneOnOne, meeting, memo, coffee, prototype]
    }
}

/// A short beta check-in between you, on the microphone, and two colleagues on a call. Each line
/// is spoken by a system voice; the transcript times are those of the synthesized audio.
@MainActor private enum Meeting {
    static let you = "You", camille = "Camille", sam = "Sam"
    static let lines: [(String, String)] = [
        (you, "Thanks for joining. I'd like to leave this call with a date for the beta, and a clear list of who does what."),
        (camille, "Sounds good. On the design side, onboarding is done. The only open question is whether we ask for calendar access on the first screen."),
        (sam, "I'd rather not. Every permission we ask for up front costs us people. Let them record first, and ask for the calendar later."),
        (you, "Agreed. Calendar access becomes optional and moves to settings. Let's call that decided."),
        (camille, "Fine by me. I'll update the onboarding mockups by Thursday."),
        (sam, "On the engineering side, the build is stable. We fixed the crash on resume last week, and the tests have been green for five days."),
        (you, "What about performance on older machines?"),
        (sam, "Transcription runs about four times faster than real time on an M1. That's enough for the beta, but I want one more test with long sessions, two hours or more."),
        (you, "Can you run that before Friday?"),
        (sam, "Yes. I'll run it on Wednesday and share the numbers."),
        (camille, "One more thing: support. If fifty people sign up on day one, who answers them?"),
        (you, "Good point. I'll take support for the first two weeks. After that, we'll see what the volume looks like."),
        (camille, "And the landing page? It still talks about features we dropped."),
        (you, "Right. I'll rewrite it around one day of use, with real screens, instead of a feature list."),
        (sam, "Do we invite everyone on the waiting list at once?"),
        (camille, "I'd say two waves. A hundred people first, then the rest a week later if nothing breaks."),
        (you, "Let's do that. First wave on the twenty-fourth, second wave on December first."),
        (sam, "Works for me. I'll set up the invite codes so we can revoke a wave if we need to."),
        (you, "Great. So: calendar access is optional, two waves starting on the twenty-fourth, and I own support and the landing page."),
        (camille, "And I own the onboarding mockups."),
        (sam, "And I own the long-session test and the invite codes."),
        (you, "Perfect. Thanks, both of you."),
    ]
    static let voices = [you: "com.apple.voice.compact.en-GB.Daniel", camille: "com.apple.voice.compact.en-US.Samantha", sam: "com.apple.voice.super-compact.en-AU.Karen"]
    static let rate = 22_050.0

    static func make(audioRoot: URL) throws -> Recording {
        let speakers = [you: Speaker(label: you, confirmed: true), camille: Speaker(label: camille, confirmed: true, source: .system), sam: Speaker(label: sam, confirmed: true, source: .system)]
        var mic = [Float](), system = [Float](), segments = [TranscriptSegment]()
        var cursor = 1.6
        for (index, (name, text)) in lines.enumerated() {
            let samples = try Synthesis.speak(text, voice: voices[name]!, rate: rate)
            let length = Double(samples.count) / rate
            let source: AudioSource = name == you ? .mic : .system
            let gain: Float = source == .mic ? 0.55 : 0.4
            let offset = Int(cursor * rate)
            for track in [source] {
                func place(_ buffer: inout [Float]) {
                    if buffer.count < offset + samples.count { buffer += [Float](repeating: 0, count: offset + samples.count - buffer.count) }
                    for (i, sample) in samples.enumerated() { buffer[offset + i] += sample * gain }
                }
                if track == .mic { place(&mic) } else { place(&system) }
            }
            segments.append(.init(start: cursor, end: cursor + length, speakerID: speakers[name]!.id, source: source, text: text))
            cursor += length + [0.45, 0.8, 0.6, 1.1][index % 4]
        }
        let duration = cursor + 1.5, frames = Int(duration * rate)
        for index in [0, 1] { if index == 0 { mic += [Float](repeating: 0, count: max(0, frames - mic.count)) } else { system += [Float](repeating: 0, count: max(0, frames - system.count)) } }

        let today = Calendar.current.startOfDay(for: Date())
        var item = Recording(title: "Beta launch check-in", kind: .meeting, startedAt: today.addingTimeInterval(10 * 3600), duration: duration,
                             notes: "Keep the first run to one button.\n\nAsk Sam for the M1 numbers for the release notes.",
                             noteEntries: [.init(offset: segments[3].start, text: "Calendar optional, in settings."),
                                           .init(offset: segments[16].start, text: "Two waves: Nov 24, Dec 1.")],
                             speakers: [speakers[you]!, speakers[camille]!, speakers[sam]!], segments: segments)
        item.speechLanguage = "en-US"; item.consentAnnounced = true
        let folder = try DataDirectoryAudio(directory: audioRoot).sessionFolder(for: item.id)
        for (source, samples) in [(AudioSource.mic, mic), (.system, system)] {
            let name = source == .mic ? "mic-0001.caf" : "system-0001.caf"
            try Synthesis.write(samples, rate: rate, to: folder.url.appendingPathComponent(name))
            item.audioChunks.append(.init(source: source, relativePath: folder.relativePath + "/" + name, start: 0, duration: duration))
        }
        // The summary types have no public initializer: the summary is decoded as a provider's would be.
        let ids = segments.map { $0.id.uuidString }
        func refs(_ indexes: Int...) -> [String] { indexes.map { ids[$0] } }
        func action(_ text: String, _ owner: String, _ due: String?, _ evidence: [String]) -> [String: Any] {
            var value: [String: Any] = ["text": text, "assignee_name": owner, "evidence_segment_ids": evidence]
            if let due { value["due_date"] = due }
            return value
        }
        let summary: [String: Any] = [
            "overview": "The team confirms the beta: calendar access becomes optional, invitations go out in two waves from November 24, and every open task has an owner.",
            "decisions": [["text": "Calendar access is optional and moves from onboarding to settings.", "evidence_segment_ids": refs(2, 3)],
                          ["text": "Invitations go out in two waves: about a hundred people on November 24, the rest on December 1.", "evidence_segment_ids": refs(15, 16)]],
            "action_items": [action("Update the onboarding mockups.", camille, "Thursday", refs(4)),
                             action("Run the long-session test (two hours or more) and share the numbers.", sam, "Wednesday", refs(7, 9)),
                             action("Set up invite codes that can be revoked per wave.", sam, nil, refs(17)),
                             action("Handle beta support for the first two weeks.", you, nil, refs(11)),
                             action("Rewrite the landing page around one day of use.", you, nil, refs(13))],
            "key_points": [["title": "Fewer permissions up front", "text": "People record first; the calendar can wait.", "evidence_segment_ids": refs(2, 3)],
                           ["title": "Build ready for beta", "text": "Crash on resume fixed, tests green for five days.", "evidence_segment_ids": refs(5)]],
            "details": [
                ["title": "Onboarding and permissions", "text": "Onboarding design is done. Sam argues that every permission asked up front loses people, so calendar access leaves the first screen and becomes an optional setting. Camille updates the mockups by Thursday.", "evidence_segment_ids": refs(1, 2, 3, 4)],
                ["title": "Build quality and performance", "text": "The build is stable after last week's fix to the crash on resume. Transcription runs about four times faster than real time on an M1, which is enough for the beta. Sam still wants a test on sessions of two hours or more, scheduled for Wednesday.", "evidence_segment_ids": refs(5, 7, 9)],
                ["title": "Support and landing page", "text": "Support for the first two weeks is covered, then reviewed against the actual volume. The landing page still describes dropped features and will be rewritten around one day of use.", "evidence_segment_ids": refs(10, 11, 12, 13)],
                ["title": "Rollout in two waves", "text": "Rather than inviting the whole waiting list, a first wave of about a hundred people opens on November 24 and the rest follows on December 1 if nothing breaks. Invite codes can revoke a wave.", "evidence_segment_ids": refs(14, 15, 16, 17)]],
        ]
        let provenance: [String: Any] = ["provider": "agent", "model": "Claude Code", "promptVersion": "agent-summary-v1+english", "promptHash": "site", "language": "en", "generatedAt": Date().timeIntervalSinceReferenceDate,
                                         "transcriptVersion": 1, "inputHash": "site", "structured": summary]
        let decoded = try JSONDecoder().decode(SummaryProvenance.self, from: JSONSerialization.data(withJSONObject: provenance))
        item.summary = decoded.structured.markdown
        item.summaryProvenance = decoded
        return item
    }
}

/// System speech synthesis to mono float samples, and CAF files from them.
private enum Synthesis {
    private final class Collector: @unchecked Sendable {
        let lock = NSLock(); var samples: [Float] = []; var done = false; var error: Error?
    }
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor static func speak(_ text: String, voice identifier: String, rate: Double) throws -> [Float] {
        guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else { throw Failure(description: "Missing system voice \(identifier)") }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { throw Failure(description: "Format") }
        let synthesizer = AVSpeechSynthesizer(), utterance = AVSpeechUtterance(string: text), collector = Collector()
        utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.98
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { collector.lock.withLock { collector.done = true }; return }
            do {
                guard let converter = AVAudioConverter(from: pcm.format, to: target),
                      let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * rate / pcm.format.sampleRate) + 1024) else { throw Failure(description: "Converter") }
                var fed = false, conversionError: NSError?
                converter.convert(to: output, error: &conversionError) { _, status in
                    if fed { status.pointee = .endOfStream; return nil }
                    fed = true; status.pointee = .haveData; return pcm
                }
                if let conversionError { throw conversionError }
                let channel = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
                collector.lock.withLock { collector.samples += channel }
            } catch { collector.lock.withLock { collector.error = error; collector.done = true } }
        }
        let deadline = Date().addingTimeInterval(60)
        while !collector.lock.withLock({ collector.done }), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return try collector.lock.withLock {
            if let error = collector.error { throw error }
            guard collector.done, !collector.samples.isEmpty else { throw Failure(description: "No speech for: \(text)") }
            return collector.samples
        }
    }

    static func write(_ samples: [Float], rate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { throw Failure(description: "Buffer") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

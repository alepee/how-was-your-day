import XCTest
import AVFoundation
@testable import HWYDCore

@MainActor
final class SessionResumeTests: XCTestCase {
    private var time: TimeInterval = 100
    private var wall = Date(timeIntervalSince1970: 1_800_000_000)
    private var transcriptions: [UUID] = []
    private let notifier = RecordingNotifier()

    private func session() -> CaptureSession {
        CaptureSession(notifier: notifier, transcribe: { [unowned self] id in transcriptions.append(id); return .accepted },
                       now: { [unowned self] in time }, date: { [unowned self] in wall })
    }
    private func chunks(_ sequence: Int, start: Double, duration: Double) -> [AudioChunk] {
        [AudioSource.mic, .system].map { AudioChunk(source: $0, relativePath: String(format: "audio/x/%@-%06d.caf", $0.rawValue, sequence), start: start, duration: duration) }
    }
    /// A session stopped an hour ago: 5.2 s recorded, one chunk pair, a note.
    private func ended(endedAgo: TimeInterval = 3600) -> Recording {
        var item = Recording(title: "Point", startedAt: wall.addingTimeInterval(-endedAgo - 10), duration: 5.2, state: .sealed)
        item.audioChunks = chunks(0, start: 0, duration: 5); item.endedAt = wall.addingTimeInterval(-endedAgo)
        item.noteEntries = [NoteEntry(offset: 2, text: "avant")]
        return item
    }

    // MARK: Eligibility

    func testEligibility() {
        let item = ended()
        XCTAssertNil(SessionResume.refusal(for: item, now: wall, captureIdle: true))
        var interrupted = item; interrupted.state = .interrupted
        XCTAssertNil(SessionResume.refusal(for: interrupted, now: wall, captureIdle: true))
        var demo = item; demo.isDemo = true
        XCTAssertEqual(SessionResume.refusal(for: demo, now: wall, captureIdle: true), .example)
        var recording = item; recording.state = .recording
        XCTAssertEqual(SessionResume.refusal(for: recording, now: wall, captureIdle: true), .recording)
        XCTAssertEqual(SessionResume.refusal(for: item, now: wall, captureIdle: false), .captureRunning)
        XCTAssertEqual(SessionResume.refusal(for: ended(endedAgo: 25 * 3600), now: wall, captureIdle: true), .tooLate)
        XCTAssertTrue(ResumeRefusal.tooLate.hidesAction); XCTAssertFalse(ResumeRefusal.captureRunning.hidesAction)
        // Work on the session: a transcription is cancelled by the caller, other work refuses.
        XCTAssertNil(SessionResume.refusal(for: item, now: wall, captureIdle: true, jobs: [.transcription(session: item.id)]))
        XCTAssertEqual(SessionResume.refusal(for: item, now: wall, captureIdle: true, jobs: [.summary(session: item.id)]), .busy(.summary(session: item.id)))
        XCTAssertEqual(SessionResume.refusal(for: item, now: wall, captureIdle: true, jobs: [.voice(session: item.id)]), .busy(.voice(session: item.id)))
        XCTAssertNil(SessionResume.refusal(for: item, now: wall, captureIdle: true, jobs: [.summary(session: UUID()), .voice(session: nil)]))
    }

    func testWithoutEndDateTheWindowCountsFromStartPlusDuration() {
        // Recorded before `endedAt` existed: 2 h recorded from 23 h ago, so ended 21 h ago.
        let old = Recording(title: "Ancienne", startedAt: wall.addingTimeInterval(-23 * 3600), duration: 2 * 3600)
        XCTAssertEqual(old.endDate, wall.addingTimeInterval(-21 * 3600))
        XCTAssertNil(SessionResume.refusal(for: old, now: wall, captureIdle: true))
        XCTAssertEqual(SessionResume.refusal(for: old, now: wall.addingTimeInterval(4 * 3600), captureIdle: true), .tooLate)
    }

    // MARK: Continuation

    func testContinuationFollowsTheLaterOfDurationAndAudio() {
        var item = ended()
        XCTAssertEqual(CaptureContinuation(after: item), CaptureContinuation(offset: 5.2, firstSequence: 1))
        item.audioChunks += chunks(3, start: 5, duration: 0.5)
        XCTAssertEqual(CaptureContinuation(after: item), CaptureContinuation(offset: 5.5, firstSequence: 4))
        XCTAssertEqual(CaptureContinuation(after: item).offsetFrames, 88_000)
        XCTAssertEqual(CaptureContinuation(after: Recording(title: "Vide")), .start)
        XCTAssertEqual(CaptureContinuation.sequence(ofFile: "audio/x/system-000012.partial.caf"), 12)
        XCTAssertEqual(CaptureContinuation.sequence(ofFile: "000007.json"), 7)
        XCTAssertNil(CaptureContinuation.sequence(ofFile: "manifest.json"))
        XCTAssertNil(CaptureContinuation.sequence(ofFile: "preview-mic.caf"))
    }

    func testFirstFreeSequenceCountsEveryFileInTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HWYD-sequence-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(CaptureContinuation.firstFreeSequence(in: folder), 0)
        for name in ["mic-000000.caf", "000002.json", "system-000001.partial.caf", "manifest.json"] { try Data().write(to: folder.appendingPathComponent(name)) }
        XCTAssertEqual(CaptureContinuation.firstFreeSequence(in: folder), 3)
    }

    // MARK: Capture

    func testResumingAppendsAfterTheEarlierAudio() async throws {
        let item = ended(), library = SessionLibrary(volatile: [item]), capture = session()
        let device = SimulatedCapture(animatesLevels: false, simulated: false, audio: CapturedAudio(chunks: chunks(1, start: 0, duration: 3)), microphone: "Micro du Mac")
        let resumed = try await capture.continueRecording(item.id, with: device, in: library)
        XCTAssertTrue(resumed)
        let from = await device.startedFrom
        XCTAssertEqual(from, CaptureContinuation(offset: 5.2, firstSequence: 1))
        XCTAssertEqual(capture.phase, .recording(item.id))
        let recording = try XCTUnwrap(library.recording(item.id))
        XCTAssertEqual(recording.state, .recording)
        XCTAssertEqual(recording.boundaries, [CaptureBoundary(offset: 5.2, at: wall, reason: .resumed, microphone: "Micro du Mac")])
        XCTAssertEqual(recording.audioChunks, item.audioChunks, "earlier audio untouched while recording")
        XCTAssertEqual(capture.elapsed, 5.2, accuracy: 1e-9, "the clock starts at the recorded time")
        time += 3
        XCTAssertEqual(capture.elapsed, 8.2, accuracy: 1e-9)
        wall += 60
        await capture.stop()
        let stopped = try XCTUnwrap(library.recording(item.id))
        XCTAssertEqual(stopped.state, .sealed)
        XCTAssertEqual(stopped.audioChunks.prefix(2), item.audioChunks.prefix(2))
        XCTAssertEqual(stopped.audioChunks.dropFirst(2).map(\.start), [5.2, 5.2])
        XCTAssertEqual(stopped.audioChunks.dropFirst(2).map(\.relativePath), ["audio/x/mic-000001.caf", "audio/x/system-000001.caf"])
        XCTAssertEqual(stopped.duration, 8.2, accuracy: 1e-9)
        XCTAssertEqual(stopped.endedAt, wall)
        XCTAssertEqual(stopped.noteEntries, item.noteEntries)
        XCTAssertEqual(stopped.title, item.title); XCTAssertEqual(stopped.kind, item.kind)
        XCTAssertEqual(transcriptions, [item.id])
    }

    func testEveryStopRecordsWhenTheSessionEnded() async throws {
        let library = SessionLibrary(volatile: []), capture = session()
        let started = try await capture.start(CaptureRequest(), with: SimulatedCapture(animatesLevels: false, simulated: false), in: library)
        let id = try XCTUnwrap(started)
        XCTAssertNil(library.recording(id)?.endedAt)
        await capture.stop()
        XCTAssertEqual(library.recording(id)?.endedAt, wall)
    }

    func testAResumeWithoutNewAudioIsStillTranscribedAgain() async throws {
        let item = ended(), library = SessionLibrary(volatile: [item]), capture = session()
        try await capture.continueRecording(item.id, with: SimulatedCapture(animatesLevels: false, simulated: false), in: library)
        await capture.stop()
        XCTAssertEqual(library.recording(item.id)?.audioChunks, item.audioChunks)
        XCTAssertEqual(transcriptions, [item.id])
    }

    func testRefusedResumesLeaveTheSessionUnchanged() async throws {
        struct Denied: LocalizedError { var errorDescription: String? { "denied" } }
        let late = ended(endedAgo: 25 * 3600), item = ended()
        let library = SessionLibrary(volatile: [late, item]), capture = session()
        func refusal(_ id: UUID, _ device: any AudioCapture) async -> Error? {
            do { try await capture.continueRecording(id, with: device, in: library); return nil } catch { return error }
        }
        let real = SimulatedCapture(animatesLevels: false, simulated: false)
        let tooLate = await refusal(late.id, real)
        let simulated = await refusal(item.id, SimulatedCapture(animatesLevels: false))
        let failed = await refusal(item.id, SimulatedCapture(simulated: false, startFailure: Denied()))
        XCTAssertEqual(tooLate as? ResumeRefusal, .tooLate)
        XCTAssertEqual(simulated as? ResumeRefusal, .example)
        XCTAssertEqual(failed?.localizedDescription, "denied")
        XCTAssertEqual(capture.phase, .idle)
        XCTAssertEqual(library.recording(item.id), item)
        XCTAssertEqual(library.recording(late.id), late)
        // Another capture runs: nothing starts.
        let other = try await capture.start(CaptureRequest(), with: SimulatedCapture(animatesLevels: false, simulated: false), in: library)
        let resumed = try await capture.continueRecording(item.id, with: real, in: library)
        XCTAssertFalse(resumed)
        XCTAssertEqual(capture.phase, .recording(try XCTUnwrap(other)))
        let started = await real.session
        XCTAssertNil(started)
    }

    // MARK: Store, merge and recovery

    func testFieldsDecodeAbsentAndMergeWithTheCapture() throws {
        let item = ended()
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        legacy["endedAt"] = nil
        let decoded = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.endedAt); XCTAssertNil(decoded.boundaries)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("boundaries"))

        var remote = item; remote.title = "Renommée"
        var local = item; local.endedAt = wall; local.boundaries = [CaptureBoundary(offset: 5.2, at: wall, reason: .resumed)]; local.state = .recording
        let (merged, conflicts) = Recording.merge(base: item, local: local, remote: remote)
        XCTAssertTrue(conflicts.isEmpty)
        XCTAssertEqual(merged.title, "Renommée"); XCTAssertEqual(merged.boundaries, local.boundaries)
        XCTAssertEqual(merged.endedAt, wall); XCTAssertEqual(merged.state, .recording)
    }

    func testRecoveryAfterACrashDuringAResumeKeepsBothParts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HWYD-resume-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(directory: root)
        var item = Recording(title: "Reprise", duration: 0.1, state: .recording)
        let folder = try store.audio.sessionFolder(for: item.id)
        func audio(_ name: String) throws {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let file = try AVAudioFile(forWriting: folder.url.appendingPathComponent(name), settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            try file.write(from: buffer)
        }
        // The first capture sealed sequence 0 (no descriptor: an older writer); the resumed one
        // crashed while writing sequence 1, at 0.1 s on the timeline.
        for source in ["mic", "system"] { try audio("\(source)-000000.caf"); try audio("\(source)-000001.partial.caf") }
        try JSONEncoder().encode(["start_frames": "1600"]).write(to: folder.url.appendingPathComponent("000001.json"))
        item.audioChunks = [AudioSource.mic, .system].map { AudioChunk(source: $0, relativePath: folder.chunkPath("\($0.rawValue)-000000.caf"), start: 0, duration: 0.1) }
        item.boundaries = [CaptureBoundary(offset: 0.1, at: wall, reason: .resumed)]
        try await store.save(item)
        let found = try await store.recoverInterrupted()
        XCTAssertEqual(found, 1)
        let recovered = try await store.recording(item.id)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertEqual(Array(recovered.audioChunks.prefix(2)), item.audioChunks, "earlier chunks and their ids are kept")
        XCTAssertEqual(recovered.audioChunks.dropFirst(2).map(\.relativePath), [folder.chunkPath("mic-000001.caf"), folder.chunkPath("system-000001.caf")])
        XCTAssertEqual(recovered.audioChunks.dropFirst(2).map(\.start), [0.1, 0.1])
        XCTAssertEqual(recovered.duration, 0.2, accuracy: 1e-9)
        XCTAssertEqual(recovered.boundaries, item.boundaries)
    }

    // MARK: Markers

    private func transcribed() -> Recording {
        let voice = Speaker(label: "Alice", confirmed: true)
        var item = Recording(title: "Point", startedAt: wall, duration: 20, speakers: [voice], segments: [
            .init(start: 1, end: 3, speakerID: voice.id, source: .mic, text: "Avant"),
            .init(start: 12, end: 14, speakerID: voice.id, source: .mic, text: "Après"),
            .init(start: 10, end: 11, speakerID: voice.id, source: .system, text: "Juste après")])
        item.endedAt = wall.addingTimeInterval(7200)
        item.boundaries = [CaptureBoundary(offset: 10, at: wall.addingTimeInterval(3600), reason: .resumed, microphone: "Micro du Mac")]
        return item
    }

    func testMarkerGoesBeforeTheFirstPassageAtOrAfterTheResume() {
        let item = transcribed()
        let sorted = item.segments.sorted { $0.start < $1.start }
        XCTAssertEqual(SessionResume.markers(item.boundaries, before: sorted), [item.segments[2].id: item.boundaries!])
        XCTAssertTrue(SessionResume.markers([CaptureBoundary(offset: 30, at: wall, reason: .resumed)], before: sorted).isEmpty, "nothing heard after the resume")
        XCTAssertTrue(SessionResume.markers(nil, before: sorted).isEmpty)
        // Only a resume is marked; the reserved microphone changes are not.
        for reason in [CaptureBoundaryReason.user, .accepted, .forced] {
            XCTAssertTrue(SessionResume.markers([CaptureBoundary(offset: 10, at: wall, reason: reason)], before: sorted).isEmpty)
        }
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(SessionResume.exportLabel(CaptureBoundary(offset: 0, at: Date(timeIntervalSince1970: 52_320), reason: .resumed), timeZone: utc), "Reprise à 14:32")
    }

    func testTranscriptExportsAndSummaryInputCarryTheMarker() throws {
        let item = transcribed(), resume = item.boundaries![0]
        let marker = RecordingText.resumeLine(resume)
        XCTAssertEqual(marker, "**[00:00:10] \(SessionResume.exportLabel(resume))**")
        let transcript = RecordingText.artifact(item, "transcript")
        let lines = transcript.components(separatedBy: "\n\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasSuffix("Avant")); XCTAssertEqual(lines[1], marker); XCTAssertTrue(lines[2].hasSuffix("Juste après"))
        var plain = item; plain.boundaries = nil
        XCTAssertFalse(RecordingText.artifact(plain, "transcript").contains("Reprise"))

        let document = try SessionExporter.document(item)
        XCTAssertEqual(document["ended_at"] as? String, item.endedAt!.ISO8601Format())
        let resumes = try XCTUnwrap(document["capture_boundaries"] as? [[String: Any]])
        XCTAssertEqual(resumes.count, 1)
        XCTAssertEqual(resumes[0]["offset_us"] as? Int64, 10_000_000)
        XCTAssertEqual(resumes[0]["at"] as? String, resume.at.ISO8601Format())
        XCTAssertEqual(resumes[0]["reason"] as? String, "resumed")
        XCTAssertEqual(resumes[0]["microphone"] as? String, "Micro du Mac")
        let legacy = try SessionExporter.document(plain)
        XCTAssertNil(legacy["capture_boundaries"], "a session never resumed exports as before")
        var undated = plain; undated.endedAt = nil
        XCTAssertEqual(try SessionExporter.document(undated)["ended_at"] as? String, wall.addingTimeInterval(20).ISO8601Format())

        // The echo canceller starts again where the capture changed.
        let locales = SpeechLocales(installed: ["fr-FR"], supported: ["fr-FR"])
        XCTAssertEqual(TranscriptionRequest(session: item, diarize: false, locales: locales).echoResets, [10])
        XCTAssertNil(TranscriptionRequest(session: plain, diarize: false, locales: locales).echoResets)
        let prompt = try AgentSummaryTask.prompt(item)
        XCTAssertTrue(prompt.contains("\"resumed\":\"\(SessionResume.exportLabel(resume))\""), prompt)
        XCTAssertFalse(try AgentSummaryTask.prompt(plain).contains("resumed"))
        XCTAssertNotEqual(try SummaryPipeline.inputHash(item), try SummaryPipeline.inputHash(plain))
    }
}

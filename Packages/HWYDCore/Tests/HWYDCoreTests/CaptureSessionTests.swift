import XCTest
@testable import HWYDCore

/// A capture whose resume fails, as a device that disappeared while paused.
private actor UnresumableCapture: AudioCapture {
    struct Failure: LocalizedError { var errorDescription: String? { "resume failed" } }
    nonisolated let isSimulated = false
    nonisolated let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self) }
    func start(session id: UUID) async throws {}
    func pause() async {}
    func resume() async throws { throw Failure() }
    func stop() async -> CapturedAudio { continuation.finish(); return CapturedAudio() }
}

@MainActor
final class CaptureSessionTests: XCTestCase {
    private var time: TimeInterval = 100
    private var transcriptions: [UUID] = []
    private var decision: WorkDecision = .accepted
    private let notifier = RecordingNotifier()
    private let chunk = AudioChunk(source: .mic, relativePath: "audio/x/mic-000000.caf", start: 0, duration: 5)

    private func session() -> CaptureSession {
        CaptureSession(notifier: notifier, transcribe: { [unowned self] id in transcriptions.append(id); return decision },
                       now: { [unowned self] in time })
    }
    private func realCapture(_ audio: CapturedAudio? = nil) -> SimulatedCapture {
        SimulatedCapture(animatesLevels: false, simulated: false, audio: audio ?? CapturedAudio(chunks: [chunk]))
    }
    /// Waits for the session to handle what the capture sent.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
    }

    func testDefaultTitles() {
        let date = Date()
        let time = date.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(CaptureRequest(kind: .call, title: "  Idée  ").sessionTitle(startingAt: date), "Idée")
        XCTAssertEqual(CaptureRequest(kind: .adHoc, title: " ").sessionTitle(startingAt: date), String(localized: "Session du \(time)", bundle: .hwyd))
        let call = CaptureRequest(kind: .call).sessionTitle(startingAt: date)
        XCTAssertTrue(call.hasPrefix(SessionKind.call.label) && call.hasSuffix(time), call)
        let meeting = CaptureRequest(kind: .voiceMemo, meeting: CalendarContext(id: "e", title: "Point produit", start: date, end: date, calendarTitle: "Travail"))
        XCTAssertEqual(meeting.sessionKind, SessionKind.meeting)
        XCTAssertEqual(meeting.sessionTitle(startingAt: date), "Point produit")
    }

    func testStartAddsTheSessionAndRefusesASecondCapture() async throws {
        let capture = session(), library = SessionLibrary(volatile: [])
        let id = try await capture.start(CaptureRequest(kind: .call, language: "fr-FR"), with: realCapture(), in: library)
        let item = try XCTUnwrap(library.recording(try XCTUnwrap(id)))
        XCTAssertEqual(capture.phase, .recording(item.id))
        XCTAssertEqual(item.state, .recording); XCTAssertEqual(item.kind, .call); XCTAssertEqual(item.speechLanguage, "fr-FR"); XCTAssertFalse(item.isDemo)
        let second = try await capture.start(CaptureRequest(), with: realCapture(), in: library)
        XCTAssertNil(second)
        XCTAssertEqual(library.recordings.count, 1)
    }

    func testAFailedStartAddsNothing() async {
        struct Denied: LocalizedError { var errorDescription: String? { "denied" } }
        let capture = session(), library = SessionLibrary(volatile: [])
        do {
            try await capture.start(CaptureRequest(), with: SimulatedCapture(startFailure: Denied()), in: library)
            XCTFail("start must throw")
        } catch { XCTAssertEqual(error.localizedDescription, "denied") }
        XCTAssertEqual(capture.phase, .idle)
        XCTAssertTrue(library.recordings.isEmpty)
    }

    func testClockStopsWhilePausedAndGivesTheDuration() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = realCapture()
        let idStarted = try await capture.start(CaptureRequest(), with: device, in: library)
        let id = try XCTUnwrap(idStarted)
        time += 5
        await capture.pause()
        let paused = await device.isPaused
        XCTAssertTrue(paused); XCTAssertTrue(capture.isPaused); XCTAssertEqual(capture.levels, .silent)
        time += 10
        XCTAssertEqual(capture.elapsed, 5, accuracy: 1e-9)
        await capture.resume()
        XCTAssertEqual(capture.phase, .recording(id))
        time += 2
        XCTAssertEqual(capture.elapsed, 7, accuracy: 1e-9)
        await capture.stop()
        XCTAssertEqual(try XCTUnwrap(library.recording(id)).duration, 7, accuracy: 1e-9)
    }

    func testRestartIsLeftOutOfTheClock() async throws {
        let capture = session(), library = SessionLibrary(volatile: [])
        let idStarted = try await capture.start(CaptureRequest(), with: realCapture(), in: library)
        let id = try XCTUnwrap(idStarted)
        time += 10
        // The restart began 0.3 s before the session heard of it and ended 0.2 s before it heard it ended.
        capture.handle(.restarting, session: id)
        time += 1.3
        XCTAssertEqual(capture.elapsed, 10, accuracy: 1e-9, "the clock stands still during a restart")
        capture.handle(.restarted(gap: 1.4), session: id)
        XCTAssertEqual(capture.elapsed, 10 - 1.4 + 1.3, accuracy: 1e-9)
        time += 1
        XCTAssertEqual(capture.elapsed, 10.9, accuracy: 1e-9)
    }

    func testPauseDuringARestartStillSkipsOnlyTheGap() async throws {
        let capture = session(), library = SessionLibrary(volatile: [])
        let idStarted = try await capture.start(CaptureRequest(), with: realCapture(), in: library)
        let id = try XCTUnwrap(idStarted)
        time += 10
        // The restart takes 1 s; the user pauses halfway through it.
        capture.handle(.restarting, session: id)
        time += 0.5
        await capture.pause()
        time += 0.5
        capture.handle(.restarted(gap: 1), session: id)
        XCTAssertEqual(capture.elapsed, 10, accuracy: 1e-9)
        time += 5
        XCTAssertEqual(capture.elapsed, 10, accuracy: 1e-9, "the clock stays paused")
    }

    func testLevelsShowOnlyWhileRecording() async throws {
        let capture = session(), device = realCapture()
        let idStarted = try await capture.start(CaptureRequest(), with: device, in: SessionLibrary(volatile: []))
        let id = try XCTUnwrap(idStarted)
        device.emit(.levels(mic: 0.5, system: 0.25))
        await waitUntil { capture.levels == CaptureLevels(mic: 0.5, system: 0.25) }
        await capture.pause()
        capture.handle(.levels(mic: 0.9, system: 0.9), session: id)
        XCTAssertEqual(capture.levels, .silent)
    }

    func testStopSealsTheSessionAndRequestsItsTranscription() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = realCapture()
        var endings: [CaptureEnding] = []
        capture.onEnd = { endings.append($0) }
        let idStarted = try await capture.start(CaptureRequest(), with: device, in: library)
        let id = try XCTUnwrap(idStarted)
        decision = .queued(behind: WorkBusy(job: .summary(session: UUID())))
        let ending = await capture.stop()
        XCTAssertEqual(ending?.cause, .requested); XCTAssertEqual(endings, [ending!])
        let item = try XCTUnwrap(library.recording(id))
        XCTAssertEqual(item.state, .sealed); XCTAssertEqual(item.audioChunks, [chunk])
        XCTAssertEqual(transcriptions, [id])
        XCTAssertEqual(notifier.messages, [String(localized: "Audio et notes conservés. La transcription démarrera après le traitement en cours.", bundle: .hwyd)])
        let stopped = await device.isStopped
        XCTAssertTrue(stopped); XCTAssertEqual(capture.phase, .idle)
        let again = await capture.stop()
        XCTAssertNil(again)
    }

    func testNoAudioMeansNoTranscription() async throws {
        let capture = session(), library = SessionLibrary(volatile: [])
        let idStarted = try await capture.start(CaptureRequest(), with: realCapture(CapturedAudio()), in: library)
        let id = try XCTUnwrap(idStarted)
        await capture.stop()
        XCTAssertEqual(library.recording(id)?.state, .sealed)
        XCTAssertTrue(transcriptions.isEmpty)
        XCTAssertEqual(notifier.messages, [String(localized: "Aucun audio reçu. Vos notes sont conservées.", bundle: .hwyd)])
    }

    func testASimulationIsAnExampleAndIsNeverTranscribed() async throws {
        let capture = session(), library = SessionLibrary(volatile: [])
        let request = CaptureRequest(language: "fr-FR")
        let idStarted = try await capture.start(request, with: SimulatedCapture(animatesLevels: false, audio: CapturedAudio(chunks: [chunk])), in: library)
        let id = try XCTUnwrap(idStarted)
        XCTAssertEqual(library.recording(id)?.isDemo, true)
        XCTAssertNil(library.recording(id)?.speechLanguage)
        await capture.stop()
        XCTAssertTrue(transcriptions.isEmpty)
        XCTAssertEqual(notifier.messages, [String(localized: "Simulation terminée. Les notes restent disponibles.", bundle: .hwyd)])
    }

    func testAFaultStopsTheSessionAndKeepsItsAudio() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = realCapture()
        var endings: [CaptureEnding] = []
        capture.onEnd = { endings.append($0) }
        let idStarted = try await capture.start(CaptureRequest(), with: device, in: library)
        let id = try XCTUnwrap(idStarted)
        time += 3
        let fault = CaptureFault(.routeChanged, message: "route")
        device.emit(.failed(fault))
        await waitUntil { capture.phase == .idle && !transcriptions.isEmpty }
        XCTAssertEqual(endings.map(\.cause), [.failed(fault)])
        let item = try XCTUnwrap(library.recording(id))
        XCTAssertEqual(item.state, .interrupted); XCTAssertEqual(item.audioChunks, [chunk]); XCTAssertEqual(item.duration, 3, accuracy: 1e-9)
        XCTAssertEqual(transcriptions, [id], "the audio recorded before the fault is transcribed")
        XCTAssertEqual(notifier.messages.first, "route")
    }

    func testFinalizationErrorInterruptsTheSession() async throws {
        let capture = session(), library = SessionLibrary(volatile: [])
        let idStarted = try await capture.start(CaptureRequest(), with: realCapture(CapturedAudio(chunks: [chunk], finalizationError: "disk full")), in: library)
        let id = try XCTUnwrap(idStarted)
        let ending = await capture.stop()
        XCTAssertEqual(ending?.finalizationError, "disk full")
        XCTAssertEqual(library.recording(id)?.state, .interrupted)
        XCTAssertEqual(notifier.notices.first?.style, .error); XCTAssertEqual(notifier.messages.first, "disk full")
    }

    func testSleepEndsTheSession() async throws {
        let capture = session(), library = SessionLibrary(volatile: [])
        let idStarted = try await capture.start(CaptureRequest(), with: realCapture(), in: library)
        let id = try XCTUnwrap(idStarted)
        await capture.pause()
        let ending = await capture.systemWillSleep()
        XCTAssertEqual(ending?.cause, .systemSleep)
        XCTAssertEqual(library.recording(id)?.state, .sealed)
        XCTAssertEqual(capture.phase, .idle)
        let idle = await capture.systemWillSleep()
        XCTAssertNil(idle)
    }

    func testAFailedResumeStaysPaused() async throws {
        let capture = session()
        let idStarted = try await capture.start(CaptureRequest(), with: UnresumableCapture(), in: SessionLibrary(volatile: []))
        let id = try XCTUnwrap(idStarted)
        await capture.pause()
        await capture.resume()
        XCTAssertEqual(capture.phase, .paused(id))
        XCTAssertEqual(notifier.messages, ["resume failed"])
    }

    func testDiscardForgetsTheCaptureWithoutEndingTheSession() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = SimulatedCapture(animatesLevels: false)
        let idStarted = try await capture.start(CaptureRequest(), with: device, in: library)
        let id = try XCTUnwrap(idStarted)
        await capture.discard()
        let stopped = await device.isStopped
        XCTAssertTrue(stopped); XCTAssertEqual(capture.phase, .idle)
        XCTAssertEqual(library.recording(id)?.state, .recording)
        XCTAssertTrue(notifier.notices.isEmpty)
    }
}

import XCTest
@testable import HWYDCore

final class InactivityWatchTests: XCTestCase {
    private let policy = InactivityPolicy(silence: 10, countdown: 5)

    func testWithoutSpeechTheWatchAsksThenStopsAfterTheCountdown() {
        var watch = InactivityWatch(policy: policy, at: 0)
        XCTAssertEqual(watch.check(at: 9.9), .none)
        XCTAssertEqual(watch.check(at: 10), .ask(silence: 10))
        XCTAssertTrue(watch.isAsking)
        XCTAssertEqual(watch.check(at: 14.9), .none)
        XCTAssertEqual(watch.check(at: 15), .stop(silence: 15))
    }

    func testSpeechCountsAgain() {
        var watch = InactivityWatch(policy: policy, at: 0)
        _ = watch.check(at: 12)
        watch.reset(at: 12)
        XCTAssertFalse(watch.isAsking)
        XCTAssertEqual(watch.check(at: 21.9), .none)
        XCTAssertEqual(watch.check(at: 22), .ask(silence: 10))
    }
}

@MainActor
final class CaptureInactivityTests: XCTestCase {
    private var time: TimeInterval = 100
    private let notifier = RecordingNotifier()
    private let settings = InMemorySettings()
    private let chunk = AudioChunk(source: .mic, relativePath: "audio/x/mic-000000.caf", start: 0, duration: 5)

    private func session() -> CaptureSession {
        let session = CaptureSession(notifier: notifier, transcribe: { _ in .accepted }, now: { [unowned self] in time }, settings: { [unowned self] in settings })
        session.inactivityPolicy = InactivityPolicy(silence: 10, countdown: 5)
        return session
    }
    private func start(_ capture: CaptureSession, simulated: Bool = false, detectsSpeech: Bool = true) async throws -> UUID {
        let device = SimulatedCapture(animatesLevels: false, simulated: simulated, detectsSpeech: detectsSpeech, audio: CapturedAudio(chunks: [chunk]))
        let id = try await capture.start(CaptureRequest(), with: device, in: SessionLibrary(volatile: []))
        return try XCTUnwrap(id)
    }
    /// Five meter readings per second for `seconds`, as the capture sends them.
    private func run(_ capture: CaptureSession, for seconds: TimeInterval, session id: UUID) {
        for _ in 0..<Int((seconds * 5).rounded()) { time += 0.2; capture.handle(.levels(mic: 0.3, system: 0), session: id) }
    }
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
    }

    func testACaptureWithoutSpeechAsksThenStops() async throws {
        let capture = session()
        var endings: [CaptureEnding] = []
        capture.onEnd = { endings.append($0) }
        let id = try await start(capture)
        // Loud meters are not speech.
        run(capture, for: 9.8, session: id)
        XCTAssertNil(capture.inactivity)
        run(capture, for: 0.2, session: id)
        let prompt = try XCTUnwrap(capture.inactivity)
        XCTAssertEqual(prompt.silence, 10, accuracy: 0.01)
        XCTAssertEqual(prompt.stopsAt.timeIntervalSinceNow, 5, accuracy: 1)
        run(capture, for: 5, session: id)
        await waitUntil { capture.phase == .idle }
        guard case .inactivity(let silence) = endings.first?.cause else { return XCTFail("\(endings)") }
        XCTAssertEqual(silence, 15, accuracy: 0.01)
        XCTAssertNil(capture.inactivity)
        XCTAssertTrue(notifier.messages.contains("Enregistrement arrêté : personne n’a parlé pendant 0 min."), "\(notifier.messages)")
    }

    func testSpeechWithdrawsTheQuestionAndCountsAgain() async throws {
        let capture = session()
        let id = try await start(capture)
        run(capture, for: 10, session: id)
        XCTAssertNotNil(capture.inactivity)
        capture.handle(.speech, session: id)
        XCTAssertNil(capture.inactivity)
        run(capture, for: 9.8, session: id)
        XCTAssertNil(capture.inactivity)
        XCTAssertEqual(capture.phase, .recording(id))
    }

    func testNotYetCountsAgain() async throws {
        let capture = session()
        let id = try await start(capture)
        run(capture, for: 10, session: id)
        capture.keepRecording()
        XCTAssertNil(capture.inactivity)
        run(capture, for: 9.8, session: id)
        XCTAssertNil(capture.inactivity)
        run(capture, for: 0.2, session: id)
        XCTAssertNotNil(capture.inactivity)
    }

    func testAPauseWithdrawsTheQuestionAndIsNotCounted() async throws {
        let capture = session()
        let id = try await start(capture)
        run(capture, for: 10, session: id)
        await capture.pause()
        XCTAssertNil(capture.inactivity)
        time += 600
        await capture.resume()
        run(capture, for: 9.8, session: id)
        XCTAssertNil(capture.inactivity)
        XCTAssertEqual(capture.phase, .recording(id))
    }

    func testTheSettingTurnsItOff() async throws {
        let capture = session()
        settings.set(false, for: .inactivityStop)
        let id = try await start(capture)
        run(capture, for: 60, session: id)
        XCTAssertNil(capture.inactivity)
        XCTAssertEqual(capture.phase, .recording(id))
    }

    func testASimulationIsNeverStopped() async throws {
        let capture = session()
        let id = try await start(capture, simulated: true)
        run(capture, for: 60, session: id)
        XCTAssertNil(capture.inactivity)
        XCTAssertEqual(capture.phase, .recording(id))
    }

    func testACaptureThatCannotDetectSpeechIsNeverStopped() async throws {
        let capture = session()
        let id = try await start(capture, detectsSpeech: false)
        run(capture, for: 60, session: id)
        XCTAssertNil(capture.inactivity)
        XCTAssertEqual(capture.phase, .recording(id))
    }
}

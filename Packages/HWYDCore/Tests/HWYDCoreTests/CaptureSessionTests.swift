import XCTest
@testable import HWYDCore

/// A capture whose resume fails, as a device that disappeared while paused.
private actor UnresumableCapture: AudioCapture {
    struct Failure: LocalizedError { var errorDescription: String? { "resume failed" } }
    nonisolated let isSimulated = false
    nonisolated let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    init() { (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self) }
    func start(session id: UUID, continuing continuation: CaptureContinuation, microphone: String?) async throws {}
    nonisolated let microphone: MicrophoneDevice? = nil
    nonisolated let microphones = MicrophoneList()
    func switchMicrophone(to uid: String, reason: MicrophoneSwitchReason) async throws {}
    func pause() async {}
    func resume() async throws { throw Failure() }
    func stop() async -> CapturedAudio { continuation.finish(); return CapturedAudio() }
}

/// A capture whose resume waits until the test lets it go, as a Bluetooth headset negotiating call mode.
private actor SlowResumeCapture: AudioCapture {
    nonisolated let isSimulated = false
    nonisolated let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private var held: CheckedContinuation<Void, Never>?
    private(set) var resumes = 0
    init() { (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self) }
    func start(session id: UUID, continuing continuation: CaptureContinuation, microphone: String?) async throws {}
    nonisolated let microphone: MicrophoneDevice? = nil
    nonisolated let microphones = MicrophoneList()
    func switchMicrophone(to uid: String, reason: MicrophoneSwitchReason) async throws {}
    func pause() async {}
    func resume() async throws { resumes += 1; await withCheckedContinuation { held = $0 } }
    var isHolding: Bool { held != nil }
    func release() { held?.resume(); held = nil }
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
        let fault = CaptureFault(.stalled, message: "route")
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

    func testASecondResumeWhileTheFirstWaitsForAudioIsIgnored() async throws {
        let capture = session(), device = SlowResumeCapture()
        let idStarted = try await capture.start(CaptureRequest(), with: device, in: SessionLibrary(volatile: []))
        let id = try XCTUnwrap(idStarted)
        time += 5
        await capture.pause()
        let first = Task { await capture.resume() }
        for _ in 0..<1000 { if await device.isHolding { break }; try? await Task.sleep(for: .milliseconds(1)) }
        await capture.resume()
        let resumes = await device.resumes
        XCTAssertEqual(resumes, 1, "the second request does not reach the capture")
        XCTAssertEqual(capture.phase, .paused(id), "the clock waits for audio")
        time += 6
        await device.release(); await first.value
        XCTAssertEqual(capture.phase, .recording(id))
        XCTAssertEqual(capture.elapsed, 5, accuracy: 1e-9, "the wait for audio is not recorded time")
    }

    func testARestartEndingWhileThePauseHeldTheClockSkipsNothing() async throws {
        let capture = session()
        let idStarted = try await capture.start(CaptureRequest(), with: realCapture(), in: SessionLibrary(volatile: []))
        let id = try XCTUnwrap(idStarted)
        time += 10
        await capture.pause()
        // A rebuild during the pause: the session ignores its start, then hears it ended.
        capture.handle(.restarting, session: id)
        capture.handle(.restarted(gap: 2), session: id)
        await capture.resume()
        XCTAssertEqual(capture.elapsed, 10, accuracy: 1e-9)
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

/// The microphone is a choice: offers, switches, a microphone that disappears.
@MainActor
final class CaptureMicrophoneTests: XCTestCase {
    private var time: TimeInterval = 100
    private var wall = Date(timeIntervalSince1970: 1_800_000_000)
    private var transcriptions: [UUID] = []
    private let notifier = RecordingNotifier()
    private let settings = InMemorySettings()
    private let builtIn = MicrophoneDevice(uid: "builtin", name: "Micro du Mac", transport: .builtIn)
    private let usb = MicrophoneDevice(uid: "usb", name: "Yeti", transport: .usb)
    private let airpods = MicrophoneDevice(uid: "airpods", name: "AirPods", transport: .bluetooth)
    private let chunk = AudioChunk(source: .mic, relativePath: "audio/x/mic-000000.caf", start: 0, duration: 5)

    private func session() -> CaptureSession {
        CaptureSession(notifier: notifier, transcribe: { [unowned self] id in transcriptions.append(id); return .accepted },
                       now: { [unowned self] in time }, date: { [unowned self] in wall }, settings: { [unowned self] in settings })
    }
    /// Runs during a switch, between `restarting` and `restarted(gap:)`, as while a graph is rebuilt.
    private var duringSwitch: (@MainActor () async -> Void)?
    private func device(_ devices: [MicrophoneDevice]? = nil, gap: TimeInterval = 0) -> SimulatedCapture {
        SimulatedCapture(animatesLevels: false, simulated: false, audio: CapturedAudio(chunks: [chunk]),
                         microphones: MicrophoneList(devices: devices ?? [builtIn, usb], defaultInput: "builtin"), switchGap: gap,
                         elapse: { [unowned self] gap in
                             time += gap
                             let action = duringSwitch; duringSwitch = nil
                             await action?()
                         })
    }
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
    }
    private func start(_ capture: CaptureSession, _ device: SimulatedCapture, in library: SessionLibrary, microphone: String? = nil) async throws -> UUID {
        let id = try await capture.start(CaptureRequest(microphone: microphone), with: device, in: library)
        return try XCTUnwrap(id)
    }

    func testStartsOnTheChosenMicrophoneAndRemembersIt() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        let id = try await start(capture, device, in: library, microphone: "usb")
        let recorded = await device.microphoneUID
        XCTAssertEqual(recorded, "usb")
        XCTAssertEqual(capture.microphone, usb); XCTAssertEqual(capture.microphones.devices, [builtIn, usb])
        XCTAssertEqual(settings.value(.microphone), "usb")
        XCTAssertEqual(library.recording(id)?.microphone, "Yeti")
        XCTAssertNil(library.recording(id)?.boundaries, "the first microphone is no boundary")
    }

    /// Without a choice (shortcut, calendar, resume), the session records the remembered microphone.
    func testWithoutAChoiceTheRememberedMicrophoneIsRecorded() async throws {
        settings.set("usb", for: .microphone)
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        _ = try await start(capture, device, in: library)
        let recorded = await device.microphoneUID
        XCTAssertEqual(recorded, "usb")
        XCTAssertEqual(capture.preferredMicrophone(in: MicrophoneList(devices: [builtIn, usb])), "usb")
        XCTAssertNil(capture.preferredMicrophone(in: MicrophoneList(devices: [builtIn])), "absent: the system default input")
    }

    func testARememberedMicrophoneThatIsAbsentGivesTheDefaultInput() async throws {
        settings.set("airpods", for: .microphone)
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        _ = try await start(capture, device, in: library)
        XCTAssertEqual(capture.microphone, builtIn)
        XCTAssertEqual(settings.value(.microphone), "airpods", "an absent microphone stays remembered")
    }

    func testTheSystemDefaultInputIsUsedWithoutAChoiceAndNotRemembered() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        let id = try await start(capture, device, in: library)
        XCTAssertEqual(capture.microphone, builtIn)
        XCTAssertNil(settings.value(.microphone))
        XCTAssertEqual(library.recording(id)?.microphone, "Micro du Mac")
    }

    func testRememberedMicrophoneFallsBackToTheDefaultInputWhenAbsent() {
        let list = MicrophoneList(devices: [builtIn, usb], defaultInput: "builtin")
        XCTAssertEqual(list.choice(remembered: "usb"), "usb")
        XCTAssertNil(list.choice(remembered: "airpods"), "absent: the system default input")
        XCTAssertNil(list.choice(remembered: nil))
    }

    func testANewDefaultInputIsOnlyOffered() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        let id = try await start(capture, device, in: library)
        await device.offer(airpods)
        await waitUntil { capture.offer != nil }
        XCTAssertEqual(capture.offer?.device, airpods); XCTAssertEqual(capture.offer?.current, "Micro du Mac")
        // No answer: nothing changes.
        time += 30
        let switches = await device.switches
        XCTAssertTrue(switches.isEmpty)
        XCTAssertEqual(capture.microphone, builtIn); XCTAssertNil(library.recording(id)?.boundaries)
        XCTAssertEqual(capture.phase, .recording(id))
    }

    func testAcceptingTheOfferSwitchesAndRecordsABoundary() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        let id = try await start(capture, device, in: library)
        time += 12
        await device.offer(airpods)
        await waitUntil { capture.offer != nil }
        await capture.acceptOffer()
        await waitUntil { capture.microphone == airpods }
        let switches = await device.switches
        XCTAssertEqual(switches.map(\.uid), ["airpods"]); XCTAssertEqual(switches.map(\.reason), [.accepted])
        XCTAssertNil(capture.offer)
        XCTAssertEqual(library.recording(id)?.boundaries, [CaptureBoundary(offset: 12, at: wall, reason: .accepted, microphone: "AirPods")])
        XCTAssertEqual(settings.value(.microphone), "airpods")
    }

    func testDecliningKeepsTheMicrophone() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        let id = try await start(capture, device, in: library)
        await device.offer(airpods)
        await waitUntil { capture.offer != nil }
        capture.declineOffer()
        XCTAssertNil(capture.offer)
        await capture.acceptOffer()
        let switches = await device.switches
        XCTAssertTrue(switches.isEmpty, "nothing left to accept")
        XCTAssertEqual(capture.microphone, builtIn); XCTAssertNil(library.recording(id)?.boundaries)
        XCTAssertNil(settings.value(.microphone))
    }

    func testANewerChangeReplacesThePendingOffer() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        _ = try await start(capture, device, in: library)
        await device.offer(airpods)
        await waitUntil { capture.offer?.device == airpods }
        let first = try XCTUnwrap(capture.offer?.id)
        await device.offer(usb)
        await waitUntil { capture.offer?.device == usb }
        XCTAssertNotEqual(capture.offer?.id, first)
        // The system goes back to the microphone in use: nothing left to offer.
        await device.offer(builtIn)
        await waitUntil { capture.offer == nil }
    }

    func testAnOfferWhoseDeviceLeavesIsWithdrawn() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        _ = try await start(capture, device, in: library)
        await device.offer(airpods)
        await waitUntil { capture.offer != nil }
        await device.remove("airpods")
        await waitUntil { capture.offer == nil }
        XCTAssertEqual(capture.microphone, builtIn)
    }

    func testChoosingAnotherMicrophoneSwitchesAtOnce() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        let id = try await start(capture, device, in: library)
        time += 4
        await capture.chooseMicrophone("usb")
        await waitUntil { capture.microphone == usb }
        let switches = await device.switches
        XCTAssertEqual(switches.map(\.reason), [.user])
        XCTAssertEqual(library.recording(id)?.boundaries, [CaptureBoundary(offset: 4, at: wall, reason: .user, microphone: "Yeti")])
        XCTAssertEqual(settings.value(.microphone), "usb")
        await capture.chooseMicrophone("usb")
        let again = await device.switches
        XCTAssertEqual(again.count, 1, "already in use")
    }

    func testAFailedChoiceKeepsTheMicrophoneAndSaysSo() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        let id = try await start(capture, device, in: library)
        await device.failSwitches(to: "usb")
        await capture.chooseMicrophone("usb")
        XCTAssertEqual(capture.microphone, builtIn); XCTAssertNil(library.recording(id)?.boundaries)
        XCTAssertEqual(notifier.notices.last?.style, .error)
        XCTAssertNil(settings.value(.microphone), "a choice is remembered only once recorded")
        XCTAssertEqual(capture.phase, .recording(id))
    }

    func testAMicrophoneThatDisappearsGivesWayToTheDefaultInputAndTheUserIsTold() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        var forced: [(MicrophoneDevice, MicrophoneDevice)] = []
        capture.onForcedSwitch = { forced.append(($0, $1)) }
        let id = try await start(capture, device, in: library, microphone: "usb")
        time += 20
        await device.remove("usb")
        await waitUntil { capture.microphone == builtIn }
        let switches = await device.switches
        XCTAssertEqual(switches.map(\.uid), ["builtin"]); XCTAssertEqual(switches.map(\.reason), [.forced])
        XCTAssertEqual(library.recording(id)?.boundaries, [CaptureBoundary(offset: 20, at: wall, reason: .forced, microphone: "Micro du Mac")])
        await waitUntil { !forced.isEmpty }
        XCTAssertEqual(forced.map(\.0), [usb]); XCTAssertEqual(forced.map(\.1), [builtIn])
        XCTAssertEqual(notifier.messages.last, String(localized: "Le micro Yeti n’est plus disponible. L’enregistrement continue sur Micro du Mac.", bundle: .hwyd))
        XCTAssertEqual(settings.value(.microphone), "usb", "a forced switch is no choice")
        XCTAssertEqual(capture.phase, .recording(id))
    }

    func testNoMicrophoneLeftInterruptsTheSessionAndKeepsItsAudio() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device([builtIn])
        var endings: [CaptureEnding] = []
        capture.onEnd = { endings.append($0) }
        let id = try await start(capture, device, in: library)
        time += 7
        await device.remove("builtin")
        await waitUntil { capture.phase == .idle }
        guard case .failed(let fault) = endings.first?.cause else { return XCTFail("the session stops on a fault") }
        XCTAssertEqual(fault.kind, .noMicrophone)
        let item = try XCTUnwrap(library.recording(id))
        XCTAssertEqual(item.state, .interrupted); XCTAssertEqual(item.audioChunks, [chunk])
        XCTAssertEqual(item.duration, 7, accuracy: 1e-9, "the clock froze when the microphone left")
        await waitUntil { transcriptions == [id] }
        XCTAssertNil(SessionResume.refusal(for: item, now: wall, captureIdle: true), "it can be resumed")
    }

    func testTheClockSkipsTheSwitchAndBoundariesFollowTheTimeline() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device(gap: 0.8)
        let id = try await start(capture, device, in: library)
        time += 10
        await capture.chooseMicrophone("usb")
        await waitUntil { capture.microphone == usb }
        // The rebuild took 0.8 s on the clock: the session clock skips them and resumes where
        // the new microphone starts.
        XCTAssertEqual(capture.elapsed, 10, accuracy: 1e-9)
        XCTAssertEqual(library.recording(id)?.boundaries?.first?.offset ?? -1, capture.elapsed, accuracy: 1e-9)
        time += 5
        await capture.pause()
        time += 30
        await capture.chooseMicrophone("builtin")
        await waitUntil { capture.microphone == builtIn }
        XCTAssertEqual(capture.elapsed, 15, accuracy: 1e-9, "a switch while paused leaves the paused clock alone")
        await capture.resume()
        time += 5
        await capture.stop()
        let item = try XCTUnwrap(library.recording(id))
        XCTAssertEqual(item.boundaries?.map(\.reason), [.user, .user])
        let offsets = item.boundaries?.map(\.offset) ?? []
        XCTAssertEqual(offsets.count, 2)
        for (offset, expected) in zip(offsets, [10.0, 15]) { XCTAssertEqual(offset, expected, accuracy: 1e-9) }
        XCTAssertEqual(item.duration, 20, accuracy: 1e-9)
        // The echo canceller starts again at each switch, as at a resume.
        let locales = SpeechLocales(installed: ["fr-FR"], supported: ["fr-FR"])
        XCTAssertEqual(TranscriptionRequest(session: item, diarize: false, locales: locales).echoResets, offsets)
        // No marker in the transcript for a microphone change.
        XCTAssertTrue(SessionResume.markers(item.boundaries, before: [TranscriptSegment(start: 16, end: 17, speakerID: nil, source: .mic, text: "x")]).isEmpty)
    }

    func testResumingRecordsOnTheGivenMicrophone() async throws {
        let capture = session(), device = device()
        var item = Recording(title: "Point", duration: 5, state: .sealed)
        item.audioChunks = [chunk]; item.endedAt = wall.addingTimeInterval(-60); item.microphone = "Micro du Mac"
        let library = SessionLibrary(volatile: [item])
        let started = try await capture.continueRecording(item.id, with: device, in: library, microphone: "usb")
        XCTAssertTrue(started)
        XCTAssertEqual(library.recording(item.id)?.boundaries?.last?.microphone, "Yeti")
        XCTAssertEqual(library.recording(item.id)?.microphone, "Micro du Mac", "the first microphone stays")
    }

    func testExportsNameTheFirstMicrophoneOnlyWhenKnown() throws {
        var item = Recording(title: "Point", duration: 5)
        XCTAssertNil(try SessionExporter.document(item)["microphone"])
        item.microphone = "Yeti"
        XCTAssertEqual(try SessionExporter.document(item)["microphone"] as? String, "Yeti")
    }

    /// The replacement cannot start: the session stops, interrupted, audio kept.
    func testAForcedSwitchThatFailsStopsTheSession() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        var endings: [CaptureEnding] = []
        capture.onEnd = { endings.append($0) }
        let id = try await start(capture, device, in: library, microphone: "usb")
        await device.failSwitches(to: "builtin")
        await device.remove("usb")
        await waitUntil { capture.phase == .idle }
        guard case .failed(let fault) = endings.first?.cause else { return XCTFail("the session stops on a fault") }
        XCTAssertEqual(fault.kind, .restart)
        XCTAssertEqual(endings.count, 1)
        XCTAssertEqual(library.recording(id)?.state, .interrupted)
        XCTAssertNil(library.recording(id)?.boundaries)
    }

    /// An offer accepted while paused switches at once; the boundary is at the paused time and the
    /// clock stays frozen until the resume.
    func testAnOfferAcceptedWhilePausedSwitchesWithoutRunningTheClock() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device(gap: 0.8)
        let id = try await start(capture, device, in: library)
        time += 6
        await capture.pause()
        time += 20
        await device.offer(airpods)
        await waitUntil { capture.offer != nil }
        await capture.acceptOffer()
        await waitUntil { capture.microphone == airpods }
        XCTAssertEqual(capture.elapsed, 6, accuracy: 1e-9)
        XCTAssertEqual(library.recording(id)?.boundaries?.map(\.offset), [6])
        XCTAssertEqual(settings.value(.microphone), "airpods")
        await capture.resume()
        time += 4
        XCTAssertEqual(capture.elapsed, 10, accuracy: 1e-9)
    }

    /// An offer that comes while a switch runs stays, naming the microphone recorded once the
    /// switch is over; accepting it then switches again.
    func testAnOfferDuringASwitchWaitsForIt() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        let id = try await start(capture, device, in: library)
        duringSwitch = { [unowned self] in
            await device.offer(airpods)
            await waitUntil { capture.offer != nil }
            XCTAssertTrue(capture.isSwitchingMicrophone)
        }
        await capture.chooseMicrophone("usb")
        await waitUntil { capture.microphone == usb }
        XCTAssertEqual(capture.offer?.device, airpods)
        XCTAssertEqual(capture.offer?.current, "Yeti", "Garder names the microphone recorded now")
        XCTAssertFalse(capture.isSwitchingMicrophone)
        await capture.acceptOffer()
        await waitUntil { capture.microphone == airpods }
        XCTAssertEqual(library.recording(id)?.boundaries?.map(\.reason), [.user, .accepted])
    }

    /// A choice made while another switch runs waits its turn instead of being dropped.
    func testAChoiceDuringASwitchRunsAfterIt() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device([builtIn, usb, airpods])
        let id = try await start(capture, device, in: library)
        var second: Task<Void, Never>?
        duringSwitch = { second = Task { await capture.chooseMicrophone("airpods") } }
        await capture.chooseMicrophone("usb")
        await second?.value
        let switches = await device.switches
        XCTAssertEqual(switches.map(\.uid), ["usb", "airpods"])
        XCTAssertEqual(capture.microphone, airpods); XCTAssertFalse(capture.isSwitchingMicrophone)
        XCTAssertEqual(library.recording(id)?.boundaries?.map(\.microphone), ["Yeti", "AirPods"])
        XCTAssertEqual(settings.value(.microphone), "airpods")
    }

    /// N2: the session stops while the forced switch rebuilds: no notice that recording goes on.
    func testAStopDuringAForcedSwitchEndsQuietly() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        var endings: [CaptureEnding] = [], forced = 0
        capture.onEnd = { endings.append($0) }
        capture.onForcedSwitch = { _, _ in forced += 1 }
        _ = try await start(capture, device, in: library, microphone: "usb")
        duringSwitch = { await capture.stop() }
        await device.remove("usb")
        await waitUntil { capture.phase == .idle && !endings.isEmpty }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(endings.map(\.cause), [.requested])
        XCTAssertEqual(forced, 0)
        XCTAssertFalse(notifier.messages.contains { $0.contains("L’enregistrement continue") })
        XCTAssertFalse(capture.isSwitchingMicrophone)
    }

    /// A notification answered after the session ended does nothing.
    func testAnAnswerAfterTheSessionEndedDoesNothing() async throws {
        let capture = session(), library = SessionLibrary(volatile: []), device = device()
        _ = try await start(capture, device, in: library)
        await device.offer(airpods)
        await waitUntil { capture.offer != nil }
        await capture.stop()
        XCTAssertNil(capture.offer)
        await capture.acceptOffer()
        await capture.chooseMicrophone("usb")
        capture.declineOffer()
        let switches = await device.switches
        XCTAssertTrue(switches.isEmpty)
        XCTAssertNil(settings.value(.microphone))
    }
}

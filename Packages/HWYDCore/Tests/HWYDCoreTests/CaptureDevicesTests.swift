import XCTest
@testable import HWYDCore

/// What a running capture makes of device changes, without hardware.
final class CaptureDevicesTests: XCTestCase {
    private let builtIn = MicrophoneDevice(uid: "builtin", name: "Micro du Mac", transport: .builtIn)
    private let usb = MicrophoneDevice(uid: "usb", name: "Yeti", transport: .usb)
    private let airpods = MicrophoneDevice(uid: "airpods", name: "AirPods", transport: .bluetooth)
    private let speakers: UInt32 = 40, headphones: UInt32 = 41

    private func list(_ devices: [MicrophoneDevice], default input: String?) -> MicrophoneList { MicrophoneList(devices: devices, defaultInput: input) }
    private func recording(on microphone: MicrophoneDevice) -> CaptureDevices {
        CaptureDevices(list: list([builtIn, usb], default: "builtin"), output: speakers, microphone: microphone)
    }

    func testNothingChangedMeansNothingToDo() {
        var devices = recording(on: builtIn)
        XCTAssertEqual(devices.check(list: list([builtIn, usb], default: "builtin"), output: speakers, microphoneAlive: true), [])
    }

    func testADeviceThatAppearsIsReportedOnceAndNotOffered() {
        var devices = recording(on: builtIn)
        let added = list([builtIn, usb, airpods], default: "builtin")
        XCTAssertEqual(devices.check(list: added, output: speakers, microphoneAlive: true), [.report(added)])
        XCTAssertEqual(devices.check(list: added, output: speakers, microphoneAlive: true), [])
    }

    /// AirPods connect: they become the default input and output in one burst.
    func testANewDefaultInputIsOfferedAndANewOutputRebuildsTheTap() {
        var devices = recording(on: builtIn)
        let connected = list([builtIn, usb, airpods], default: "airpods")
        XCTAssertEqual(devices.check(list: connected, output: headphones, microphoneAlive: true),
                       [.report(connected), .rebuildForOutput, .offer(airpods)])
        XCTAssertTrue(devices.outputChanged)
        devices.tapRebuilt()
        XCTAssertEqual(devices.check(list: connected, output: headphones, microphoneAlive: true), [], "one rebuild, one offer")
    }

    func testTheDefaultInputComingBackToTheMicrophoneInUseIsNoOffer() {
        var devices = recording(on: usb)
        let back = list([builtIn, usb], default: "usb")
        XCTAssertEqual(devices.check(list: back, output: speakers, microphoneAlive: true), [.report(back)])
    }

    /// S1: AirPods connect and the user picks the USB microphone before the check settles. The
    /// switch reads the devices without moving the reference: the check still reports and offers.
    func testASwitchBeforeTheCheckDoesNotSwallowTheChange() {
        var devices = recording(on: builtIn)
        devices.switched(to: usb, newTap: false)
        let connected = list([builtIn, usb, airpods], default: "airpods")
        XCTAssertEqual(devices.check(list: connected, output: speakers, microphoneAlive: true), [.report(connected), .offer(airpods)])
    }

    /// The user picked the AirPods themselves before the check: reported, not offered.
    func testASwitchToTheNewDefaultBeforeTheCheckIsNoOffer() {
        var devices = recording(on: builtIn)
        devices.switched(to: airpods, newTap: false)
        let connected = list([builtIn, usb, airpods], default: "airpods")
        XCTAssertEqual(devices.check(list: connected, output: speakers, microphoneAlive: true), [.report(connected)])
    }

    func testAMicrophoneThatLeavesIsLostOnce() {
        var devices = recording(on: usb)
        let left = list([builtIn], default: "builtin")
        XCTAssertEqual(devices.check(list: left, output: speakers, microphoneAlive: false), [.report(left), .lose(usb)])
        XCTAssertTrue(devices.isLost)
        let again = list([builtIn, airpods], default: "airpods")
        XCTAssertEqual(devices.check(list: again, output: speakers, microphoneAlive: false), [.report(again)], "nothing is offered or lost while lost")
        devices.switched(to: builtIn, newTap: false)
        XCTAssertFalse(devices.isLost)
        XCTAssertEqual(devices.microphone, builtIn)
    }

    /// A microphone still listed but no longer alive is lost too: its device notifies first.
    func testAMicrophoneThatIsNoLongerAliveIsLost() {
        var devices = recording(on: usb)
        XCTAssertEqual(devices.check(list: list([builtIn, usb], default: "builtin"), output: speakers, microphoneAlive: false), [.lose(usb)])
    }

    /// N1: AirPods recorded and played through are unplugged. The loss wins; the forced switch
    /// builds the tap again, and the output change asks for no rebuild of its own.
    func testALossWithAnOutputChangeRebuildsOnce() {
        var devices = CaptureDevices(list: list([builtIn, airpods], default: "airpods"), output: headphones, microphone: airpods)
        let unplugged = list([builtIn], default: "builtin")
        XCTAssertEqual(devices.check(list: unplugged, output: speakers, microphoneAlive: false), [.report(unplugged), .lose(airpods)])
        XCTAssertTrue(devices.outputChanged, "the next switch builds the tap again")
        // Our own aggregate, created by the switch, notifies the devices.
        XCTAssertEqual(devices.check(list: unplugged, output: speakers, microphoneAlive: false), [])
        devices.switched(to: builtIn, newTap: true)
        XCTAssertFalse(devices.outputChanged)
        XCTAssertEqual(devices.check(list: unplugged, output: speakers, microphoneAlive: true), [], "no second rebuild")
    }
}

/// One device operation at a time: a check or a rebuild is never interrupted by a notification.
final class DeviceCheckGateTests: XCTestCase {
    /// B1: a rebuild for a new output waits inside a check; our own aggregate and the headset
    /// notify meanwhile. The check runs to its end, and one more follows.
    func testANotificationDuringACheckWaitsForItsEnd() {
        var gate = DeviceCheckGate()
        XCTAssertTrue(gate.notified())
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.notified(), "no new check, and nothing cancelled")
        XCTAssertFalse(gate.notified())
        XCTAssertTrue(gate.end(), "one check follows")
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.end(), "nothing came meanwhile")
    }

    func testASwitchIsRefusedWhileACheckRunsAndAChangeDuringASwitchIsCheckedAfter() {
        var gate = DeviceCheckGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin(), "a second operation waits or is refused")
        XCTAssertTrue(gate.end())
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.notified())
        XCTAssertTrue(gate.end())
        XCTAssertFalse(gate.isBusy); XCTAssertFalse(gate.isPending)
    }
}

/// Waiting for the first buffers of a rebuilt graph, and what may happen meanwhile.
final class AudioWaitTests: XCTestCase {
    private actor Probes {
        var answers: [AudioWait.Probe]
        var count = 0
        init(_ answers: [AudioWait.Probe]) { self.answers = answers }
        func next() -> AudioWait.Probe { count += 1; return answers.count > 1 ? answers.removeFirst() : answers[0] }
    }
    private func deadline(_ seconds: Double = 2) -> ContinuousClock.Instant { .now.advanced(by: .milliseconds(Int(seconds * 1000))) }

    func testReturnsOnceTheAudioFlows() async throws {
        let probes = Probes([.waiting, .waiting, .flowing])
        let outcome = try await AudioWait.until(deadline(), every: .milliseconds(1)) { await probes.next() }
        XCTAssertEqual(outcome, .flowing)
        let count = await probes.count
        XCTAssertEqual(count, 3)
    }

    /// B1: the task that waits is cancelled, as a newer device notification used to do. The wait
    /// goes on until the audio flows.
    func testCancellingTheWaitingTaskDoesNotEndTheWait() async throws {
        let probes = Probes([.waiting, .waiting, .waiting, .flowing])
        let end = deadline()
        let task = Task { try await AudioWait.until(end, every: .milliseconds(5)) { await probes.next() } }
        task.cancel()
        let outcome = try await task.value
        XCTAssertEqual(outcome, .flowing)
    }

    /// The device changed its channel count while the graph waited for its first buffers: the wait ends at once,
    /// so the capture builds the graph again instead of waiting for a deadline no buffer can meet.
    func testAFormatChangeEndsTheWait() async throws {
        let probes = Probes([.waiting, .formatChanged, .flowing])
        let outcome = try await AudioWait.until(deadline(), every: .milliseconds(1)) { await probes.next() }
        XCTAssertEqual(outcome, .formatChanged)
    }

    /// A pause or a stop during a rebuild ends the wait without an error: the rebuild is kept, and
    /// resuming waits for the first buffers.
    func testAPauseOrAStopEndsTheWait() async throws {
        let paused = Probes([.waiting, .paused])
        let first = try await AudioWait.until(deadline(), every: .milliseconds(1)) { await paused.next() }
        XCTAssertEqual(first, .paused)
        let stopped = Probes([.waiting, .stopped])
        let second = try await AudioWait.until(deadline(), every: .milliseconds(1)) { await stopped.next() }
        XCTAssertEqual(second, .stopped)
    }

    func testAWriterFailureOrTheDeadlineThrows() async {
        let failing = Probes([.waiting, .failed("lost buffers")])
        do { _ = try await AudioWait.until(deadline(), every: .milliseconds(1)) { await failing.next() }; XCTFail("must throw") }
        catch { XCTAssertEqual(error as? AudioWait.Failure, AudioWait.Failure(message: "lost buffers")) }
        let silent = Probes([.waiting])
        do { _ = try await AudioWait.until(deadline(0.05), every: .milliseconds(5)) { await silent.next() }; XCTFail("must throw") }
        catch { XCTAssertTrue(error is AudioWait.Timeout) }
    }
}

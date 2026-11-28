import XCTest
@testable import HWYDCore

final class MicrophoneReadingTests: XCTestCase {
    private let builtIn = MicrophoneReading.builtInMicrophoneUID

    func testBuiltInMicrophoneOnOneChannelIsReadAsIs() {
        XCTAssertEqual(MicrophoneReading(uid: builtIn, channels: 1, othersReading: true), .firstChannel)
    }

    func testBuiltInMicrophoneHeldByACallIsReadFromItsCapsules() {
        XCTAssertEqual(MicrophoneReading(uid: builtIn, channels: 3, othersReading: true), .capsules(gain: MicrophoneReading.capsuleGain))
    }

    func testBuiltInMicrophoneWithoutAnotherReaderIsReadAsIs() {
        // Several channels with nobody else reading input: not a call's voice processing, never raised.
        XCTAssertEqual(MicrophoneReading(uid: builtIn, channels: 3, othersReading: false), .firstChannel)
    }

    func testOtherBuiltInStereoInputKeepsItsFirstChannel() {
        // A built-in line input, or the stereo microphone of an Intel Mac, has two channels of its own.
        XCTAssertEqual(MicrophoneReading(uid: "BuiltInLineInputDevice", channels: 2, othersReading: true), .firstChannel)
        XCTAssertEqual(MicrophoneReading(uid: "AppleHDAEngineInput:1B,0,1,0:1", channels: 2, othersReading: true), .firstChannel)
    }

    func testExternalInterfaceKeepsItsFirstChannel() {
        // A six-input USB interface: the microphone is on its first input, the others may be silent.
        XCTAssertEqual(MicrophoneReading(uid: "AppleUSBAudioEngine:Native Instruments:Komplete Audio 6:1,2", channels: 6, othersReading: true), .firstChannel)
    }

    func testCapsulesAreAveragedThenRaised() {
        let frame: [Float] = [0.001, 0.002, 0.003]
        let value = frame.withUnsafeBufferPointer { MicrophoneReading.capsules(gain: 79.4).sample($0.baseAddress!, channels: 3) }
        XCTAssertEqual(value, 0.002 * 79.4, accuracy: 1e-5)
    }

    func testRaisedCapsulesStayWithinFullScale() {
        let frame: [Float] = [0.5, -0.5, 0.5]
        let reading = MicrophoneReading.capsules(gain: 79.4)
        XCTAssertEqual(frame.withUnsafeBufferPointer { reading.sample($0.baseAddress!, channels: 3) }, 1)
        let negative: [Float] = [-0.5, -0.5, -0.5]
        XCTAssertEqual(negative.withUnsafeBufferPointer { reading.sample($0.baseAddress!, channels: 3) }, -1)
    }

    func testFirstChannelIgnoresTheOthers() {
        let frame: [Float] = [0.2, 0.9, 0.9]
        XCTAssertEqual(frame.withUnsafeBufferPointer { MicrophoneReading.firstChannel.sample($0.baseAddress!, channels: 3) }, 0.2)
    }

    func testMoreChannelsIsAFormatChange() {
        // Joining a call: the built-in microphone goes from one channel to three.
        XCTAssertTrue(CaptureDrops(overflow: 3).isFormatChange)
    }

    func testFewerChannelsIsAFormatChange() {
        // Leaving the call: back to one channel.
        XCTAssertTrue(CaptureDrops(fewerChannels: 2).isFormatChange)
    }

    func testAnyOtherLossIsNotAFormatChange() {
        XCTAssertFalse(CaptureDrops(full: 1).isFormatChange)
        XCTAssertFalse(CaptureDrops(inconsistent: 1).isFormatChange)
        // No frame, or more than the ring holds: a broken buffer, not a new format.
        XCTAssertFalse(CaptureDrops(frameSize: 1).isFormatChange)
        XCTAssertFalse(CaptureDrops(overflow: 3, full: 1).isFormatChange)
        XCTAssertFalse(CaptureDrops(frameSize: 1, fewerChannels: 2).isFormatChange)
        XCTAssertFalse(CaptureDrops().isFormatChange)
    }

    func testSummaryListsReasonsInTheRingsOrder() {
        XCTAssertEqual(CaptureDrops(overflow: 3, inconsistent: 0, frameSize: 2, full: 1, fewerChannels: 5).summary, "3/0/2/1/5")
    }

    func testRebuildBudgetAllowsJoiningAndLeavingCalls() {
        var budget = FormatRebuildBudget()
        XCTAssertTrue(budget.allow(now: 0))
        XCTAssertTrue(budget.allow(now: 40))
        XCTAssertTrue(budget.allow(now: 80))
    }

    func testRebuildBudgetStopsALoop() {
        var budget = FormatRebuildBudget()
        for step in 0..<FormatRebuildBudget.limit { XCTAssertTrue(budget.allow(now: Double(step) * 0.3)) }
        XCTAssertFalse(budget.allow(now: 1.5))
        // Once the window passed, rebuilds are allowed again.
        XCTAssertTrue(budget.allow(now: 0.3 * Double(FormatRebuildBudget.limit - 1) + FormatRebuildBudget.window))
    }
}

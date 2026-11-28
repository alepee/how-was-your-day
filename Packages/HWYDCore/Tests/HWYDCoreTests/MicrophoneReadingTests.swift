import XCTest
@testable import HWYDCore

final class MicrophoneReadingTests: XCTestCase {
    func testBuiltInMicrophoneOnOneChannelIsReadAsIs() {
        XCTAssertEqual(MicrophoneReading(builtIn: true, channels: 1), .firstChannel)
    }

    func testBuiltInMicrophoneHeldByACallIsReadFromItsCapsules() {
        XCTAssertEqual(MicrophoneReading(builtIn: true, channels: 3), .capsules(gain: MicrophoneReading.capsuleGain))
    }

    func testExternalInterfaceKeepsItsFirstChannel() {
        // A six-input USB interface: the microphone is on its first input, the others may be silent.
        XCTAssertEqual(MicrophoneReading(builtIn: false, channels: 6), .firstChannel)
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
        XCTAssertTrue(CaptureDrops(layout: 2).isFormatChange)
    }

    func testAnyOtherLossIsNotAFormatChange() {
        XCTAssertFalse(CaptureDrops(full: 1).isFormatChange)
        XCTAssertFalse(CaptureDrops(inconsistent: 1).isFormatChange)
        XCTAssertFalse(CaptureDrops(overflow: 3, full: 1).isFormatChange)
        XCTAssertFalse(CaptureDrops().isFormatChange)
    }

    func testSummaryListsReasonsInOrder() {
        XCTAssertEqual(CaptureDrops(overflow: 3, inconsistent: 0, layout: 2, full: 1).summary, "3/0/2/1")
    }
}

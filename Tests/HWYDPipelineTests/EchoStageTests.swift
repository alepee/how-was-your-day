import XCTest
import AVFoundation
@testable import HWYDPipeline

final class EchoStageTests: XCTestCase {
    func testReadHandlesPartialDecoderReadsAndHistoryPadding() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
            buffer.frameLength = 32000
            buffer.floatChannelData![0].update(repeating: 0.25, count: 32000)
            try file.write(from: buffer)
        }
        let file = try AVAudioFile(forReading: url)
        let first = try EchoStage.read(file, start: -8000, count: 24000)
        XCTAssertEqual(first.count, 1500)
        XCTAssertTrue(first.prefix(500).allSatisfy { $0 == 0 })
        XCTAssertTrue(first.suffix(1000).allSatisfy { $0 == 0.25 })
        let last = try EchoStage.read(file, start: 24000, count: 8000)
        XCTAssertEqual(last.count, 500)
        XCTAssertTrue(last.allSatisfy { $0 == 0.25 })
    }
}

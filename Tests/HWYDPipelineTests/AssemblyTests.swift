import XCTest
import AVFoundation
import HWYDCore
@testable import HWYDPipeline

final class AssemblyTests: XCTestCase {
    func testAssemblyPreservesGapAndRejectsOverlap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(directory: root)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        buffer.floatChannelData![0].update(repeating: 0.25, count: 1600)
        do { let file = try AVAudioFile(forWriting: root.appendingPathComponent("source.caf"), settings: format.settings); try file.write(from: buffer) }
        let chunks = [AudioChunk(source: .mic, relativePath: "source.caf", start: 0, duration: 0.1), AudioChunk(source: .mic, relativePath: "source.caf", start: 0.2, duration: 0.1)]
        let output = root.appendingPathComponent("full.caf")
        try DiarizationStage.assemble(chunks, store: store, destination: output)
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.length, 4800)
        file.framePosition = 1600; try file.read(into: buffer, frameCount: 1600)
        XCTAssertTrue((0..<1600).allSatisfy { buffer.floatChannelData![0][$0] == 0 })
        var overlapping = chunks; overlapping[1].start = 0.05
        XCTAssertThrowsError(try DiarizationStage.assemble(overlapping, store: store, destination: root.appendingPathComponent("invalid.caf")))
    }
}

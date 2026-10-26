import XCTest
import AVFoundation
import HWYDCore
@testable import HWYDPipeline

final class EchoCancellationTests: XCTestCase {
    func testPreparationKeepsOriginalsAndChunkTiming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(directory: root)
        let url = root.appendingPathComponent("original.caf")
        try write((0..<1603).map { Float(sin(Double($0) * 0.1)) * 0.1 }, to: url)
        let original = try Data(contentsOf: url)
        let mic = AudioChunk(source: .mic, relativePath: "original.caf", start: 0.2, duration: 1603.0 / 16000)
        let system = AudioChunk(source: .system, relativePath: "original.caf", start: 0.1, duration: 1603.0 / 16000)
        var request = TranscriptionRequest(recordingID: UUID(), chunks: [mic, system])
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let prepared = try EchoCancellation.prepare(request, store: store, directory: work)
        XCTAssertEqual(try AVAudioFile(forReading: XCTUnwrap(prepared.chunks[mic.id])).length, 1603)
        XCTAssertEqual(try AVAudioFile(forReading: XCTUnwrap(prepared.microphone)).length, 4803)
        XCTAssertNil(prepared.chunks[system.id])
        XCTAssertEqual(try Data(contentsOf: url), original)
        request.echoCancellation = false
        XCTAssertNil(try EchoCancellation.prepare(request, store: store, directory: work).engine)
        request.echoCancellation = nil; request.chunks = [mic]
        XCTAssertNil(try EchoCancellation.prepare(request, store: store, directory: work).engine)
    }
    func testDelayedReverberantEchoAndDoubleTalk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = 16000 * 16 + 123
        var seed: UInt64 = 42
        var reference = [Float](repeating: 0, count: count)
        var near = reference, mic = reference
        var previous: Float = 0
        for i in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1
            let noise = Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
            previous = 0.65 * previous + 0.35 * noise
            reference[i] = previous * 0.3
            if i >= 16000 * 10 {
                near[i] = Float(sin(Double(i) * 2 * .pi * 233 / 16000)) * 0.08
            }
            mic[i] = near[i] + (i >= 1600 ? reference[i - 1600] * 0.6 : 0)
                + (i >= 2023 ? reference[i - 2023] * 0.2 : 0)
        }
        try write(mic, to: root.appendingPathComponent("mic.caf"))
        try write(reference, to: root.appendingPathComponent("ref.caf"))
        let output = root.appendingPathComponent("out.caf")
        try EchoCancellation.process(microphone: root.appendingPathComponent("mic.caf"), reference: root.appendingPathComponent("ref.caf"), output: output)
        let cleaned = try read(output)
        XCTAssertEqual(cleaned.count, count)
        let echoRange = (16000 * 6)..<(16000 * 9)
        let ratio = energy(cleaned, echoRange) / energy(mic, echoRange)
        print("Echo residual energy ratio: \(ratio)")
        XCTAssertLessThan(ratio, 0.05)
        let talkRange = (16000 * 12)..<(16000 * 15)
        let dot = talkRange.reduce(0.0) { $0 + Double(cleaned[$1] * near[$1]) }
        let gain = dot / energy(near, talkRange)
        print("Near-end retained gain during double talk: \(gain)")
        XCTAssertGreaterThan(gain, 0.7)
        XCTAssertLessThan(gain, 1.3)
    }
    func testMissingReferenceTailAndSilencePreserveTimeline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = (0..<16003).map { Float(sin(Double($0) * 0.1)) * 0.1 }
        try write(mic, to: root.appendingPathComponent("mic.caf"))
        try write([Float](repeating: 0, count: 256), to: root.appendingPathComponent("ref.caf"))
        let output = root.appendingPathComponent("out.caf")
        try EchoCancellation.process(microphone: root.appendingPathComponent("mic.caf"), reference: root.appendingPathComponent("ref.caf"), output: output)
        let cleaned = try read(output)
        XCTAssertEqual(cleaned.count, mic.count)
        XCTAssertTrue(cleaned.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(energy(cleaned, 8000..<16000) / energy(mic, 8000..<16000), 0.8)
    }
    private func energy(_ samples: [Float], _ range: Range<Int>) -> Double {
        range.reduce(0) { $0 + Double(samples[$1]) * Double(samples[$1]) }
    }
    private func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(samples.count))!
        buffer.frameLength = UInt32(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            samples += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }
}

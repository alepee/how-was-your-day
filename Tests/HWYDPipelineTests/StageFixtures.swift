import AVFoundation
import Foundation
import HWYDCore
@testable import HWYDPipeline

/// A private data directory for one test, removed with it. Never the user's.
final class StageFolder {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hwyd-stage-\(UUID().uuidString)")
    var audio: DataDirectoryAudio { DataDirectoryAudio(directory: root) }
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }

    /// Writes a 16 kHz mono chunk holding a constant level, which `LevelEmbedder` reads back.
    func chunk(_ name: String, source: AudioSource, seconds: Double, level: Float) throws -> AudioChunk {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: level, count: Int(frames))
        try AVAudioFile(forWriting: root.appendingPathComponent(name), settings: format.settings).write(from: buffer)
        return AudioChunk(source: source, relativePath: name, start: 0, duration: seconds)
    }
}

/// Stands for the voice model: a voice is the level of its audio, one axis per tenth.
struct LevelEmbedder: VoiceEmbedding {
    /// Runs while the "model" works, as an opposition recorded meanwhile would.
    var during: @Sendable () async throws -> Void = {}
    static func vector(level: Float) -> [Float] {
        var vector = [Float](repeating: 0, count: 256)
        vector[Int((level * 10).rounded())] = 1
        return vector
    }
    func embedding(of samples: [Float]) async throws -> [Float] {
        try await during()
        return Self.vector(level: samples.reduce(0, +) / Float(samples.count))
    }
}

/// Answers with the turns it was given and records the files it was asked to read.
actor ScriptedDiarizer: OfflineDiarizing {
    private let turns: [AudioSource: [SpeakerTurn]]
    private(set) var requests: [(file: URL, source: AudioSource, existed: Bool)] = []
    init(_ turns: [AudioSource: [SpeakerTurn]]) { self.turns = turns }
    func diarize(file: URL, source: AudioSource) async throws -> [SpeakerTurn] {
        requests.append((file, source, FileManager.default.fileExists(atPath: file.path)))
        return turns[source] ?? []
    }
}

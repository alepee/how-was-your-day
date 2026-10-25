import AVFoundation
import Foundation
import FluidAudio
import HWYDCore

actor FluidDiarizer: OfflineDiarizing {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func diarize(file: URL, source: HWYDCore.AudioSource) async throws -> [SpeakerTurn] {
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels(directory: directory)
        let result = try await manager.process(file)
        // Never serialize DiarizationResult: it also contains a speaker embedding database.
        return result.segments.map { .init(cluster: $0.speakerId, source: source, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
    }
}

enum DiarizationStage {
    static func install(directory: URL) async throws {
        ModelHub.offlineMode = false
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels(directory: directory)
    }
    static func run(_ result: TranscriptionResult, store: SessionStore, workingDirectory: URL, diagnosticURL: URL? = nil) async throws -> TranscriptionResult {
        ModelHub.offlineMode = true
        let folder = workingDirectory.appendingPathComponent("diarization-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let diarizer = FluidDiarizer(directory: store.directory.appendingPathComponent("models/diarization"))
        var turns: [SpeakerTurn] = []
        for source in [HWYDCore.AudioSource.mic, .system] {
            let chunks = result.request.chunks.filter { $0.source == source }.sorted { $0.start < $1.start }
            guard !chunks.isEmpty, result.segments.contains(where: { $0.source == source }) else { continue }
            let file = folder.appendingPathComponent("\(source.rawValue).caf")
            try assemble(chunks, store: store, destination: file)
            turns += try await diarizer.diarize(file: file, source: source)
        }
        if let diagnosticURL {
            // Explicit whitelist: never serialize FluidAudio results or voice vectors.
            let diagnostic = AlignmentDiagnostic(segments: result.segments, turns: turns.map {
                .init(cluster: $0.cluster, source: $0.source, start: $0.start, end: $0.end)
            })
            try JSONEncoder().encode(diagnostic).write(to: diagnosticURL, options: .atomic)
        }
        let aligned = SpeakerAlignment.apply(segments: result.segments, turns: turns)
        var output = result
        output.segments = aligned.segments; output.speakers = aligned.speakers
        output.diarizationEngine = "fluidaudio-0.17.7-community-1-exclusive"
        return output
    }
    static func assemble(_ chunks: [AudioChunk], store: SessionStore, destination: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        var written: Int64 = 0
        for chunk in chunks {
            guard chunk.start.isFinite, chunk.start >= 0, chunk.start + chunk.duration <= 86400 else { throw TranscriptionError.invalidAudio }
            let target = Int64((chunk.start * 16000).rounded())
            guard target >= written else { throw TranscriptionError.invalidAudio }
            // Preserve timeline gaps with silence rather than shifting all subsequent words.
            while written < target {
                buffer.frameLength = AVAudioFrameCount(min(8192, target - written))
                buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
                try output.write(from: buffer); written += Int64(buffer.frameLength)
            }
            let input = try AVAudioFile(forReading: store.audioURL(for: chunk), commonFormat: .pcmFormatFloat32, interleaved: false)
            guard input.processingFormat.sampleRate == 16000, input.processingFormat.channelCount == 1,
                  abs(Double(input.length) / 16000 - chunk.duration) <= 2.0 / 16000 else { throw TranscriptionError.invalidAudio }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { throw TranscriptionError.invalidAudio }
                try output.write(from: buffer); written += Int64(buffer.frameLength)
            }
        }
    }
}

private struct AlignmentDiagnostic: Encodable {
    var schema = 1
    var segments: [TranscriptSegment]
    var turns: [Turn]
    struct Turn: Encodable {
        var cluster: String
        var source: HWYDCore.AudioSource
        var start: Double
        var end: Double
    }
}

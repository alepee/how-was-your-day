import AVFoundation
import Foundation
import HWYDCore
import HWYDEcho

/// Disposable derived audio. Original chunks and their session timestamps never change.
struct EchoPreparation {
    var chunks: [UUID: URL] = [:]
    var microphone: URL?
    var engine: String?
}

enum EchoCancellation {
    static let engine = "speexdsp-1.2.1-mdf-residual-512ms-v2"
    static func prepare(_ request: TranscriptionRequest, store: SessionStore, directory: URL) throws -> EchoPreparation {
        let mic = request.chunks.filter { $0.source == .mic }.sorted { $0.start < $1.start }
        let system = request.chunks.filter { $0.source == .system }.sorted { $0.start < $1.start }
        guard request.echoCancellation != false, !mic.isEmpty, !system.isEmpty else { return EchoPreparation() }
        let micURL = directory.appendingPathComponent("microphone-original.caf")
        let systemURL = directory.appendingPathComponent("reference.caf")
        let outputURL = directory.appendingPathComponent("microphone-clean.caf")
        try DiarizationStage.assemble(mic, store: store, destination: micURL)
        try DiarizationStage.assemble(system, store: store, destination: systemURL)
        try process(microphone: micURL, reference: systemURL, output: outputURL)
        let input = try AVAudioFile(forReading: outputURL)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192)!
        var prepared = EchoPreparation(microphone: outputURL, engine: engine)
        for chunk in mic {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent("\(chunk.id).caf")
            let output = try AVAudioFile(forWriting: url, settings: input.processingFormat.settings)
            input.framePosition = Int64((chunk.start * 16000).rounded())
            var remaining = Int64((chunk.duration * 16000).rounded())
            while remaining > 0 {
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, remaining)))
                guard buffer.frameLength > 0 else { throw TranscriptionError.invalidAudio }
                try output.write(from: buffer); remaining -= Int64(buffer.frameLength)
            }
            prepared.chunks[chunk.id] = url
        }
        return prepared
    }

    static func process(microphone: URL, reference: URL, output: URL) throws {
        let mic = try AVAudioFile(forReading: microphone, commonFormat: .pcmFormatFloat32, interleaved: false)
        let system = try AVAudioFile(forReading: reference, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard [mic, system].allSatisfy({ $0.processingFormat.sampleRate == 16000 && $0.processingFormat.channelCount == 1 }),
              let state = hwyd_echo_create() else { throw TranscriptionError.invalidAudio }
        defer { hwyd_echo_destroy(state) }
        let file = try AVAudioFile(forWriting: output, settings: mic.processingFormat.settings)
        let micBuffer = AVAudioPCMBuffer(pcmFormat: mic.processingFormat, frameCapacity: 256)!
        let refBuffer = AVAudioPCMBuffer(pcmFormat: system.processingFormat, frameCapacity: 256)!
        let resultBuffer = AVAudioPCMBuffer(pcmFormat: mic.processingFormat, frameCapacity: 256)!
        var input = [Int16](repeating: 0, count: 256)
        var ref = input, result = input
        var processed: Int64 = 0
        var written: Int64 = 0
        // The residual suppressor uses one frame of overlap-add latency.
        // Drop that initial frame and flush the tail, preserving session timing.
        while written < mic.length {
            try Task.checkCancellation()
            micBuffer.frameLength = 0
            if mic.framePosition < mic.length { try mic.read(into: micBuffer, frameCount: 256) }
            let count = Int(micBuffer.frameLength)
            guard count > 0 || mic.framePosition == mic.length else { throw TranscriptionError.invalidAudio }
            // Align by the absolute file position, including zero-filled capture gaps.
            let position = mic.framePosition - Int64(count)
            system.framePosition = min(position, system.length)
            refBuffer.frameLength = 0
            if count > 0, system.framePosition < system.length {
                try system.read(into: refBuffer, frameCount: AVAudioFrameCount(min(Int64(count), system.length - system.framePosition)))
            }
            for i in 0..<256 {
                input[i] = i < count ? pcm(micBuffer.floatChannelData![0][i]) : 0
                ref[i] = i < Int(refBuffer.frameLength) ? pcm(refBuffer.floatChannelData![0][i]) : 0
            }
            hwyd_echo_process(state, &input, &ref, &result)
            if processed >= 256 {
                let outputCount = Int(min(256, mic.length - written))
                resultBuffer.frameLength = AVAudioFrameCount(outputCount)
                for i in 0..<outputCount { resultBuffer.floatChannelData![0][i] = Float(result[i]) / 32768 }
                try file.write(from: resultBuffer)
                written += Int64(outputCount)
            }
            processed += 256
        }
    }
    private static func pcm(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        return Int16(max(-32768, min(32767, (sample * 32768).rounded())))
    }
}

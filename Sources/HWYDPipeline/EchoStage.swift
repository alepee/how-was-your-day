import AVFoundation
import Foundation
import HWYDCore

struct EchoReport: Codable {
    var diagnosticSchema = 1
    var algorithm = "normalized-correlation-1khz-v1"
    var diagnosticOnly = true
    var recordingID: UUID
    var windows: [EchoWindow]
}

enum EchoStage {
    static func run(request: TranscriptionRequest, store: SessionStore, workingDirectory: URL) throws -> EchoReport {
        let folder = workingDirectory.appendingPathComponent("echo-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        var files: [AVAudioFile] = []
        for source in [AudioSource.mic, .system] {
            let chunks = request.chunks.filter { $0.source == source }.sorted { $0.start < $1.start }
            guard !chunks.isEmpty else { throw TranscriptionError.invalidAudio }
            let url = folder.appendingPathComponent("\(source.rawValue).caf")
            try DiarizationStage.assemble(chunks, store: store, destination: url)
            files.append(try AVAudioFile(forReading: url))
        }
        guard abs(files[0].length - files[1].length) <= 2 else { throw EchoError(message: "Durées incompatibles : \(files[0].length), \(files[1].length).") }
        var report = EchoReport(recordingID: request.recordingID, windows: [])
        var frame: Int64 = 0
        while frame < files[0].length {
            let count = Int(min(16000, files[0].length - frame))
            let mic = try read(files[0], start: frame, count: count)
            let system = try read(files[1], start: frame - 8000, count: count + 8000)
            report.windows.append(EchoDiagnostic.measure(microphone: mic, systemHistory: system, start: Double(frame) / 16000))
            frame += Int64(count)
        }
        return report
    }
    // Box averaging is a deliberately simple diagnostic decimator, not an acoustic echo canceller.
    static func read(_ file: AVAudioFile, start: Int64, count: Int) throws -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        let padding = Int(max(0, -start))
        file.framePosition = max(0, start)
        let available = min(count - padding, Int(file.length - file.framePosition))
        if available > 0 {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(available))!
            var copied = 0
            while copied < available {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(available - copied))
                guard buffer.frameLength > 0 else { throw EchoError(message: "Lecture interrompue à \(start).") }
                for index in 0..<Int(buffer.frameLength) { samples[padding + copied + index] = buffer.floatChannelData![0][index] }
                copied += Int(buffer.frameLength)
            }
        }
        return stride(from: 0, to: count - 15, by: 16).map { offset in
            samples[offset..<(offset + 16)].reduce(0, +) / 16
        }
    }
}

private struct EchoError: LocalizedError { let message: String; var errorDescription: String? { message } }

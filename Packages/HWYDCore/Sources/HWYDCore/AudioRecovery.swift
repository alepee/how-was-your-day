import AVFoundation
import Foundation

/// Called only while the store's capture lock is held. Original partial files remain untouched.
public enum AudioRecovery {
    public static func recover(in root: URL, recordingID: UUID) throws -> [AudioChunk] {
        let relative = "audio/\(recordingID.uuidString.lowercased())"
        let directory = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        func checked(_ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot) else { throw StoreError.invalidPath }
            return url
        }
        let manifest = try checked("manifest.json")
        let previous = (try? JSONDecoder().decode([AudioChunk].self, from: Data(contentsOf: manifest))) ?? []
        let descriptors = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.range(of: #"^[0-9]{6}\.json$"#, options: .regularExpression) != nil
        }.sorted()
        var chunks: [AudioChunk] = []
        var skipped: [String] = []
        for descriptorName in descriptors {
            do {
                let descriptor = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: checked(descriptorName)))
                guard let frameText = descriptor["start_frames"], let startFrames = Int64(frameText), startFrames >= 0 else { throw TranscriptionError.invalidAudio }
                let sequence = String(descriptorName.prefix(6))
                var pair: [AudioChunk] = []
                for source in [AudioSource.mic, .system] {
                    let finalName = "\(source.rawValue)-\(sequence).caf"
                    let final = try checked(finalName)
                    let exists = FileManager.default.fileExists(atPath: final.path)
                    let input = try AVAudioFile(forReading: exists ? final : checked("\(source.rawValue)-\(sequence).partial.caf"))
                    guard input.length > 0, input.processingFormat.sampleRate == 16000, input.processingFormat.channelCount == 1 else { throw TranscriptionError.invalidAudio }
                    if !exists {
                        let staging = try checked(".recovery-\(UUID().uuidString).caf")
                        do {
                            // A successfully decoded, bounded PCM copy seals a readable partial CAF.
                            var output: AVAudioFile? = try AVAudioFile(forWriting: staging, settings: input.processingFormat.settings)
                            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192)!
                            var read: Int64 = 0
                            while read < input.length {
                                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, input.length - read)))
                                guard buffer.frameLength > 0 else { throw TranscriptionError.invalidAudio }
                                try output?.write(from: buffer); read += Int64(buffer.frameLength)
                            }
                            output = nil
                            let handle = try FileHandle(forWritingTo: staging); try handle.synchronize(); try handle.close()
                            try FileManager.default.moveItem(at: staging, to: final)
                        } catch { try? FileManager.default.removeItem(at: staging); throw error }
                    }
                    let path = relative + "/" + finalName
                    pair.append(.init(id: previous.first(where: { $0.relativePath == path })?.id ?? UUID(), source: source,
                                      relativePath: path, start: Double(startFrames) / 16000, duration: Double(input.length) / 16000))
                }
                guard pair.count == 2, pair[0].duration == pair[1].duration else { throw TranscriptionError.invalidAudio }
                chunks += pair
            } catch { skipped.append(descriptorName) }
        }
        // No descriptor means an older manifest may still be the only recovery source.
        if descriptors.isEmpty { return previous }
        try JSONEncoder().encode(chunks).write(to: manifest, options: .atomic)
        try JSONEncoder().encode(skipped).write(to: checked("recovery-skipped.json"), options: .atomic)
        return chunks
    }
}

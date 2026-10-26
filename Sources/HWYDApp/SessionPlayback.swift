import AVFoundation
import CryptoKit
import HWYDCore

/// Both tracks share one engine and one host-clock start. CAF boundaries are scheduled ahead.
@MainActor final class SessionPlayback {
    private var engine = AVAudioEngine()
    private var nodes: [AudioSource: AVAudioPlayerNode] = [:]
    private var files: [AVAudioFile] = []
    private var startHostTime: UInt64 = 0
    private var offset: Double = 0
    private var end: Double = 0
    private(set) var running = false

    var position: Double {
        guard running else { return offset }
        let now = mach_absolute_time()
        return min(end, offset + (now > startHostTime ? AVAudioTime.seconds(forHostTime: now - startHostTime) : 0))
    }
    func start(chunks: [AudioChunk], store: SessionStore, at time: Double, duration: Double, offline: Bool = false) throws {
        stop()
        engine = AVAudioEngine()
        offset = time; end = duration
        do {
            for source in [AudioSource.mic, .system] {
                let track = chunks.filter { $0.source == source && $0.start + $0.duration > time }.sorted { $0.start < $1.start }
                guard !track.isEmpty else { continue }
                let node = AVAudioPlayerNode()
                engine.attach(node); nodes[source] = node
                var connected = false
                for chunk in track {
                    let file = try AVAudioFile(forReading: store.audioURL(for: chunk))
                    let rate = file.processingFormat.sampleRate
                    if !connected {
                        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
                        connected = true
                    }
                    let first = AVAudioFramePosition(max(0, time - chunk.start) * rate)
                    let count = min(file.length, AVAudioFramePosition(chunk.duration * rate)) - first
                    guard count > 0 else { continue }
                    files.append(file)
                    let scheduled = AVAudioTime(sampleTime: AVAudioFramePosition(max(0, chunk.start - time) * rate), atRate: rate)
                    node.scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(count), at: scheduled)
                }
            }
            guard !files.isEmpty else { throw PlaybackError.unavailable }
            // Headroom when summing the two raw signals.
            engine.mainMixerNode.outputVolume = 0.5
            if offline {
                try engine.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!, maximumFrameCount: 4096)
            }
            try engine.start()
            startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08)
            let start = AVAudioTime(hostTime: startHostTime)
            for node in nodes.values { node.play(at: offline ? nil : start) }
            running = true
        } catch { stop(); throw error }
    }
    func renderForTesting(frames: AVAudioFrameCount) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        guard try engine.renderOffline(frames, to: buffer) == .success else { throw PlaybackError.unavailable }
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    func setAudible(_ source: AudioSource, _ audible: Bool) { nodes[source]?.volume = audible ? 1 : 0 }
    func stop() {
        if running { offset = position }
        running = false
        for node in nodes.values { node.stop() }
        engine.stop()
        if engine.isInManualRenderingMode { engine.disableManualRenderingMode() }
        for node in nodes.values { engine.detach(node) }
        nodes.removeAll(); files.removeAll()
    }
    enum PlaybackError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Aucun audio disponible à cet instant." }
    }
}

struct TrackEnvelope: Codable, Sendable {
    var peaks: [Float]
    var available: Bool
}

/// Reads bounded PCM buffers away from the UI. Values are actual peaks, not decorative bars.
actor WaveformReader {
    private struct Cached: Codable {
        var key: String
        var envelopes: [AudioSource: TrackEnvelope]
    }
    private var memory: [String: [AudioSource: TrackEnvelope]] = [:]
    private(set) var cacheHits = 0
    func read(chunks: [AudioChunk], store: SessionStore, duration: Double, bins: Int = 600) throws -> [AudioSource: TrackEnvelope] {
        guard duration.isFinite, duration > 0, bins > 0, bins <= 10000 else { return [:] }
        var identity = "waveform-v1|\(duration)|\(bins)"
        for chunk in chunks {
            let url = try store.audioURL(for: chunk)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            identity += "|\(url.path)|\(chunk.start)|\(chunk.duration)|\(attributes[.size] ?? 0)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let value = memory[key] { cacheHits += 1; return value }
        let directory = store.directory.appendingPathComponent("cache/waveforms")
        let file = directory.appendingPathComponent("\(chunks.first?.id.uuidString ?? "empty")-\(bins).json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Cached.self, from: data), cached.key == key {
            remember(cached.envelopes, key: key); cacheHits += 1; return cached.envelopes
        }
        var result: [AudioSource: TrackEnvelope] = [:]
        for source in [AudioSource.mic, .system] {
            var peaks = [Float](repeating: 0, count: bins)
            var available = false
            for chunk in chunks where chunk.source == source {
                try Task.checkCancellation()
                let file = try AVAudioFile(forReading: store.audioURL(for: chunk))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { continue }
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let first = file.framePosition
                    try file.read(into: buffer)
                    guard buffer.frameLength > 0, let samples = buffer.floatChannelData else { break }
                    available = true
                    let rate = file.processingFormat.sampleRate
                    let channels = Int(buffer.format.channelCount)
                    let scale = Double(bins) / duration
                    for frame in 0..<Int(buffer.frameLength) {
                        let bin = Int((chunk.start + Double(first + Int64(frame)) / rate) * scale)
                        guard bin >= 0 && bin < bins else { continue }
                        for channel in 0..<channels {
                            peaks[bin] = max(peaks[bin], abs(samples[channel][frame]))
                        }
                    }
                }
            }
            result[source] = TrackEnvelope(peaks: peaks, available: available)
        }
        try Task.checkCancellation()
        remember(result, key: key)
        // A full cache or read-only disk must not prevent playback.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(Cached(key: key, envelopes: result)) { try? data.write(to: file, options: .atomic) }
        return result
    }
    private func remember(_ value: [AudioSource: TrackEnvelope], key: String) {
        if memory.count >= 8 { memory.removeAll(keepingCapacity: true) }
        memory[key] = value
    }
}

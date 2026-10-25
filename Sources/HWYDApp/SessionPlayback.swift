import AVFoundation
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

struct TrackEnvelope: Sendable {
    var peaks: [Float]
    var available: Bool
}

/// Reads bounded PCM buffers away from the UI. Values are actual peaks, not decorative bars.
actor WaveformReader {
    func read(chunks: [AudioChunk], store: SessionStore, duration: Double, bins: Int = 600) throws -> [AudioSource: TrackEnvelope] {
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
                    for frame in 0..<Int(buffer.frameLength) {
                        let time = chunk.start + Double(first + Int64(frame)) / file.processingFormat.sampleRate
                        let bin = Int(time / max(duration, 0.001) * Double(bins))
                        guard bin >= 0 && bin < bins else { continue }
                        for channel in 0..<Int(buffer.format.channelCount) {
                            peaks[bin] = max(peaks[bin], abs(samples[channel][frame]))
                        }
                    }
                }
            }
            result[source] = TrackEnvelope(peaks: peaks, available: available)
        }
        return result
    }
}

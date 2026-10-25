import AVFoundation
import HWYDCore

@MainActor enum PlaybackChecks {
    static func run(directory: URL) async throws {
        let store = try SessionStore(directory: directory)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        func chunk(_ name: String, _ source: AudioSource, _ start: Double, _ value: Float) throws -> AudioChunk {
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            for i in 0..<1600 { buffer.floatChannelData![0][i] = value * (i % 2 == 0 ? 1 : -1) }
            try file.write(from: buffer)
            return AudioChunk(source: source, relativePath: name, start: start, duration: 0.1)
        }
        // Unequal starts, a missing interval, and a CAF boundary. No hardware output.
        let chunks = try [chunk("mic1.caf", .mic, 0, 0.2), chunk("mic2.caf", .mic, 0.1, 0.2), chunk("sys.caf", .system, 0.1, 0.4)]
        let playback = SessionPlayback()
        try playback.start(chunks: chunks, store: store, at: 0, duration: 0.3, offline: true)
        let samples = try playback.renderForTesting(frames: 4096)
        func magnitude(_ samples: [Float], _ index: Int, _ expected: Float) throws {
            guard abs(abs(samples[index]) - expected) < 0.005 else {
                throw CaptureFailure(message: "Playback sample \(index): \(samples[index]), expected magnitude \(expected)")
            }
        }
        try magnitude(samples, 800, 0.1)
        try magnitude(samples, 2400, 0.3)
        try magnitude(samples, 3800, 0)
        playback.stop()
        try playback.start(chunks: chunks, store: store, at: 0.15, duration: 0.3, offline: true)
        playback.setAudible(.system, false)
        let muted = try playback.renderForTesting(frames: 512)
        try magnitude(muted, 400, 0.1)
        playback.setAudible(.system, true)
        playback.setAudible(.mic, false)
        let solo = try playback.renderForTesting(frames: 256)
        try magnitude(solo, 200, 0.2)
        playback.stop()
        let envelopes = try await WaveformReader().read(chunks: chunks, store: store, duration: 0.3, bins: 3)
        guard envelopes[.mic]?.peaks == [0.2, 0.2, 0], envelopes[.system]?.peaks == [0, 0.4, 0] else {
            throw CaptureFailure(message: "Waveform alignment failed")
        }
        let model = AppModel(directory: directory, appliesAppearance: false)
        guard model.isTrackAudible(.mic), model.isTrackAudible(.system) else { throw CaptureFailure(message: "Default mix failed") }
        model.toggleSolo(.mic)
        guard model.isTrackAudible(.mic), !model.isTrackAudible(.system) else { throw CaptureFailure(message: "Solo failed") }
        model.toggleMute(.mic)
        guard !model.isTrackAudible(.mic) else { throw CaptureFailure(message: "Mute must override solo") }
        model.toggleSolo(.system)
        guard model.isTrackAudible(.system) else { throw CaptureFailure(message: "Multi-solo failed") }
        print("Offline playback: synchronized mix, CAF boundary, gap, seek, mute, solo and real waveforms: PASS")
    }
}

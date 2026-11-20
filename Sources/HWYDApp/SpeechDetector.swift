import AVFoundation
import Foundation
import SoundAnalysis

/// Tells whether someone speaks in the captured audio, with the sound classifier built into macOS
/// (SoundAnalysis, on device, nothing downloaded or sent). The capture uses it to notice a session
/// in which nobody speaks any more (`CaptureEvent.speech`); nothing it hears is stored.
///
/// Each track has its own analyzer: the microphone and the system audio of a call. The writer
/// hands it the 16 kHz mono samples it already converted, never from the realtime callback;
/// the analysis runs on its own queue so the writer is never held up.
final class SpeechDetector: @unchecked Sendable {
    /// Sounds of the classifier that count as someone speaking.
    private static let speechLabels = ["speech", "whispering", "shout", "yell"]
    /// Confidence above which a window holds speech. The classifier gives 0.8 to 0.95 to plain
    /// speech and under 0.05 to silence.
    private static let confidence = 0.5
    private let queue = DispatchQueue(label: "dev.lepee.hwyd.speech-detector", qos: .utility)
    private let format: AVAudioFormat
    private var analyzers: [SNAudioStreamAnalyzer] = []
    private var positions: [AVAudioFramePosition] = [0, 0]
    private let observer = Observer()

    /// Nil when the classifier is not available: the capture then never reports speech.
    init?(sampleRate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
        self.format = format
        do {
            for _ in 0..<2 {
                let analyzer = SNAudioStreamAnalyzer(format: format)
                try analyzer.add(try SNClassifySoundRequest(classifierIdentifier: .version1), withObserver: observer)
                analyzers.append(analyzer)
            }
        } catch { return nil }
    }

    /// How many windows held speech so far; the caller compares it with its last reading.
    var heard: Int { observer.heard }

    /// Analyzes samples of `track` (0 microphone, 1 system audio), in order.
    func listen(track: Int, samples: [Float]) {
        guard !samples.isEmpty, analyzers.indices.contains(track) else { return }
        queue.async { [self] in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            analyzers[track].analyze(buffer, atAudioFramePosition: positions[track])
            positions[track] += AVAudioFramePosition(samples.count)
        }
    }

    /// Stops the analysis; what is still queued is dropped.
    func finish() {
        queue.sync { analyzers.forEach { $0.removeAllRequests() }; analyzers = [] }
    }

    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var heard: Int { lock.withLock { count } }
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let speaks = SpeechDetector.speechLabels.contains { (result.classification(forIdentifier: $0)?.confidence ?? 0) >= SpeechDetector.confidence }
            if speaks { lock.withLock { count += 1 } }
        }
    }
}

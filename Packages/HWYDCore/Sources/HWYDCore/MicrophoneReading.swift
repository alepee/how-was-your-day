import Foundation

/// How the capture turns the microphone channels it receives into one track.
///
/// While a call app uses macOS voice processing on the built-in microphone, macOS exposes that microphone as its raw
/// capsules, several channels about 35 dB below the processed microphone it normally delivers as one channel. The
/// other apps then record almost nothing. Their average, raised by `capsuleGain`, brings the voice back to its usual
/// level. Measured on a MacBook Pro: 3 channels during FaceTime and Google Meet (Chrome, Safari, Firefox), 1 otherwise.
/// An external microphone keeps its format and its first channel is recorded as before, and so does any other built-in
/// input with several channels of its own (a line input, the stereo microphone of some Intel Macs).
public enum MicrophoneReading: Equatable, Sendable {
    /// The first channel, as is.
    case firstChannel
    /// The average of every channel, multiplied by `gain` and limited to full scale.
    case capsules(gain: Float)

    /// +38 dB.
    public static let capsuleGain: Float = 79.4
    /// The Core Audio UID of the built-in microphone of Apple silicon Macs, as macOS reports it. Other built-in inputs
    /// have their own UID.
    public static let builtInMicrophoneUID = "BuiltInMicrophoneDevice"

    /// The capsules are read only when all three hold: the Mac's own microphone, several channels, and another app
    /// reading audio input, since only a call app's voice processing exposes them.
    /// - Parameters:
    ///   - uid: the microphone's Core Audio UID.
    ///   - channels: the channels the microphone exposes now.
    ///   - othersReading: another process reads audio input now.
    public init(uid: String, channels: Int, othersReading: Bool) {
        self = uid == Self.builtInMicrophoneUID && channels > 1 && othersReading ? .capsules(gain: Self.capsuleGain) : .firstChannel
    }

    /// One frame of the microphone, `channels` interleaved samples starting at `frame`.
    public func sample(_ frame: UnsafePointer<Float>, channels: Int) -> Float {
        switch self {
        case .firstChannel:
            return frame[0]
        case .capsules(let gain):
            var sum: Float = 0
            for channel in 0..<channels { sum += frame[channel] }
            return max(-1, min(1, sum / Float(channels) * gain))
        }
    }
}

/// Buffers the realtime callback could not queue, by reason, as counted by the capture's ring.
public struct CaptureDrops: Equatable, Sendable {
    /// A buffer had more channels than the ring.
    public var overflow: UInt64
    /// Buffers of one delivery disagreed on their frame count.
    public var inconsistent: UInt64
    /// A buffer had no frame, or more than the ring holds.
    public var frameSize: UInt64
    /// The writer fell behind and the ring was full.
    public var full: UInt64
    /// A buffer had fewer channels than the ring.
    public var fewerChannels: UInt64

    public init(overflow: UInt64 = 0, inconsistent: UInt64 = 0, frameSize: UInt64 = 0, full: UInt64 = 0, fewerChannels: UInt64 = 0) {
        self.overflow = overflow; self.inconsistent = inconsistent; self.frameSize = frameSize; self.full = full; self.fewerChannels = fewerChannels
    }

    public var isEmpty: Bool { overflow + inconsistent + frameSize + full + fewerChannels == 0 }

    /// The device changed its channel count: a call app took or released the built-in microphone. The graph is
    /// built again on the new format instead of stopping the session. Any other loss still stops it, so a real
    /// desynchronization is never hidden.
    public var isFormatChange: Bool { overflow + fewerChannels > 0 && inconsistent == 0 && frameSize == 0 && full == 0 }

    /// As shown in the error message, in the ring's order: overflow/inconsistent/frame size/full/fewer channels.
    public var summary: String { "\(overflow)/\(inconsistent)/\(frameSize)/\(full)/\(fewerChannels)" }
}

/// Limits how often the capture builds its graph again for a format change: a device that keeps changing, or a
/// format that never settles, stops the session instead of leaving gaps in a loop.
public struct FormatRebuildBudget: Sendable {
    /// Rebuilds allowed within `window`. Joining then leaving a call costs two.
    public static let limit = 4
    public static let window: TimeInterval = 10

    private var times: [TimeInterval] = []

    public init() {}

    /// - Parameter now: a monotonic time in seconds.
    /// - Returns: false when this rebuild would exceed the budget; it is then not counted.
    public mutating func allow(now: TimeInterval) -> Bool {
        times.removeAll { now - $0 >= Self.window }
        guard times.count < Self.limit else { return false }
        times.append(now)
        return true
    }
}

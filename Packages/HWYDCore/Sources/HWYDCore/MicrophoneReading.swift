import Foundation

/// How the capture turns the microphone channels it receives into one track.
///
/// While a call app uses macOS voice processing on the built-in microphone, macOS exposes that microphone as its raw
/// capsules, several channels about 35 dB below the processed microphone it normally delivers as one channel. The
/// other apps then record almost nothing. Their average, raised by `capsuleGain`, brings the voice back to its usual
/// level. Measured on a MacBook Pro: 3 channels during FaceTime and Google Meet (Chrome, Safari, Firefox), 1 otherwise.
/// An external microphone keeps its format and its first channel is recorded as before.
public enum MicrophoneReading: Equatable, Sendable {
    /// The first channel, as is.
    case firstChannel
    /// The average of every channel, multiplied by `gain` and limited to full scale.
    case capsules(gain: Float)

    /// +38 dB.
    public static let capsuleGain: Float = 79.4

    /// - Parameters:
    ///   - builtIn: the microphone is the Mac's own (`kAudioDeviceTransportTypeBuiltIn`).
    ///   - channels: the channels the microphone exposes now.
    public init(builtIn: Bool, channels: Int) {
        self = builtIn && channels > 1 ? .capsules(gain: Self.capsuleGain) : .firstChannel
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
    /// A buffer had fewer channels than the ring, or an unexpected frame count.
    public var layout: UInt64
    /// The writer fell behind and the ring was full.
    public var full: UInt64

    public init(overflow: UInt64 = 0, inconsistent: UInt64 = 0, layout: UInt64 = 0, full: UInt64 = 0) {
        self.overflow = overflow; self.inconsistent = inconsistent; self.layout = layout; self.full = full
    }

    public var isEmpty: Bool { overflow + inconsistent + layout + full == 0 }

    /// The device changed its channel count: a call app took or released the built-in microphone. The graph is
    /// built again on the new format instead of stopping the session. Any other loss still stops it, so a real
    /// desynchronization is never hidden.
    public var isFormatChange: Bool { overflow + layout > 0 && inconsistent == 0 && full == 0 }

    /// As shown in the error message: overflow/inconsistent/layout/full.
    public var summary: String { "\(overflow)/\(inconsistent)/\(layout)/\(full)" }
}

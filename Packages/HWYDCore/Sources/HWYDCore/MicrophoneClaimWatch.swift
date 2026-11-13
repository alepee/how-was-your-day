import Foundation

/// Decides when the capture should restart its microphone stream because another app started reading audio input.
///
/// A meeting app that opens the microphone after the capture started may switch on voice processing and reconfigure
/// the input device. The stream that was already running then keeps delivering the microphone about 30 dB lower,
/// until it is stopped and started again. The watch compares the processes reading input at each poll with the
/// previous poll and asks for one restart once a newcomer had time to settle.
public struct MicrophoneClaimWatch: Sendable {
    /// Lets the newcomer finish setting up its audio graph before the stream restarts.
    public static let settleDelay: TimeInterval = 1.5
    /// An app that toggles its input on every mute must not restart the stream in a loop.
    public static let minimumInterval: TimeInterval = 10

    private var known: Set<Int32>
    private var due: TimeInterval?
    private var lastRestart: TimeInterval?

    /// - Parameter readers: the other processes already reading audio input when the capture started.
    public init(readers: Set<Int32>) { known = readers }

    /// - Parameters:
    ///   - readers: the other processes reading audio input now, the capture's own process excluded.
    ///   - now: a monotonic time in seconds.
    /// - Returns: true when the microphone stream should restart now.
    public mutating func poll(readers: Set<Int32>, now: TimeInterval) -> Bool {
        // A process that stops reading and starts again counts as a newcomer again.
        if !readers.subtracting(known).isEmpty, due == nil { due = now + Self.settleDelay }
        known = readers
        guard let due, now >= due else { return false }
        if let lastRestart, now - lastRestart < Self.minimumInterval {
            self.due = lastRestart + Self.minimumInterval
            return false
        }
        self.due = nil
        lastRestart = now
        return true
    }

    /// A manual pause and resume already restarts the stream: a pending restart is no longer needed.
    public mutating func reset(readers: Set<Int32>) {
        known = readers
        due = nil
    }
}

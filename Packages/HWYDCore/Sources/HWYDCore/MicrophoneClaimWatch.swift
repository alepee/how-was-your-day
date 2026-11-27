import Foundation

/// Decides when the capture should restart its microphone stream because another app reads audio input.
///
/// A meeting app with voice processing may reconfigure the input device. The stream that was already running then
/// keeps delivering the microphone about 30 dB lower, until it is stopped and started again. Two moments call for one
/// restart once the other app had time to settle:
/// - an app starts reading input after the capture started: the watch compares the processes reading input at each
///   poll with the previous poll;
/// - an app already reads input when the capture builds its graph: creating the capture's aggregate device changes
///   the device list, and the meeting app may set up its voice processing again under the same process, before the
///   capture can see it. Observed with Google Meet on the MacBook microphone: the whole session stayed 23 dB lower.
public struct MicrophoneClaimWatch: Sendable {
    /// Lets the other app finish setting up its audio graph before the stream restarts.
    public static let settleDelay: TimeInterval = 1.5
    /// An app that toggles its input on every mute must not restart the stream in a loop.
    public static let minimumInterval: TimeInterval = 10

    private var known: Set<Int32>
    private var due: TimeInterval?
    private var lastRestart: TimeInterval?

    /// The capture just built its graph and its stream runs.
    /// - Parameters:
    ///   - readers: the other processes reading audio input now, the capture's own process excluded.
    ///   - now: a monotonic time in seconds.
    public init(readers: Set<Int32>, now: TimeInterval) {
        known = []
        graphBuilt(readers: readers, now: now)
    }

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

    /// The capture built a new graph (a new aggregate device) and its stream runs: an app already reading input
    /// may set up its voice processing again, so one restart is due once it settled.
    public mutating func graphBuilt(readers: Set<Int32>, now: TimeInterval) {
        known = readers
        due = readers.isEmpty ? nil : now + Self.settleDelay
    }

    /// The stream restarted on the same graph (a manual pause and resume, or a claim restart): a pending restart is
    /// no longer needed.
    public mutating func reset(readers: Set<Int32>) {
        known = readers
        due = nil
    }
}

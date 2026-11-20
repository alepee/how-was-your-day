import Foundation
import Synchronization

/// A clock that moves only when a check advances it, so a check decides when time passes
/// instead of waiting for it. A sleeper wakes once the clock reaches its deadline; a sleeper whose
/// deadline is already past returns at once. Cancelling a sleeper wakes it with `CancellationError`.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }
    private struct Sleeper { let deadline: Instant; let continuation: CheckedContinuation<Void, any Error> }
    private struct State { var now = Instant(offset: .zero); var sleepers: [UUID: Sleeper] = [:] }
    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    /// The clock's time in seconds, for the capture clock.
    var seconds: TimeInterval {
        let offset = now.offset.components
        return TimeInterval(offset.seconds) + TimeInterval(offset.attoseconds) / 1e18
    }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let ready: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock forward and wakes the sleepers whose deadline it reached.
    func advance(by duration: Duration) {
        let woken = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in due.keys { state.sleepers[id] = nil }
            return Array(due.values)
        }
        for sleeper in woken { sleeper.continuation.resume() }
    }
}

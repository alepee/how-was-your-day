import Foundation

/// When a capture in which nobody speaks asks whether the user is done, and when it stops.
/// Speech on either track counts: the microphone or the system audio of a call.
public struct InactivityPolicy: Equatable, Sendable {
    /// Time without speech before asking.
    public var silence: TimeInterval
    /// Time left to answer before the capture stops.
    public var countdown: TimeInterval
    public init(silence: TimeInterval, countdown: TimeInterval) { self.silence = silence; self.countdown = countdown }
    public static let standard = InactivityPolicy(silence: 5 * 60, countdown: 2 * 60)
}

/// The question a capture without speech asks: « Vous avez fini ? ». Without an answer, the
/// capture stops at `stopsAt`. Speech coming back, or the user answering « Pas encore », withdraws it.
public struct InactivityPrompt: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// How long nobody had spoken when the capture asked.
    public var silence: TimeInterval
    /// Wall-clock time the capture stops without an answer.
    public var stopsAt: Date
    public init(silence: TimeInterval, stopsAt: Date) { self.silence = silence; self.stopsAt = stopsAt }
}

/// Counts the time since speech was last heard and tells when to ask and when to stop. Pure: the
/// caller gives a monotonic time.
struct InactivityWatch {
    enum Step: Equatable {
        case none
        /// Nobody spoke for `silence` seconds: ask, the capture stops after the countdown.
        case ask(silence: TimeInterval)
        /// The countdown ran out, `silence` seconds after speech was last heard.
        case stop(silence: TimeInterval)
    }
    let policy: InactivityPolicy
    private var lastSpeech: TimeInterval
    private var askedAt: TimeInterval?

    init(policy: InactivityPolicy, at now: TimeInterval) { self.policy = policy; lastSpeech = now }

    var isAsking: Bool { askedAt != nil }

    /// Counts again from `now`: speech was heard, the capture resumed, or the user answered.
    mutating func reset(at now: TimeInterval) { lastSpeech = now; askedAt = nil }

    /// Where the count stands at `now`.
    mutating func check(at now: TimeInterval) -> Step {
        if let askedAt { return now - askedAt >= policy.countdown ? .stop(silence: now - lastSpeech) : .none }
        guard now - lastSpeech >= policy.silence else { return .none }
        askedAt = now
        return .ask(silence: now - lastSpeech)
    }
}

import Foundation

/// Records the two tracks of one session: the microphone and system audio. An instance serves
/// one capture, from `start` to `stop`. The app's adapter, `CoreAudioCapture`, drives the Core
/// Audio graph on its own serial queue; `SimulatedCapture` stands in for demo mode, previews and
/// tests and never opens a device.
///
/// While the capture runs, `events` reports meter levels, restarts of the microphone stream and
/// the fault that ends the capture. The stream finishes once `stop` returns.
public protocol AudioCapture: Sendable {
    /// A simulation records no audio: its sessions are examples and are never transcribed.
    var isSimulated: Bool { get }
    var events: AsyncStream<CaptureEvent> { get }
    /// Returns once audio flows. Throws, with a message for the user, when the capture cannot
    /// start; nothing is left running then.
    func start(session id: UUID) async throws
    /// Stops the devices without ending the session. The audio timeline skips the pause.
    func pause() async
    func resume() async throws
    /// Stops the devices and seals what was recorded.
    func stop() async -> CapturedAudio
}

/// What a running capture reports.
public enum CaptureEvent: Equatable, Sendable {
    /// Peak levels of the microphone and system audio, from 0 to 1, a few times per second.
    case levels(mic: Float, system: Float)
    /// The microphone stream is about to restart, for instance because a meeting app switched on
    /// voice processing after the capture started. Like a pause, the restart is left out of the
    /// audio timeline.
    case restarting
    /// The stream runs again. `gap` is how long it stood still, in seconds.
    case restarted(gap: TimeInterval)
    /// The capture cannot go on. The session must stop; what was recorded so far is kept.
    case failed(CaptureFault)
}

/// Why a running capture cannot go on.
public struct CaptureFault: LocalizedError, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The devices stopped delivering audio.
        case stalled
        /// The default input or output device changed. The graph is not rebuilt: the session
        /// stops so that both tracks keep the device they started with.
        case routeChanged
        /// Buffers were lost, or the audio could not be written.
        case writer
        /// The microphone stream could not restart.
        case restart
    }
    public var kind: Kind
    /// Said to the user as is.
    public var message: String
    public init(_ kind: Kind, message: String) { self.kind = kind; self.message = message }
    public var errorDescription: String? { message }
}

/// The audio a capture sealed when it stopped.
public struct CapturedAudio: Equatable, Sendable {
    public var chunks: [AudioChunk]
    /// Set when the last chunks could not be sealed; the session is then interrupted.
    public var finalizationError: String?
    public init(chunks: [AudioChunk] = [], finalizationError: String? = nil) {
        self.chunks = chunks; self.finalizationError = finalizationError
    }
}

/// A capture that opens no device. In demo mode it animates the meters; tests set what `stop`
/// returns, make `start` fail and send the events a device would.
public actor SimulatedCapture: AudioCapture {
    public nonisolated let isSimulated: Bool
    public nonisolated let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let audio: CapturedAudio
    private let startFailure: (any Error & Sendable)?
    private let animatesLevels: Bool
    public private(set) var session: UUID?
    public private(set) var isPaused = false
    public private(set) var isStopped = false
    /// Active time, paused time left out, that drives the meters.
    private var banked: Duration = .zero
    private var runningSince: ContinuousClock.Instant?
    private var animation: Task<Void, Never>?

    /// - Parameters:
    ///   - animatesLevels: sends moving levels five times per second, as demo mode shows them.
    ///   - simulated: false lets a test stand in for a real capture, whose sessions are transcribed.
    public init(animatesLevels: Bool = true, simulated: Bool = true, audio: CapturedAudio = CapturedAudio(),
                startFailure: (any Error & Sendable)? = nil) {
        (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
        isSimulated = simulated
        self.audio = audio; self.startFailure = startFailure; self.animatesLevels = animatesLevels
    }

    public func start(session id: UUID) async throws {
        if let startFailure { continuation.finish(); throw startFailure }
        session = id
        runningSince = .now
        guard animatesLevels else { return }
        animation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                await self?.animate()
            }
        }
    }
    public func pause() async {
        guard !isPaused, !isStopped, let runningSince else { return }
        banked += runningSince.duration(to: .now); self.runningSince = nil
        isPaused = true
    }
    public func resume() async throws {
        guard isPaused, !isStopped else { return }
        runningSince = .now; isPaused = false
    }
    public func stop() async -> CapturedAudio {
        animation?.cancel(); animation = nil
        isStopped = true
        continuation.finish()
        return audio
    }
    /// Sends an event as the hardware would.
    public nonisolated func emit(_ event: CaptureEvent) { continuation.yield(event) }

    private func animate() {
        guard !isPaused, !isStopped, let runningSince else { return }
        let parts = (banked + runningSince.duration(to: .now)).components
        let elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        continuation.yield(.levels(mic: Float((sin(elapsed * 2.2) + 1) * 0.3 + 0.05), system: Float((sin(elapsed * 1.6) + 1) * 0.16)))
    }
}

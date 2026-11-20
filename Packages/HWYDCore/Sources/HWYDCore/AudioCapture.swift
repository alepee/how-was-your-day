import Foundation

/// Records the two tracks of one session: the microphone and system audio. An instance serves
/// one capture, from `start` to `stop`. The app's adapter, `CoreAudioCapture`, drives the Core
/// Audio graph on its own serial queue; `SimulatedCapture` stands in for demo mode, previews and
/// tests and never opens a device.
///
/// The capture records a chosen microphone. It detects the devices and rebuilds its graph; the
/// session decides what to do about them (`CaptureSession`): a new system default input is only
/// offered, the microphone changes when the session asks (`switchMicrophone`), and a microphone
/// that disappears is reported for the session to replace.
///
/// While the capture runs, `events` reports meter levels, devices, restarts of the stream and
/// the fault that ends the capture. The stream finishes once `stop` returns.
public protocol AudioCapture: Sendable {
    /// A simulation records no audio: its sessions are examples and are never transcribed.
    var isSimulated: Bool { get }
    var events: AsyncStream<CaptureEvent> { get }
    /// Returns once audio flows. Throws, with a message for the user, when the capture cannot
    /// start; nothing is left running then. `continuation` says where the chunks go on the
    /// session's timeline and which file number they start from: `.start` for a new session,
    /// after the earlier audio when recording resumes in a session that ended. `microphone` is the
    /// UID of the input to record; nil, or a device that is not present, records the system
    /// default input.
    func start(session id: UUID, continuing continuation: CaptureContinuation, microphone: String?) async throws
    /// The input device the running capture records, nil when unknown.
    var microphone: MicrophoneDevice? { get async }
    /// The input devices present and the system default input, as the capture last read them.
    var microphones: MicrophoneList { get async }
    /// Records `uid` from now on. The graph is rebuilt between `restarting` and `restarted(gap:)`,
    /// then `microphoneSwitched` follows, so that the session dates the boundary on its corrected
    /// clock; the gap is left out of the audio timeline and the chunks keep their sequence. When the new microphone cannot start, the capture goes back to
    /// the previous one if it is still there and throws; when neither runs, it reports
    /// `CaptureFault.restart` and throws.
    func switchMicrophone(to uid: String, reason: MicrophoneSwitchReason) async throws
    /// Stops the devices without ending the session. The audio timeline skips the pause. A restart
    /// in progress ends with `restarted(gap:)` first: the pause is not part of its gap.
    func pause() async
    func resume() async throws
    /// Stops the devices and seals what was recorded.
    func stop() async -> CapturedAudio
}

extension AudioCapture {
    /// Starts a new session on the system default input.
    public func start(session id: UUID) async throws { try await start(session: id, continuing: .start, microphone: nil) }
    public func start(session id: UUID, continuing continuation: CaptureContinuation) async throws {
        try await start(session: id, continuing: continuation, microphone: nil)
    }
}

/// What a running capture reports.
public enum CaptureEvent: Equatable, Sendable {
    /// Peak levels of the microphone and system audio, from 0 to 1, a few times per second.
    case levels(mic: Float, system: Float)
    /// Someone spoke, on the microphone or in the system audio, since the previous report.
    case speech
    /// The microphone stream is about to restart, for instance because a meeting app switched on
    /// voice processing after the capture started. Like a pause, the restart is left out of the
    /// audio timeline.
    case restarting
    /// The stream runs again. `gap` is how long it stood still, in seconds. It can start before
    /// `restarting`: a microphone that disappears is noticed after its last buffer.
    case restarted(gap: TimeInterval)
    /// The input devices or the system default input changed.
    case microphonesChanged(MicrophoneList)
    /// The system default input moved to this device, which the capture does not record. Only an
    /// offer: the capture keeps its microphone until the session asks for a switch.
    case microphoneOffered(MicrophoneDevice)
    /// The microphone recorded disappeared. The stream stands still, between `restarting` and the
    /// `restarted(gap:)` of the next switch, until the session switches or stops.
    case microphoneLost(MicrophoneDevice)
    /// The capture records this microphone from now on. Sent right after `restarted(gap:)`, or
    /// alone while paused.
    case microphoneSwitched(MicrophoneDevice, reason: MicrophoneSwitchReason)
    /// The capture cannot go on. The session must stop; what was recorded so far is kept.
    case failed(CaptureFault)
}

/// Why a running capture cannot go on.
public struct CaptureFault: LocalizedError, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The devices stopped delivering audio.
        case stalled
        /// No input device is left. The session can be resumed once a microphone is back.
        case noMicrophone
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
/// returns, make `start` fail and send the events a device would, including microphones that
/// appear, are offered or disappear. The chunks `stop` returns are placed after the
/// continuation's offset, as a device would write them.
public actor SimulatedCapture: AudioCapture {
    public nonisolated let isSimulated: Bool
    public nonisolated let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let audio: CapturedAudio
    private let startFailure: (any Error & Sendable)?
    private let animatesLevels: Bool
    public private(set) var session: UUID?
    /// Where the last start continued.
    public private(set) var startedFrom: CaptureContinuation?
    /// The name a test says the input device has, whatever the microphone recorded.
    private let fixedName: String?
    public private(set) var microphones: MicrophoneList
    /// UID of the microphone recorded.
    public var microphoneUID: String? { current?.uid }
    /// The microphone recorded, kept once it disappeared, as a device would.
    private var current: MicrophoneDevice?
    /// The switches the session asked for, in order.
    public private(set) var switches: [(uid: String, reason: MicrophoneSwitchReason)] = []
    /// Microphones whose switch fails, as a device that cannot start.
    private var failingMicrophones: Set<String> = []
    /// How long a switch keeps the stream still, reported in `restarted(gap:)`.
    private let switchGap: TimeInterval
    /// Lets that time pass on the test's clock, between `restarting` and `restarted(gap:)`; a test
    /// can also act there, as during a rebuild.
    private let elapse: (@MainActor @Sendable (TimeInterval) async -> Void)?
    public private(set) var isPaused = false
    public private(set) var isStopped = false
    /// Active time, paused time left out, that drives the meters.
    private var banked: Duration = .zero
    private var runningSince: ContinuousClock.Instant?
    private var animation: Task<Void, Never>?

    /// - Parameters:
    ///   - animatesLevels: sends moving levels five times per second, as demo mode shows them.
    ///   - simulated: false lets a test stand in for a real capture, whose sessions are transcribed.
    ///   - microphone: the input name the capture reports, whatever device it records.
    ///   - microphones: the inputs it pretends to see.
    ///   - switchGap: how long a switch takes; `elapse` makes that time pass on the caller's clock.
    public init(animatesLevels: Bool = true, simulated: Bool = true, audio: CapturedAudio = CapturedAudio(),
                startFailure: (any Error & Sendable)? = nil, microphone: String? = nil,
                microphones: MicrophoneList = .simulated, switchGap: TimeInterval = 0,
                elapse: (@MainActor @Sendable (TimeInterval) async -> Void)? = nil) {
        fixedName = microphone; self.microphones = microphones; self.switchGap = switchGap; self.elapse = elapse
        (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
        isSimulated = simulated
        self.audio = audio; self.startFailure = startFailure; self.animatesLevels = animatesLevels
    }

    public var microphone: MicrophoneDevice? {
        guard var device = current else { return fixedName.map { MicrophoneDevice(uid: "simulated", name: $0) } }
        if let fixedName { device.name = fixedName }
        return device
    }

    public func start(session id: UUID, continuing start: CaptureContinuation, microphone uid: String?) async throws {
        if let startFailure { continuation.finish(); throw startFailure }
        session = id; startedFrom = start
        current = microphones.device(uid) ?? microphones.defaultDevice
        runningSince = .now
        guard animatesLevels else { return }
        animation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                await self?.animate()
            }
        }
    }
    public func switchMicrophone(to uid: String, reason: MicrophoneSwitchReason) async throws {
        struct Unavailable: LocalizedError { var errorDescription: String? { String(localized: "Ce micro n’a pas pu démarrer.", bundle: .hwyd) } }
        switches.append((uid, reason))
        let lost = microphones.device(microphoneUID) == nil
        guard let device = microphones.device(uid), !failingMicrophones.contains(uid) else {
            // As a device would: back to the previous microphone, or a fault when none is left.
            if lost {
                continuation.yield(.failed(CaptureFault(.restart, message: Unavailable().errorDescription!)))
            }
            throw Unavailable()
        }
        // A lost microphone already stopped the stream.
        if !isPaused, !lost { continuation.yield(.restarting) }
        if !isPaused { await elapse?(switchGap) }
        current = device
        if !isPaused { continuation.yield(.restarted(gap: switchGap)) }
        continuation.yield(.microphoneSwitched(device, reason: reason))
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
        let offset = startedFrom?.offset ?? 0
        guard offset > 0 else { return audio }
        var placed = audio
        for index in placed.chunks.indices { placed.chunks[index].start += offset }
        return placed
    }
    /// Sends an event as the hardware would.
    public nonisolated func emit(_ event: CaptureEvent) { continuation.yield(event) }

    /// A device appears and becomes the system default input, as AirPods do when they connect.
    public func offer(_ device: MicrophoneDevice) {
        if microphones.device(device.uid) == nil { microphones.devices.append(device) }
        microphones.defaultInput = device.uid
        continuation.yield(.microphonesChanged(microphones))
        if device.uid != microphoneUID { continuation.yield(.microphoneOffered(device)) }
    }
    /// A device is unplugged. The system default input moves to the first input left.
    public func remove(_ uid: String) {
        guard let device = microphones.device(uid) else { return }
        microphones.devices.removeAll { $0.uid == uid }
        if microphones.defaultInput == uid { microphones.defaultInput = microphones.devices.first?.uid }
        continuation.yield(.microphonesChanged(microphones))
        guard uid == microphoneUID else { return }
        if !isPaused { continuation.yield(.restarting) }
        continuation.yield(.microphoneLost(device))
    }
    /// The switch to `uid` will fail, as a device that cannot start.
    public func failSwitches(to uid: String) { failingMicrophones.insert(uid) }

    private func animate() {
        guard !isPaused, !isStopped, let runningSince else { return }
        let parts = (banked + runningSince.duration(to: .now)).components
        let elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        continuation.yield(.levels(mic: Float((sin(elapsed * 2.2) + 1) * 0.3 + 0.05), system: Float((sin(elapsed * 1.6) + 1) * 0.16)))
    }
}

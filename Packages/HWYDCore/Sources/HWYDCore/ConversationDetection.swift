import Combine
import Foundation

/// An application that may hold a conversation: a meeting app, a browser, a phone app. Its audio
/// usually runs in a helper process; the helper counts as the application that holds it.
public struct ConversationApp: Identifiable, Hashable, Sendable {
    /// Bundle identifier, or the bundle's path when it has none.
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }

    /// The outermost application bundle that holds `path`; nil for a command-line tool or a daemon,
    /// which never count as a conversation.
    public static func bundlePath(ofExecutable path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return parts[...index].joined(separator: "/")
    }
}

/// What one audio process of an application does at the moment it is read.
public struct AppAudioActivity: Equatable, Sendable {
    public var app: ConversationApp
    public var readsMicrophone: Bool
    public var playsAudio: Bool
    public init(app: ConversationApp, readsMicrophone: Bool, playsAudio: Bool) {
        self.app = app; self.readsMicrophone = readsMicrophone; self.playsAudio = playsAudio
    }
}

/// How much the detector needs to know about the other applications' audio.
public enum AudioAttention: Sendable {
    /// Nothing: detection is off.
    case off
    /// What the system reports: an application that starts or stops audio.
    case changes
    /// A reading every two seconds as well: the system does not report an application that
    /// releases the microphone and keeps playing.
    case closely
}

/// Which other applications read the microphone or play audio. Reading it never opens a device.
/// The app's adapter listens to Core Audio; demos, previews and checks get `FixedAudioActivity`.
@MainActor public protocol AudioActivity: AnyObject {
    var readings: AnyPublisher<[AppAudioActivity], Never> { get }
    func attend(_ attention: AudioAttention)
}

/// Readings given by hand: demo mode, previews, checks and tests.
@MainActor public final class FixedAudioActivity: AudioActivity {
    private let subject = PassthroughSubject<[AppAudioActivity], Never>()
    public private(set) var attention = AudioAttention.off
    public init() {}
    public var readings: AnyPublisher<[AppAudioActivity], Never> { subject.eraseToAnyPublisher() }
    public func attend(_ attention: AudioAttention) { self.attention = attention }
    public func report(_ activity: [AppAudioActivity]) { subject.send(activity) }
}

public struct ConversationStartPolicy: Equatable, Sendable {
    /// How long an application holds the microphone before recording is proposed. A dictation or a
    /// voice command is shorter.
    public var settle: TimeInterval
    /// How long an application neither reads the microphone nor plays audio before its conversation
    /// is over. Until then it is not proposed again: an application may release the microphone on mute.
    public var release: TimeInterval
    public init(settle: TimeInterval, release: TimeInterval) { self.settle = settle; self.release = release }
    public static let standard = ConversationStartPolicy(settle: 8, release: 60)
}

/// Decides when to propose recording because an application holds the microphone. Pure: the caller
/// gives each reading with a monotonic time.
public struct ConversationStartWatch: Sendable {
    private enum Offer { case waiting, standing, answered }
    private struct Conversation {
        var app: ConversationApp
        var microphoneSince: TimeInterval?
        var quietSince: TimeInterval?
        /// Proposed once, or recorded: not proposed again before the conversation is over.
        var offer = Offer.waiting
    }
    public let policy: ConversationStartPolicy
    private var conversations: [String: Conversation] = [:]

    public init(policy: ConversationStartPolicy = .standard) { self.policy = policy }

    /// Whether an application is in a conversation: its end can only be seen by reading again.
    public var isTracking: Bool { !conversations.isEmpty }

    /// - Parameters:
    ///   - capturing: a capture runs; the conversations it covers are not proposed afterwards.
    /// - Returns: the application whose conversation is proposed for recording now.
    public mutating func observe(_ activity: [AppAudioActivity], capturing: Bool, now: TimeInterval) -> ConversationApp? {
        conversations = conversations.filter { $0.value.quietSince.map { now - $0 < policy.release } ?? true }
        let reading = Set(activity.filter(\.readsMicrophone).map(\.app)), playing = Set(activity.filter(\.playsAudio).map(\.app.id))
        for app in reading where conversations[app.id] == nil { conversations[app.id] = Conversation(app: app) }
        for (id, conversation) in conversations {
            if reading.contains(conversation.app) {
                conversations[id]?.microphoneSince = conversation.microphoneSince ?? now
                conversations[id]?.quietSince = nil
            } else {
                conversations[id]?.microphoneSince = nil
                conversations[id]?.quietSince = playing.contains(id) ? nil : conversation.quietSince ?? now
            }
            if capturing { conversations[id]?.offer = .answered }
        }
        guard !capturing else { return nil }
        if let standing = conversations.values.first(where: { $0.offer == .standing }) { return standing.app }
        let due = conversations.values
            .compactMap { conversation in conversation.offer == .waiting ? conversation.microphoneSince.map { (conversation.app, $0) } : nil }
            .filter { now - $0.1 >= policy.settle }
            .min { $0.1 < $1.1 }
        guard let (app, _) = due else { return nil }
        conversations[app.id]?.offer = .standing
        return app
    }

    /// The user answered the proposal.
    public mutating func dismiss() {
        for (id, conversation) in conversations where conversation.offer == .standing { conversations[id]?.offer = .answered }
    }
}

/// The proposal to record the conversation an application seems to hold.
public struct ConversationProposal: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var app: ConversationApp
}

/// Proposes recording when another application holds the microphone and no capture runs. It never
/// starts a capture: the proposal is answered by the user.
@MainActor public final class ConversationDetector: ObservableObject {
    @Published public private(set) var proposal: ConversationProposal?
    /// Off: nothing is proposed and the other applications are not looked at.
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            watch = ConversationStartWatch(policy: watch.policy); last = []
            observe()
        }
    }
    public var isCapturing = false {
        didSet { if isCapturing != oldValue { observe() } }
    }
    private let activity: any AudioActivity
    private let now: @MainActor () -> TimeInterval
    private var watch: ConversationStartWatch
    private var last: [AppAudioActivity] = []
    private var readings: AnyCancellable?

    public init(activity: any AudioActivity, enabled: Bool = true, policy: ConversationStartPolicy = .standard,
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.activity = activity; self.now = now; isEnabled = enabled; watch = ConversationStartWatch(policy: policy)
        readings = activity.readings.sink { [weak self] reading in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.last = reading
                self.observe()
            }
        }
        observe()
    }

    /// The user answered the proposal, to record or not.
    public func answer() {
        watch.dismiss()
        observe()
    }

    private func observe() {
        let app = watch.observe(last, capturing: isCapturing, now: now())
        if app != proposal?.app { proposal = app.map { ConversationProposal(app: $0) } }
        activity.attend(!isEnabled ? .off : watch.isTracking ? .closely : .changes)
    }
}

extension SettingKey where Value == Bool {
    /// Proposes recording when another application holds the microphone.
    public static var conversationDetection: Self { .init("capture.conversationDetection", default: true) }
}

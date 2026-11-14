import Foundation

/// How the app was launched, read once from the command line by the composition root.
///
/// Every mode but `app` works on synthetic data: no microphone, no user preference, no
/// external link, no network request from the updater.
public enum LaunchMode: Equatable, Sendable {
    /// The installed app on the user's data. `examples` opens it on the examples (`--demo`).
    case app(examples: Bool)
    /// `--snapshot <dir>`: renders the UI into PNG files, then quits.
    case snapshot(URL)
    /// `--self-test <dir> [seconds]`: drives the capture writer with synthetic buffers.
    case selfTest(URL, seconds: Double)
    /// `--ui-test <dir>`: the interaction checks, on a store in `dir`.
    case uiTest(URL)
    /// `--asr-test <dir>`: real transcription of a synthetic sample in `dir`.
    case asrTest(URL)
    /// A synthetic flag without its folder: the window opens on the examples and nothing real is touched.
    case preview

    /// Reads the first synthetic flag, in the order the app has always checked them.
    public init(arguments: [String]) {
        func folder(after flag: String) -> URL?? {
            guard let index = arguments.firstIndex(of: flag) else { return nil }
            return .some(arguments.count > index + 1 ? URL(fileURLWithPath: arguments[index + 1]) : nil)
        }
        if let directory = folder(after: "--asr-test") { self = directory.map(Self.asrTest) ?? .preview; return }
        if let directory = folder(after: "--ui-test") { self = directory.map(Self.uiTest) ?? .preview; return }
        if let directory = folder(after: "--self-test") {
            guard let directory, let index = arguments.firstIndex(of: "--self-test") else { self = .preview; return }
            let seconds = arguments.count > index + 2 ? Double(arguments[index + 2]) ?? 2 : 2
            self = .selfTest(directory, seconds: seconds); return
        }
        if let directory = folder(after: "--snapshot") { self = directory.map(Self.snapshot) ?? .preview; return }
        self = .app(examples: arguments.contains("--demo"))
    }

    /// Synthetic data only: no microphone, preference, link, shortcut or updater.
    public var isSynthetic: Bool { if case .app = self { false } else { true } }
}

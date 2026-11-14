import Foundation

/// Where the bundled helpers live, and which secret vault they use. The app builds one from its
/// bundle; nothing else spells out a helper path.
public struct HelperLocator: Equatable, Sendable {
    public let helpersDirectory: URL
    /// The vault `hwyd-pipeline` reads voice prints from. Synthetic checks give `.memory`, so a
    /// helper they start never reaches the user's keychain.
    public var secrets: HelperSecrets = .keychain
    public init(helpersDirectory: URL, secrets: HelperSecrets = .keychain) { self.helpersDirectory = helpersDirectory; self.secrets = secrets }
    /// Helpers of an app bundle, in `Contents/Helpers`.
    public init(appBundle: URL) { self.init(helpersDirectory: appBundle.appendingPathComponent("Contents/Helpers", isDirectory: true)) }
    /// Transcription, voice and model installation helper.
    public var pipeline: URL { helpersDirectory.appendingPathComponent("hwyd-pipeline") }
    /// MCP server, also handed to ACP agents for the summary handoff.
    public var mcp: URL { helpersDirectory.appendingPathComponent("hwyd-mcp") }
    /// Variables a helper process is started with.
    public var environment: [String: String] { [HelperSecrets.environmentKey: secrets.rawValue] }
}

/// The secret vault a helper process uses, passed in its environment.
public enum HelperSecrets: String, Sendable {
    /// The login keychain: the installed app, and a helper started by hand or by a script.
    case keychain
    /// Memory of the helper process, empty at start and lost at exit.
    case memory

    public static let environmentKey = "HWYD_SECRET_VAULT"
    /// What a helper process was asked for; the keychain when nothing was said.
    public init(environment: [String: String]) { self = environment[Self.environmentKey].flatMap(Self.init(rawValue:)) ?? .keychain }
    public func makeVault() -> any SecretVault {
        switch self {
        case .keychain: KeychainVault()
        case .memory: InMemorySecretVault()
        }
    }
}

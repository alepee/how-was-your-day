import Foundation

/// Where the bundled helpers live. The app builds one from its bundle; nothing else spells out
/// a helper path.
public struct HelperLocator: Equatable, Sendable {
    public let helpersDirectory: URL
    public init(helpersDirectory: URL) { self.helpersDirectory = helpersDirectory }
    /// Helpers of an app bundle, in `Contents/Helpers`.
    public init(appBundle: URL) { self.init(helpersDirectory: appBundle.appendingPathComponent("Contents/Helpers", isDirectory: true)) }
    /// Transcription, voice and model installation helper.
    public var pipeline: URL { helpersDirectory.appendingPathComponent("hwyd-pipeline") }
    /// MCP server, also handed to ACP agents for the summary handoff.
    public var mcp: URL { helpersDirectory.appendingPathComponent("hwyd-mcp") }
}

import Foundation

/// Finds which known ACP agents (`ACPAgentPreset.all`) are installed on this Mac.
public protocol AgentDiscovery: Sendable {
    /// Commands of the installed presets, in `ACPAgentPreset.all` order.
    func installedAgents() async -> [String]
}

/// Answers a fixed list: previews, tests, and modes that must not start a process.
public struct FixedAgentDiscovery: AgentDiscovery {
    public let commands: [String]
    public init(_ commands: [String] = []) { self.commands = commands }
    public func installedAgents() async -> [String] { commands }
}

extension ACPAgentPreset {
    /// Shell script printing the executable of each installed preset, one per line. Run through
    /// a login shell, as the agent itself will be launched.
    public static var detectionScript: String {
        all.map { "command -v \($0.executable) >/dev/null 2>&1 && echo \($0.executable)" }.joined(separator: "; ")
    }
    /// Commands of the presets whose executable the detection script printed.
    public static func installed(fromDetectionOutput output: String) -> [String] {
        let found = Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return all.filter { found.contains($0.executable) }.map(\.command)
    }
}

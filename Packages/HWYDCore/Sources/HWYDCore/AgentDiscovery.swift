import Foundation

/// The known ACP agents (`ACPAgentPreset.all`) on this Mac, as commands in preset order.
public struct AgentInventory: Equatable, Sendable {
    /// HWYD can start them now.
    public var ready: [String]
    /// The agent's tool is installed but its ACP adapter is not; installing the adapter makes it ready.
    public var installable: [String]
    public init(ready: [String] = [], installable: [String] = []) { self.ready = ready; self.installable = installable }
}

/// Finds which known ACP agents are installed on this Mac, and installs the adapter an agent lacks.
public protocol AgentDiscovery: Sendable {
    func inventory() async -> AgentInventory
    /// Installs the preset's ACP adapter. Throws with a message for the user.
    func installAdapter(for preset: ACPAgentPreset) async throws
}

/// Answers a fixed inventory: previews, tests, and modes that must not start a process. Installing
/// an adapter only moves the agent to the ready ones.
public actor FixedAgentDiscovery: AgentDiscovery {
    private var current: AgentInventory
    public init(_ ready: [String] = [], installable: [String] = []) { current = AgentInventory(ready: ready, installable: installable) }
    public func inventory() async -> AgentInventory { current }
    public func installAdapter(for preset: ACPAgentPreset) async throws {
        guard current.installable.contains(preset.command) else { return }
        current.installable.removeAll { $0 == preset.command }
        current.ready = ACPAgentPreset.all.map(\.command).filter { current.ready.contains($0) || $0 == preset.command }
    }
}

extension ACPAgentPreset {
    /// Shell script printing, one per line, the executable and the tool of each preset found. Run
    /// through a login shell, as the agent itself will be launched.
    public static var detectionScript: String {
        Set(all.flatMap { [$0.executable, $0.cli] }).sorted()
            .map { "command -v \($0) >/dev/null 2>&1 && echo \($0)" }.joined(separator: "; ")
    }
    /// What the detection script found: ready presets, and those whose adapter can be installed.
    public static func inventory(fromDetectionOutput output: String) -> AgentInventory {
        let found = Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        let ready = all.filter { found.contains($0.executable) }
        let installable = all.filter { !found.contains($0.executable) && $0.adapterPackage != nil && found.contains($0.cli) }
        return AgentInventory(ready: ready.map(\.command), installable: installable.map(\.command))
    }
}

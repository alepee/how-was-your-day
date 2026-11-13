import Foundation
import HWYDCore

/// Looks for the known ACP agents through a login shell, as the agent itself will be launched.
struct LoginShellAgentDiscovery: AgentDiscovery {
    func installedAgents() async -> [String] {
        await Task.detached(priority: .utility) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", ACPAgentPreset.detectionScript]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            process.waitUntilExit()
            return ACPAgentPreset.installed(fromDetectionOutput: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }.value
    }
}

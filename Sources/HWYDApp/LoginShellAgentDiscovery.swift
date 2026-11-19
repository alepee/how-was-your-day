import Foundation
import HWYDCore

/// Looks for the known ACP agents through a login shell, as the agent itself will be launched,
/// and installs a missing adapter with the user's npm.
struct LoginShellAgentDiscovery: AgentDiscovery {
    func inventory() async -> AgentInventory {
        ACPAgentPreset.inventory(fromDetectionOutput: await Self.run(ACPAgentPreset.detectionScript).output)
    }
    func installAdapter(for preset: ACPAgentPreset) async throws {
        guard let command = preset.adapterInstallCommand else { return }
        guard await Self.run(command).succeeded else {
            throw AgentInstallFailure(message: String(localized: "Installation de l’adaptateur \(preset.name) impossible. Lancez dans un terminal : \(command)"))
        }
    }
    /// Runs a script in a login shell.
    private static func run(_ script: String) async -> (output: String, succeeded: Bool) {
        await Task.detached(priority: .utility) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", script]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return ("", false) }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (output, process.terminationStatus == 0)
        }.value
    }
}

struct AgentInstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

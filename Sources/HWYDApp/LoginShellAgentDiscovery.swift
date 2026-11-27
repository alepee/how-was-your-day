import Foundation
import HWYDCore

/// Looks for the known ACP agents through a login shell, on the `PATH` the agent itself will be
/// launched with, and installs a missing adapter with the user's npm.
struct LoginShellAgentDiscovery: AgentDiscovery {
    var shellPath: UserShellPath = .shared

    func inventory() async -> AgentInventory {
        ACPAgentPreset.inventory(fromDetectionOutput: await run(ACPAgentPreset.detectionScript).output)
    }
    func installAdapter(for preset: ACPAgentPreset) async throws {
        guard let script = preset.adapterInstallScript, let command = preset.adapterInstallCommand else { return }
        switch await run(script).status {
        case 0: return
        case ACPAgentPreset.npmMissingStatus:
            throw AgentInstallFailure(message: String(localized: "L’adaptateur \(preset.name) s’installe avec npm, introuvable sur ce Mac. Installez Node.js (nodejs.org ou « brew install node »), puis réessayez."))
        default:
            throw AgentInstallFailure(message: String(localized: "Installation de l’adaptateur \(preset.name) impossible. Lancez dans un terminal : \(command)"))
        }
    }
    /// Runs a script in a login shell.
    private func run(_ script: String) async -> (output: String, status: Int32) {
        let environment = AgentSearchPath.environment(shellPath: await shellPath.value())
        return await Task.detached(priority: .utility) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", script]
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return ("", -1) }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (output, process.terminationStatus)
        }.value
    }
}

struct AgentInstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

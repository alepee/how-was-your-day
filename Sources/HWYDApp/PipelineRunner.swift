import Foundation
import Darwin
import HWYDCore

extension HelperLocator {
    /// Helpers bundled with the running app.
    static let app = HelperLocator(appBundle: Bundle.main.bundleURL)
}

@MainActor final class PipelineRunner {
    private let helpers: HelperLocator
    private var process: Process?
    init(helpers: HelperLocator = .app) { self.helpers = helpers }
    private var cancelled = false
    func prepare() { cancelled = false }
    func cancel() { cancelled = true; if let process, process.isRunning { process.terminate() } }
    func run(arguments: [String], log: URL) async throws {
        guard !cancelled else { throw CancellationError() }
        let executable = helpers.pipeline
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PipelineFailure(message: String(localized: "Le helper de transcription est absent. Relancez l’app construite par scripts/build-app.sh."))
        }
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close(); process = nil }
        let child = Process(); child.executableURL = executable; child.arguments = arguments
        child.standardOutput = output; child.standardError = output; child.standardInput = FileHandle.nullDevice
        // The helper answers in the app's language, whatever the system language.
        child.environment = ProcessInfo.processInfo.environment.merging([HWYDLocalization.environmentKey: HWYDLocalization.current]) { $1 }
        process = child
        try child.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1800))
        while child.isRunning {
            if cancelled || Task.isCancelled || ContinuousClock.now > deadline {
                child.terminate()
                for _ in 0..<25 where child.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                throw PipelineFailure(message: String(localized: "Traitement interrompu. Vous pouvez le relancer depuis le transcript."))
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard child.terminationStatus == 0 else {
            let data = try Data(contentsOf: log)
            let message = String(decoding: data.suffix(4000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PipelineFailure(message: message.isEmpty ? String(localized: "Le traitement a été interrompu. Vous pouvez le relancer.") : message)
        }
    }
}
extension PipelineRunner {
    /// Runs a short read-only helper command and returns its standard output.
    nonisolated static func query(_ arguments: [String], helpers: HelperLocator = .app, timeout: Duration = .seconds(30)) async throws -> Data {
        let executable = helpers.pipeline
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw PipelineFailure(message: String(localized: "Le helper de transcription est absent.")) }
        let child = Process(); child.executableURL = executable; child.arguments = arguments
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = FileHandle.nullDevice; child.standardInput = FileHandle.nullDevice
        try child.run()
        let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while child.isRunning {
            if ContinuousClock.now > deadline { child.terminate(); throw PipelineFailure(message: String(localized: "Le helper ne répond pas.")) }
            try await Task.sleep(for: .milliseconds(50))
        }
        let data = await reader.value
        guard child.terminationStatus == 0 else { throw PipelineFailure(message: String(localized: "Le helper a échoué.")) }
        return data
    }
}
struct PipelineFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

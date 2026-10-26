import Foundation
import Darwin
import HWYDCore

@main struct PipelineCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first {
            case let command where ["enroll-voice", "identify-voices", "forget-voice", "probe-voice"].contains(command ?? "") && args.count == 4:
                let store = try SessionStore(directory: URL(fileURLWithPath: args[1]))
                let lock = open(store.directory.appendingPathComponent("pipeline.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
                guard lock >= 0 else { throw CLIError(message: "Verrou indisponible.") }
                defer { close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw CLIError(message: "Un traitement est déjà en cours.") }
                let job = try JSONDecoder().decode(VoiceJob.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                let matches = try await VoiceStage.run(command: command!, store: store, job: job)
                try JSONEncoder().encode(matches).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
            case "diagnose": print(await AppleSpeechRecognizer.diagnostics())
            case "install-model":
                try await AppleSpeechRecognizer().install(locale: args.count > 1 ? args[1] : "fr-FR")
                print("Modèle installé.")
            case "install-diarizer" where args.count == 2:
                try await DiarizationStage.install(directory: URL(fileURLWithPath: args[1]).appendingPathComponent("models/diarization"))
                print("Modèles de séparation des voix installés.")
            case let command where (command == "transcribe" || command == "transcribe-calibration") && args.count == 4:
                let store = try SessionStore(directory: URL(fileURLWithPath: args[1]))
                let lock = open(store.directory.appendingPathComponent("pipeline.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
                guard lock >= 0 else { throw CLIError(message: "Impossible de verrouiller le pipeline.") }
                defer { close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw CLIError(message: "Un autre pipeline traite déjà ce store.") }
                let request = try JSONDecoder().decode(TranscriptionRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                if command == "transcribe-calibration", request.diarize != true {
                    throw CLIError(message: "La calibration nécessite diarize: true dans la requête.")
                }
                let working = URL(fileURLWithPath: args[3]).deletingLastPathComponent().appendingPathComponent("echo-processing-\(UUID())")
                try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: working) }
                let prepared = try EchoCancellation.prepare(request, store: store, directory: working)
                var result = try await TranscriptionPipeline.run(request, store: store, recognizer: AppleSpeechRecognizer(), audioOverrides: prepared.chunks)
                result.echoCancellationEngine = prepared.engine
                if request.diarize == true {
                    result = try await DiarizationStage.run(result, store: store, workingDirectory: URL(fileURLWithPath: args[3]).deletingLastPathComponent(), diagnosticURL: command == "transcribe-calibration" ? URL(fileURLWithPath: args[3] + ".alignment.json") : nil, microphoneOverride: prepared.microphone)
                }
                try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
            case "echo-diagnostic" where args.count == 4:
                let store = try SessionStore(directory: URL(fileURLWithPath: args[1]))
                let request = try JSONDecoder().decode(TranscriptionRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                let output = URL(fileURLWithPath: args[3])
                let report = try EchoStage.run(request: request, store: store, workingDirectory: output.deletingLastPathComponent())
                try JSONEncoder().encode(report).write(to: output, options: .atomic)
            case "inspect" where args.count == 2:
                let recordings = try await SessionStore(directory: URL(fileURLWithPath: args[1])).all()
                for item in recordings { print("\(item.id)  \(item.state.rawValue)  v\(item.revision)  \(item.title)") }
            default:
                FileHandle.standardError.write(Data("Usage: hwyd-pipeline echo-diagnostic <store> <request.json> <report.json> | diagnose | install-model [locale] | install-diarizer <store> | inspect <store> | transcribe[-calibration] <store> <request.json> <result.json>\n".utf8)); exit(2)
            }
        } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
    }
}

private struct CLIError: LocalizedError { let message: String; var errorDescription: String? { message } }

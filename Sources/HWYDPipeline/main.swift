import Foundation
import Darwin
import HWYDCore

@main struct PipelineCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        // Every adapter of this run, chosen once by the root. The subcommands hand them to the stages.
        let environment = PipelineRoot.environment
        do {
            switch args.first {
            case let command where ["enroll-voice", "identify-voices", "forget-voice", "forget-voice-source", "voice-sources", "probe-voice"].contains(command ?? "") && args.count == 4:
                let workspace = try environment.workspace(at: URL(fileURLWithPath: args[1]))
                // Second line of defense: the app's WorkCoordinator already runs one heavy job at a time. This
                // lock guards against a process it cannot see, such as a second app instance or a script.
                // Print changes and reads are quick and run beside a transcription: they only take the
                // voice print lock, as every reader and writer of the prints does.
                let lock = open(workspace.directory.appendingPathComponent("pipeline.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
                guard lock >= 0 else { throw CLIError(message: String(localized: "Verrou indisponible.", bundle: .hwyd)) }
                defer { close(lock) }
                if VoiceStage.heavyCommands.contains(command!) {
                    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw CLIError(message: String(localized: "Un traitement est déjà en cours.", bundle: .hwyd)) }
                }
                let job = try JSONDecoder().decode(VoiceJob.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                try await VoiceStage.run(command: command!, people: workspace.people, audio: workspace.audio, prints: workspace.prints, embedder: workspace.voices.embedder, directory: workspace.directory, job: job).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
            case "diagnose": print(await environment.speechModels.diagnostics())
            case "languages":
                FileHandle.standardOutput.write(try JSONEncoder().encode(await environment.speechModels.locales()))
            case "install-model":
                try await environment.speechModels.install(args.count > 1 ? args[1] : "fr-FR")
                print("Modèle installé.") // l10n:ignore (log line)
            case "diarizer-status" where args.count == 2:
                FileHandle.standardOutput.write(try JSONEncoder().encode(DiarizerStatus(installed: environment.voiceModels(in: URL(fileURLWithPath: args[1])).isInstalled())))
            case "install-diarizer" where args.count == 2:
                try await environment.voiceModels(in: URL(fileURLWithPath: args[1])).install()
                print("Modèles de séparation des voix installés.") // l10n:ignore (log line)
            case let command where (command == "transcribe" || command == "transcribe-calibration") && args.count == 4:
                let workspace = try environment.workspace(at: URL(fileURLWithPath: args[1]))
                // Second line of defense: the app's WorkCoordinator already runs one job at a time. This lock
                // guards against a process it cannot see, such as a second app instance or a script.
                let lock = open(workspace.directory.appendingPathComponent("pipeline.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
                guard lock >= 0 else { throw CLIError(message: String(localized: "Impossible de verrouiller le pipeline.", bundle: .hwyd)) }
                defer { close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw CLIError(message: String(localized: "Un autre pipeline traite déjà ce store.", bundle: .hwyd)) }
                var request = try JSONDecoder().decode(TranscriptionRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                if request.locale == SpeechLanguage.automatic { request = request.resolvingLanguages(await environment.speechModels.locales()) }
                if command == "transcribe-calibration", request.diarize != true {
                    throw CLIError(message: String(localized: "La calibration nécessite diarize: true dans la requête.", bundle: .hwyd))
                }
                let working = URL(fileURLWithPath: args[3]).deletingLastPathComponent().appendingPathComponent("echo-processing-\(UUID())")
                try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: working) }
                let prepared = try EchoCancellation.prepare(request, audio: workspace.audio, directory: working)
                var result = try await TranscriptionPipeline.run(request, audio: workspace.audio, recognizer: environment.recognizer, audioOverrides: prepared.chunks)
                result.echoCancellationEngine = prepared.engine
                if request.diarize == true {
                    let diarized = try await DiarizationStage.run(result, audio: workspace.audio, diarizer: workspace.voices.diarizer, workingDirectory: URL(fileURLWithPath: args[3]).deletingLastPathComponent(), diagnosticURL: command == "transcribe-calibration" ? URL(fileURLWithPath: args[3] + ".alignment.json") : nil, microphoneOverride: prepared.microphone)
                    // The app names a recognised voice when it applies the result, after checking the
                    // person can still be recognized.
                    result = await VoiceProcessingStage.run(diarized.result, windows: diarized.windows, people: workspace.people, audio: workspace.audio,
                                                            prints: workspace.prints, directory: workspace.directory, audioOverrides: prepared.chunks).result
                }
                result.segments = EchoTranscriptGuard.annotate(result.segments)
                try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
            case "echo-diagnostic" where args.count == 4:
                let workspace = try environment.workspace(at: URL(fileURLWithPath: args[1]))
                let request = try JSONDecoder().decode(TranscriptionRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                let output = URL(fileURLWithPath: args[3])
                let report = try EchoStage.run(request: request, audio: workspace.audio, workingDirectory: output.deletingLastPathComponent())
                try JSONEncoder().encode(report).write(to: output, options: .atomic)
            case "voice-processing" where args.count == 4 || args.count == 5:
                // Read-only diagnostic: no lock, no write to the store, voice memory never opened. An optional
                // revision reads an earlier version of the session, such as the one before a voice was split.
                let workspace = try environment.workspace(at: URL(fileURLWithPath: args[1]), readOnly: true)
                guard let id = UUID(uuidString: args[2]) else { throw StoreError.notFound }
                let recording: Recording?
                if args.count == 5, let revision = Int(args[4]) { recording = try await workspace.versions(id).last { $0.revision == revision } }
                else { recording = try await workspace.recordings.all().first { $0.id == id } }
                guard let recording else { throw StoreError.notFound }
                let output = URL(fileURLWithPath: args[3])
                let report = try await VoiceProcessingStage.diagnose(recording: recording, audio: workspace.audio, people: workspace.people, diarizer: workspace.voices.diarizer,
                                                                     directory: workspace.directory, workingDirectory: output.deletingLastPathComponent())
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: output, options: .atomic)
            case "inspect" where args.count == 2:
                let recordings = try await environment.workspace(at: URL(fileURLWithPath: args[1])).recordings.all()
                for item in recordings { print("\(item.id)  \(item.state.rawValue)  v\(item.revision)  \(item.title)") }
            default:
                FileHandle.standardError.write(Data("Usage: hwyd-pipeline echo-diagnostic <store> <request.json> <report.json> | voice-processing <store> <recording-id> <report.json> [revision] | diagnose | languages | install-model [locale] | install-diarizer <store> | diarizer-status <store> | inspect <store> | transcribe[-calibration] <store> <request.json> <result.json>\n".utf8)); exit(2)
            }
        } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
    }
}

struct CLIError: LocalizedError { let message: String; var errorDescription: String? { message } }

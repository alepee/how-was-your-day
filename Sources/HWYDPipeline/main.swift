import Foundation
import Darwin
import HWYDCore

@main struct PipelineCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        // Voice prints: the keychain, unless the app started this helper for a synthetic check.
        let prints = VoicePrints(vault: HelperSecrets(environment: ProcessInfo.processInfo.environment).makeVault())
        do {
            switch args.first {
            case let command where ["enroll-voice", "identify-voices", "forget-voice", "forget-voice-source", "voice-sources", "probe-voice"].contains(command ?? "") && args.count == 4:
                let store = try SessionStore(directory: URL(fileURLWithPath: args[1]))
                // Second line of defense: the app's WorkCoordinator already runs one job at a time. This lock
                // guards against a process it cannot see, such as a second app instance or a script.
                let lock = open(store.directory.appendingPathComponent("pipeline.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
                guard lock >= 0 else { throw CLIError(message: String(localized: "Verrou indisponible.", bundle: .hwyd)) }
                defer { close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw CLIError(message: String(localized: "Un traitement est déjà en cours.", bundle: .hwyd)) }
                let job = try JSONDecoder().decode(VoiceJob.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                try await VoiceStage.run(command: command!, store: store, prints: prints, job: job).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
            case "diagnose": print(await AppleSpeechRecognizer.diagnostics())
            case "languages":
                FileHandle.standardOutput.write(try JSONEncoder().encode(await AppleSpeechRecognizer.locales()))
            case "install-model":
                try await AppleSpeechRecognizer().install(locale: args.count > 1 ? args[1] : "fr-FR")
                print("Modèle installé.") // l10n:ignore (log line)
            case "diarizer-status" where args.count == 2:
                FileHandle.standardOutput.write(try JSONEncoder().encode(DiarizerStatus(installed: DiarizationStage.isInstalled(
                    directory: URL(fileURLWithPath: args[1]).appendingPathComponent("models/diarization")))))
            case "install-diarizer" where args.count == 2:
                try await DiarizationStage.install(directory: URL(fileURLWithPath: args[1]).appendingPathComponent("models/diarization"))
                print("Modèles de séparation des voix installés.") // l10n:ignore (log line)
            case let command where (command == "transcribe" || command == "transcribe-calibration") && args.count == 4:
                let store = try SessionStore(directory: URL(fileURLWithPath: args[1]))
                // Second line of defense: the app's WorkCoordinator already runs one job at a time. This lock
                // guards against a process it cannot see, such as a second app instance or a script.
                let lock = open(store.directory.appendingPathComponent("pipeline.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
                guard lock >= 0 else { throw CLIError(message: String(localized: "Impossible de verrouiller le pipeline.", bundle: .hwyd)) }
                defer { close(lock) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw CLIError(message: String(localized: "Un autre pipeline traite déjà ce store.", bundle: .hwyd)) }
                var request = try JSONDecoder().decode(TranscriptionRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                if request.locale == SpeechLanguage.automatic { request = request.resolvingLanguages(await AppleSpeechRecognizer.locales()) }
                if command == "transcribe-calibration", request.diarize != true {
                    throw CLIError(message: String(localized: "La calibration nécessite diarize: true dans la requête.", bundle: .hwyd))
                }
                let working = URL(fileURLWithPath: args[3]).deletingLastPathComponent().appendingPathComponent("echo-processing-\(UUID())")
                try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: working) }
                let prepared = try EchoCancellation.prepare(request, audio: store.audio, directory: working)
                var result = try await TranscriptionPipeline.run(request, audio: store.audio, recognizer: AppleSpeechRecognizer(), audioOverrides: prepared.chunks)
                result.echoCancellationEngine = prepared.engine
                if request.diarize == true {
                    result = try await DiarizationStage.run(result, audio: store.audio, models: store.directory.appendingPathComponent("models/diarization"), workingDirectory: URL(fileURLWithPath: args[3]).deletingLastPathComponent(), diagnosticURL: command == "transcribe-calibration" ? URL(fileURLWithPath: args[3] + ".alignment.json") : nil, microphoneOverride: prepared.microphone)
                    let people = try await store.people().filter(\.recognitionEnabled)
                    if !people.isEmpty {
                        var recording = Recording(id: request.recordingID, title: "Voice identification", speakers: result.speakers ?? [], segments: result.segments)
                        recording.audioChunks = request.chunks
                        do {
                            let matches = try await VoiceStage.identify(recording: recording, store: store, prints: prints, audioOverrides: prepared.chunks)
                            result.speakers = recording.speakers.map { speaker in
                                var speaker = speaker
                                if let match = matches[speaker.id.uuidString], let person = people.first(where: { $0.id == match.personID }) {
                                    speaker.proposedIdentity = match; speaker.label = person.name
                                }
                                return speaker
                            }
                        } catch {
                            // A locked keychain must not discard a successfully transcribed session.
                            result.identityWarning = String(localized: "Reconnaissance vocale indisponible : \(error.localizedDescription)", bundle: .hwyd)
                        }
                    }
                }
                result.segments = EchoTranscriptGuard.annotate(result.segments)
                try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
            case "echo-diagnostic" where args.count == 4:
                let store = try SessionStore(directory: URL(fileURLWithPath: args[1]))
                let request = try JSONDecoder().decode(TranscriptionRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
                let output = URL(fileURLWithPath: args[3])
                let report = try EchoStage.run(request: request, audio: store.audio, workingDirectory: output.deletingLastPathComponent())
                try JSONEncoder().encode(report).write(to: output, options: .atomic)
            case "inspect" where args.count == 2:
                let recordings = try await SessionStore(directory: URL(fileURLWithPath: args[1])).all()
                for item in recordings { print("\(item.id)  \(item.state.rawValue)  v\(item.revision)  \(item.title)") }
            default:
                FileHandle.standardError.write(Data("Usage: hwyd-pipeline echo-diagnostic <store> <request.json> <report.json> | diagnose | languages | install-model [locale] | install-diarizer <store> | diarizer-status <store> | inspect <store> | transcribe[-calibration] <store> <request.json> <result.json>\n".utf8)); exit(2)
            }
        } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
    }
}

private struct CLIError: LocalizedError { let message: String; var errorDescription: String? { message } }

import Foundation
import HWYDCore

/// The process-wide objects of one helper run, built once from the process environment read at
/// start. Nothing else reads it.
enum PipelineRoot {
    static let environment = PipelineEnvironment.launch(ProcessInfo.processInfo.environment)
}

/// Apple Speech assets: the languages of this Mac, their download and a diagnostic line. Closures
/// rather than a port: each wraps one call, and only the subcommands use them.
struct SpeechModels: Sendable {
    var locales: @Sendable () async -> SpeechLocales
    var install: @Sendable (_ locale: String) async throws -> Void
    var diagnostics: @Sendable () async -> String
}

/// The voice models of one data directory: voice separation, voice vectors, and their files.
struct VoiceModels: Sendable {
    var diarizer: any OfflineDiarizing
    var embedder: any VoiceEmbedding
    /// Whether every model file is on disk, as `install` leaves them.
    var isInstalled: @Sendable () -> Bool
    var install: @Sendable () async throws -> Void
}

/// One data directory with the adapters that serve it. The subcommands hand its members to the
/// stages, which never build an adapter themselves.
struct PipelineWorkspace: Sendable {
    /// The data directory: `pipeline.lock`, `voiceprints.lock` and the working folders live there.
    var directory: URL
    var recordings: any RecordingRepository
    var people: any VoicePeople
    var audio: any AudioLocator
    /// Voice prints over the environment's vault. Vectors never leave it.
    var prints: VoicePrints
    var voices: VoiceModels
    /// The versions the store keeps of one session, oldest first: a diagnostic reads an earlier one.
    var versions: @Sendable (UUID) async throws -> [Recording]
}

/// The composition root of one helper run: every adapter it uses, chosen once. `launch(_:)`
/// builds it for the running process; tests build workspaces from doubles of the ports.
struct PipelineEnvironment: Sendable {
    var recognizer: any SpeechRecognizing
    var speechModels: SpeechModels
    /// Where voice prints live: the keychain, unless the app started this helper for a synthetic check.
    var secrets: any SecretVault

    /// The running process: Apple Speech, and the vault named by `HWYD_SECRET_VAULT`.
    static func launch(_ environment: [String: String]) -> PipelineEnvironment {
        let recognizer = AppleSpeechRecognizer()
        return PipelineEnvironment(
            recognizer: recognizer,
            speechModels: SpeechModels(locales: { await AppleSpeechRecognizer.locales() },
                                       install: { try await recognizer.install(locale: $0) },
                                       diagnostics: { await AppleSpeechRecognizer.diagnostics() }),
            secrets: HelperSecrets(environment: environment).makeVault())
    }

    /// The FluidAudio models under `<directory>/models/diarization`. Opens no store.
    func voiceModels(in directory: URL) -> VoiceModels {
        let models = directory.appendingPathComponent("models/diarization")
        return VoiceModels(diarizer: FluidDiarizer(directory: models), embedder: FluidVoiceEmbedder(directory: models),
                           isInstalled: { FluidModels.isInstalled(directory: models) },
                           install: { try await FluidModels.install(directory: models) })
    }

    /// Opens the store of `directory` and gives what serves it. `readOnly` is for a diagnostic:
    /// nothing is migrated or written.
    func workspace(at directory: URL, readOnly: Bool = false) throws -> PipelineWorkspace {
        let store = try SessionStore(directory: directory, readOnly: readOnly)
        return PipelineWorkspace(directory: store.directory, recordings: store, people: store, audio: store.audio,
                                 prints: VoicePrints(vault: secrets), voices: voiceModels(in: store.directory),
                                 versions: { try await store.versions(for: $0) })
    }
}

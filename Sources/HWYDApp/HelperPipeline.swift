import Foundation
import HWYDCore

/// The pipeline ports, served by the bundled `hwyd-pipeline`. These adapters are the only code
/// that knows its commands, job folders, `request.json` and `result.json`.
private struct HelperJob {
    let folder: URL
    /// A private folder under `<store>/jobs`.
    init(store: URL, prefix: String = "") throws {
        folder = store.appendingPathComponent("jobs/\(prefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    var request: URL { folder.appendingPathComponent("request.json") }
    var result: URL { folder.appendingPathComponent("result.json") }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

/// Transcribes through `hwyd-pipeline transcribe`. The job folder stays after a failure, with its log.
struct HelperTranscriptionService: TranscriptionService {
    let helpers: HelperLocator
    let store: URL
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let job = try HelperJob(store: store)
        try JSONEncoder().encode(request).write(to: job.request, options: .atomic)
        try await PipelineRunner.run(["transcribe", store.path, job.request.path, job.result.path], helpers: helpers,
                                     log: job.folder.appendingPathComponent("pipeline.log"))
        let result = try JSONDecoder().decode(TranscriptionResult.self, from: Data(contentsOf: job.result))
        job.remove()
        return result
    }
}

/// Voice prints through the helper's voice commands; the helper alone reads the keychain.
struct HelperVoiceMemory: VoiceMemory {
    let helpers: HelperLocator
    let store: URL
    /// Commands about a person need no session; the helper still expects one in the job.
    private static var noSession: Recording { Recording(title: "Gestion des voix") } // l10n:ignore
    private func run(_ command: String, _ job: VoiceJob) async throws -> Data {
        let folder = try HelperJob(store: store, prefix: "voice-")
        defer { folder.remove() }
        try JSONEncoder().encode(job).write(to: folder.request, options: .atomic)
        try await PipelineRunner.run([command, store.path, folder.request.path, folder.result.path], helpers: helpers,
                                     log: folder.folder.appendingPathComponent("log.txt"))
        return try Data(contentsOf: folder.result)
    }
    private static func matches(_ data: Data) throws -> VoiceMatches {
        let decoded = try JSONDecoder().decode([String: VoiceMatch].self, from: data)
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, match in UUID(uuidString: key).map { ($0, match) } })
    }
    func enroll(speakerID: UUID, in recording: Recording, as personID: UUID) async throws -> VoiceMatches {
        try Self.matches(await run("enroll-voice", VoiceJob(recording: recording, speakerID: speakerID, personID: personID)))
    }
    func identify(in recording: Recording) async throws -> VoiceMatches {
        try Self.matches(await run("identify-voices", VoiceJob(recording: recording)))
    }
    func forget(personID: UUID) async throws {
        _ = try await run("forget-voice", VoiceJob(recording: Self.noSession, personID: personID))
    }
    func forget(personID: UUID, source recordingID: UUID?) async throws {
        _ = try await run("forget-voice-source", VoiceJob(recording: Self.noSession, personID: personID, sourceRecordingID: recordingID))
    }
    func sources(personID: UUID) async throws -> [VoiceContribution] {
        try JSONDecoder().decode([VoiceContribution].self, from: await run("voice-sources", VoiceJob(recording: Self.noSession, personID: personID)))
    }
}

/// Languages and voice models as `hwyd-pipeline` sees them: Apple Speech reserves assets per process.
struct HelperSpeechModelCatalog: SpeechModelCatalog {
    let helpers: HelperLocator
    let store: URL
    private func logFolder() throws -> URL {
        let directory = store.appendingPathComponent("jobs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    func locales() async throws -> SpeechLocales {
        try JSONDecoder().decode(SpeechLocales.self, from: await PipelineRunner.query(["languages"], helpers: helpers))
    }
    func install(locale: String) async throws {
        try await PipelineRunner.run(["install-model", locale], helpers: helpers, log: try logFolder().appendingPathComponent("install-model.log"))
    }
    func diarizerReady() async -> Bool {
        guard let data = try? await PipelineRunner.query(["diarizer-status", store.path], helpers: helpers) else { return false }
        return (try? JSONDecoder().decode(DiarizerStatus.self, from: data))?.installed ?? false
    }
    func installDiarizer() async throws {
        try await PipelineRunner.run(["install-diarizer", store.path], helpers: helpers, log: try logFolder().appendingPathComponent("install-diarizer.log"))
    }
}

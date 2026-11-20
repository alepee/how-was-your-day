import Foundation
import FluidAudio
import HWYDCore

/// Turns clean speech of one voice into its vector. Declared in the helper, not in HWYDCore: a
/// vector goes from here to `VoicePrints` or to a comparison, and nowhere else.
protocol VoiceEmbedding: Sendable {
    /// The vector of the single voice heard in `samples` (16 kHz mono). Throws
    /// `VoiceError.insufficientSpeech` when the audio does not hold exactly one voice.
    func embedding(of samples: [Float]) async throws -> [Float]
}

struct FluidVoiceEmbedder: VoiceEmbedding {
    let directory: URL
    func embedding(of samples: [Float]) async throws -> [Float] {
        ModelHub.offlineMode = true
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig().withSpeakers(exactly: 1))
        try await manager.prepareModels(directory: directory)
        let result = try await manager.process(audio: samples)
        guard let embeddings = result.speakerDatabase, embeddings.count == 1, let vector = embeddings.values.first else { throw VoiceError.insufficientSpeech }
        return vector
    }
}

/// The model files `FluidDiarizer` and `FluidVoiceEmbedder` load.
enum FluidModels {
    /// Whether every model the offline diarizer loads is on disk, as `install` leaves them.
    static func isInstalled(directory: URL) -> Bool {
        let folder = directory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
    static func install(directory: URL) async throws {
        ModelHub.offlineMode = false
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels(directory: directory)
    }
}

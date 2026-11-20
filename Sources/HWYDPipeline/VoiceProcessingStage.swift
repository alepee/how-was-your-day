import Foundation
import HWYDCore

/// Runs the voice post-processing on a diarized transcript: echo, coherence, duplicates,
/// identification, classification. The rules live in `VoicePostProcessor`; this stage gives them the
/// audio levels and voice memory they need. Embeddings stay in memory.
enum VoiceProcessingStage {
    /// `prints` nil skips identification: the diagnostic never opens voice memory.
    static func run(_ result: TranscriptionResult, windows: [VoiceWindow], people store: any VoicePeople, audio: any AudioLocator, prints: VoicePrints?,
                    directory: URL, audioOverrides: [UUID: URL]) async -> (result: TranscriptionResult, measures: [UUID: VoiceMeasure]) {
        var recording = Recording(id: result.request.recordingID, title: "Voice post-processing", speakers: result.speakers ?? [], segments: result.segments)
        recording.audioChunks = result.request.chunks
        var processor = VoicePostProcessor(recording: recording, windows: windows)
        processor.detect { spans, source in
            // Two minutes spread over the group are enough for a level, whatever its length.
            let sample = VoiceCoherence.spread(spans, total: 120, pieces: 12)
            guard let samples = try? VoiceStage.readSpeech(sample, source: source, chunks: result.request.chunks, audio: audio, overrides: audioOverrides, limit: .max),
                  !samples.isEmpty else { return nil }
            return VoiceCoherence.levelDB(samples)
        }
        var output = result
        if let prints {
            do {
                let rows = processor.identificationCandidates.map { (key: $0.key, source: $0.source, vector: $0.vector) }
                let people = Set(try await store.people().filter(\.recognitionEnabled).map(\.id))
                processor.applyIdentities(try await VoiceStage.identify(rows, people: store, prints: prints, directory: directory).filter { people.contains($0.value.personID) })
            } catch {
                // A locked keychain must not discard a successfully transcribed session.
                output.identityWarning = String(localized: "Reconnaissance vocale indisponible : \(error.localizedDescription)", bundle: .hwyd)
            }
        }
        processor.classify()
        output.speakers = processor.recording.speakers; output.segments = processor.recording.segments
        output.absorbedSpeakers = processor.recording.absorbedSpeakers; output.splitProposals = processor.recording.splitProposals
        output.voiceProcessingEngine = VoicePostProcessor.engine
        return (output, processor.measures)
    }

    /// `voice-processing`: runs diarization and the post-processing again on a stored session and
    /// reports what they decide, next to what the user had decided. Read-only on the store.
    static func diagnose(recording: Recording, audio: any AudioLocator, people: any VoicePeople, diarizer: any OfflineDiarizing,
                         directory: URL, workingDirectory: URL) async throws -> VoiceProcessingReport {
        let folder = workingDirectory.appendingPathComponent("voice-processing-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = TranscriptionRequest(recordingID: recording.id, chunks: recording.audioChunks)
        let prepared = try EchoCancellation.prepare(request, audio: audio, directory: folder)
        let diarized = try await DiarizationStage.run(TranscriptionResult(request: request, segments: recording.segments), audio: audio,
                                                      diarizer: diarizer, workingDirectory: folder,
                                                      microphoneOverride: prepared.microphone)
        let before = diarized.result.speakers ?? []
        let processed = await run(diarized.result, windows: diarized.windows, people: people, audio: audio, prints: nil, directory: directory, audioOverrides: prepared.chunks)

        // Each fresh voice is named after the stored voice that shares most of its speech.
        func stored(_ id: UUID) -> Speaker? {
            var shared: [UUID: Double] = [:]
            for segment in diarized.result.segments where segment.speakerID == id {
                for other in recording.segments where other.source == segment.source {
                    guard let voice = other.speakerID else { continue }
                    let overlap = min(segment.end, other.end) - max(segment.start, other.start)
                    if overlap > 0 { shared[voice, default: 0] += overlap }
                }
            }
            return shared.max { $0.value < $1.value }.flatMap { best in recording.speakers.first { $0.id == best.key } }
        }
        let names = Dictionary(uniqueKeysWithValues: before.map { ($0.id, stored($0.id)) })
        let after = processed.result
        let voices = before.map { voice -> VoiceProcessingReport.Voice in
            let now = (after.speakers ?? []).first { $0.id == voice.id } ?? after.absorbedSpeakers?.first { $0.id == voice.id }
            let known = names[voice.id] ?? nil
            var entry = VoiceProcessingReport.Voice(source: voice.source, storedLabel: known?.label, storedIgnored: known?.ignored ?? false,
                                                    storedConfirmed: known?.confirmed ?? false, storedPersonID: known?.personID,
                                                    decision: now?.automatic, measure: processed.measures[voice.id] ?? VoiceMeasure())
            if let nearest = entry.measure.nearestLonger { entry.nearestLongerLabel = (names[nearest] ?? nil)?.label }
            if let proposal = after.splitProposals?.first(where: { $0.speakerID == voice.id }) {
                entry.proposalMergeIntoLabel = proposal.mergeInto.flatMap { (names[$0] ?? nil)?.label }
                entry.proposalSegmentCount = proposal.segmentIDs.count
            }
            return entry
        }
        return VoiceProcessingReport(recordingID: recording.id, revision: recording.revision, duration: recording.duration, voices: voices)
    }
}

/// Output of `hwyd-pipeline voice-processing`. Durations, shares and cosines: never a vector.
struct VoiceProcessingReport: Codable {
    var diagnosticSchema = 2
    var engine = VoicePostProcessor.engine
    var diagnosticOnly = true
    /// The diagnostic never opens voice memory, so no voice is recognised and a brief known voice can show as minor.
    var identification = false
    var recordingID: UUID
    var revision: Int
    var duration: Double
    var voices: [Voice]

    struct Voice: Codable {
        var source: HWYDCore.AudioSource
        /// Stored voice sharing most of this voice's speech, and what the user had decided for it.
        var storedLabel: String?
        var storedIgnored: Bool
        var storedConfirmed: Bool
        var storedPersonID: UUID?
        var decision: AutomaticVoiceDecision?
        var measure: VoiceMeasure
        var nearestLongerLabel: String?
        var proposalMergeIntoLabel: String?
        var proposalSegmentCount: Int?
    }
}

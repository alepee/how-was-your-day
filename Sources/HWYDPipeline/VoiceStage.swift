import AVFoundation
import Darwin
import HWYDCore

/// Local enrollment and recognition. Jobs carry IDs and segments, never embeddings.
enum VoiceStage {
    /// Commands that run a model and take the processing lock; the others only touch the prints.
    static let heavyCommands: Set<String> = ["enroll-voice", "identify-voices", "probe-voice"]

    /// Runs `body` holding the voice print lock, waiting for it if needed. Every read and write of
    /// the prints takes it, and holds it only for that: never during a model run. The helper
    /// never nests it.
    static func withPrintLock<T>(_ directory: URL, _ body: () async throws -> T) async throws -> T {
        let lock = open(directory.appendingPathComponent("voiceprints.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CLIError(message: String(localized: "Verrou indisponible.", bundle: .hwyd)) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CLIError(message: String(localized: "Verrou indisponible.", bundle: .hwyd)) }
        return try await body()
    }

    static func embedding(recording: Recording, speaker: HWYDCore.Speaker, audio: any AudioLocator, embedder: any VoiceEmbedding, audioOverrides: [UUID: URL] = [:]) async throws -> [Float] {
        // Passages a pending split proposal attributes to someone else stay out of the sample, which
        // is spread over the whole voice: its first minute alone can be another person's.
        let doubted = Set(recording.pendingSplitProposals.filter { $0.speakerID == speaker.id }.flatMap(\.segmentIDs))
        let spans = VoiceCoherence.spread(VoiceCoherence.usableSegments(of: speaker.id, in: recording.segments).filter { !doubted.contains($0.id) }
            .map { VoiceCoherence.Span(start: $0.start, end: $0.end) })
        let samples = try readSpeech(spans, source: speaker.source, chunks: recording.audioChunks, audio: audio, overrides: audioOverrides, limit: 960_000)
        guard samples.count >= 320_000 else { throw VoiceError.insufficientSpeech }
        return try VoicePrints.normalized(await embedder.embedding(of: samples))
    }
    /// Concatenates the audio of `spans` from one track, in order, up to `limit` samples at 16 kHz.
    static func readSpeech(_ spans: [VoiceCoherence.Span], source: HWYDCore.AudioSource, chunks: [AudioChunk], audio: any AudioLocator,
                           overrides: [UUID: URL], limit: Int) throws -> [Float] {
        var samples: [Float] = []
        for span in spans {
            for chunk in chunks.filter({ $0.source == source && $0.start < span.end && $0.start + $0.duration > span.start }).sorted(by: { $0.start < $1.start }) {
                let file = try AVAudioFile(forReading: overrides[chunk.id] ?? audio.url(for: chunk), commonFormat: .pcmFormatFloat32, interleaved: false)
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else { throw VoiceError.insufficientSpeech }
                let start = Int64(max(0, span.start - chunk.start) * 16000)
                let end = min(file.length, Int64((span.end - chunk.start) * 16000))
                let frames = min(max(0, end - start), Int64(limit - samples.count))
                guard frames > 0 else { continue }
                file.framePosition = start
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
                var remaining = frames
                while remaining > 0 {
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(remaining))
                    guard buffer.frameLength > 0 else { throw VoiceError.insufficientSpeech }
                    if let channel = buffer.floatChannelData?[0] { samples += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)) }
                    remaining -= Int64(buffer.frameLength)
                }
            }
            if samples.count >= limit { break }
        }
        return samples
    }
    /// Runs one voice command. The result is JSON: matches for enrollment and identification,
    /// contributions for `voice-sources`, nothing otherwise. It never carries a vector.
    /// `directory` holds `voiceprints.lock` and the working folder of the echo-cancelled audio.
    static func run(command: String, people: any VoicePeople, audio: any AudioLocator, prints: VoicePrints, embedder: any VoiceEmbedding, directory: URL, job: VoiceJob) async throws -> Data {
        let empty = try JSONEncoder().encode([String: VoiceMatch]())
        switch command {
        case "probe-voice":
            guard job.recording.isDemo, let speaker = job.recording.speakers.first(where: { $0.id == job.speakerID }) else { throw VoiceError.insufficientSpeech }
            _ = try await embedding(recording: job.recording, speaker: speaker, audio: audio, embedder: embedder)
            return empty
        case "forget-voice":
            guard let id = job.personID else { throw StoreError.notFound }
            try await withPrintLock(directory) {
                try prints.remove(person: id)
                try await updateChannels(person: id, people: people, channels: [])
            }
            return empty
        case "forget-voice-source":
            guard let id = job.personID else { throw StoreError.notFound }
            try await withPrintLock(directory) {
                let remaining = try prints.remove(person: id, recordingID: job.sourceRecordingID)
                try await updateChannels(person: id, people: people, channels: remaining)
            }
            return empty
        case "voice-sources":
            guard let id = job.personID else { throw StoreError.notFound }
            return try await withPrintLock(directory) { try JSONEncoder().encode(prints.contributions(person: id)) }
        default: break
        }
        let enabled = try await people.people().filter { $0.recognitionEnabled }
        let speaker = job.recording.speakers.first { $0.id == job.speakerID }
        let working = directory.appendingPathComponent("jobs/voice-audio-\(UUID())")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: working) }
        // Microphone audio needs the echo of the call removed, for enrollment and for the identification that follows.
        let prepared = job.recording.audioChunks.contains(where: { $0.source == .mic }) ? try EchoCancellation.prepare(
            TranscriptionRequest(recordingID: job.recording.id, chunks: job.recording.audioChunks), audio: audio, directory: working) : EchoPreparation()
        if command == "enroll-voice" {
            guard let person = enabled.first(where: { $0.id == job.personID }), let speaker else { throw VoiceError.consentRequired }
            let channel = VoiceChannel(source: speaker.source)
            let vector = try await embedding(recording: job.recording, speaker: speaker, audio: audio, embedder: embedder, audioOverrides: prepared.chunks)
            // Recheck enrollment eligibility after the expensive model run, under the print lock: an
            // erasure or an opposition made meanwhile either ran before (refused here) or waits for this.
            try await withPrintLock(directory) {
                guard try await people.people().contains(where: { $0.id == person.id && $0.recognitionEnabled }) else { throw VoiceError.consentRequired }
                try prints.add(vector, person: person.id, channel: channel, recordingID: job.recording.id, speakerID: speaker.id)
                guard var current = try await people.people().first(where: { $0.id == person.id }), current.recognitionEnabled else {
                    try prints.remove(person: person.id); throw VoiceError.consentRequired
                }
                current.enrolledChannels = VoiceChannel.allCases.filter { current.channels.contains($0) || $0 == channel }
                current.lastEnrolledAt = Date()
                try await people.savePerson(current)
            }
            // The new sample may name other voices of this session: look again. The sample is stored
            // already, so a failure here only costs the suggestions.
            do { return try JSONEncoder().encode(await identify(recording: job.recording, people: people, audio: audio, prints: prints, embedder: embedder, directory: directory, audioOverrides: prepared.chunks)) }
            catch { return empty }
        }
        return try JSONEncoder().encode(await identify(recording: job.recording, people: people, audio: audio, prints: prints, embedder: embedder, directory: directory, audioOverrides: prepared.chunks))
    }
    private static func updateChannels(person id: UUID, people: any VoicePeople, channels: [VoiceChannel]) async throws {
        guard var person = try await people.people().first(where: { $0.id == id }) else { return }
        person.enrolledChannels = channels.isEmpty ? nil : channels
        if channels.isEmpty { person.lastEnrolledAt = nil }
        try await people.savePerson(person)
    }
    /// Proposes a known person for each voice. A voice is compared with the exemplars of its own channel;
    /// a person known only on the other channel can still be proposed, above a stricter threshold.
    static func identify(recording: Recording, people store: any VoicePeople, audio: any AudioLocator, prints: VoicePrints, embedder: any VoiceEmbedding, directory: URL, audioOverrides: [UUID: URL] = [:]) async throws -> [String: VoiceMatch] {
        guard try await hasExemplars(people: store, prints: prints, directory: directory) else { return [:] }
        var rows: [(key: String, source: HWYDCore.AudioSource, vector: [Float])] = []
        for speaker in recording.speakers where !speaker.ignored {
            do { rows.append((speaker.id.uuidString, speaker.source, try await embedding(recording: recording, speaker: speaker, audio: audio, embedder: embedder, audioOverrides: audioOverrides))) }
            catch VoiceError.insufficientSpeech { continue }
        }
        return try await identify(rows, people: store, prints: prints, directory: directory)
    }
    private static func hasExemplars(people store: any VoicePeople, prints: VoicePrints, directory: URL) async throws -> Bool {
        try await withPrintLock(directory) {
            try await store.people().filter(\.recognitionEnabled).contains { person in try VoiceChannel.allCases.contains { try !prints.vectors(person: person.id, channel: $0).isEmpty } }
        }
    }
    /// Compares voice embeddings with voice memory. Each row is one voice; each person names at most one row.
    static func identify<Key: Hashable>(_ rows: [(key: Key, source: HWYDCore.AudioSource, vector: [Float])], people store: any VoicePeople, prints: VoicePrints, directory: URL) async throws -> [Key: VoiceMatch] {
        let (people, exemplars): ([VoicePerson], [[VoiceChannel: [[Float]]]]) = try await withPrintLock(directory) {
            let people = try await store.people().filter(\.recognitionEnabled)
            return (people, try people.map { person in
                try Dictionary(uniqueKeysWithValues: VoiceChannel.allCases.map { ($0, try prints.vectors(person: person.id, channel: $0)) })
            })
        }
        guard !people.isEmpty else { return [:] }
        guard exemplars.contains(where: { $0.values.contains { !$0.isEmpty } }) else { return [:] }
        let candidates: [[VoiceResolver.Candidate?]] = rows.map { row in
            exemplars.map { VoiceResolver.candidate(row.vector, channel: VoiceChannel(source: row.source), exemplars: $0) }
        }
        let scores = candidates.map { row in row.map { $0?.adjusted ?? -1 } }
        let assignment = VoiceResolver.assign(scores: scores)
        var result: [Key: VoiceMatch] = [:]
        for i in rows.indices {
            guard let index = assignment[i], let candidate = candidates[i][index] else { continue }
            let ranked = scores[i].sorted(by: >)
            result[rows[i].key] = VoiceMatch(personID: people[index].id, score: candidate.score, margin: ranked.count > 1 ? ranked[0] - ranked[1] : nil,
                                                           channel: candidate.channel, crossChannel: candidate.crossChannel)
        }
        // Opposed or erased meanwhile: no longer proposed. The app checks again when it applies the result.
        let stillEnabled = Set(try await store.people().filter { $0.recognitionEnabled && !$0.channels.isEmpty }.map(\.id))
        return result.filter { stillEnabled.contains($0.value.personID) }
    }
}

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
        var samples: [Float] = []
        for segment in recording.segments.filter({ $0.speakerID == speaker.id }).sorted(by: { $0.start < $1.start }) {
            guard segment.end - segment.start >= 0.5,
                  !recording.segments.contains(where: { $0.id != segment.id && $0.source == segment.source && $0.speakerID != segment.speakerID && $0.start < segment.end && $0.end > segment.start }) else { continue }
            for chunk in recording.audioChunks.filter({ $0.source == speaker.source && $0.start < segment.end && $0.start + $0.duration > segment.start }).sorted(by: { $0.start < $1.start }) {
                let file = try AVAudioFile(forReading: audioOverrides[chunk.id] ?? audio.url(for: chunk), commonFormat: .pcmFormatFloat32, interleaved: false)
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else { throw VoiceError.insufficientSpeech }
                let start = Int64(max(0, segment.start - chunk.start) * 16000)
                let end = min(file.length, Int64((segment.end - chunk.start) * 16000))
                let frames = min(max(0, end - start), Int64(960_000 - samples.count))
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
            if samples.count >= 960_000 { break }
        }
        guard samples.count >= 320_000 else { throw VoiceError.insufficientSpeech }
        return try VoicePrints.normalized(await embedder.embedding(of: samples))
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
        let (people, exemplars): ([VoicePerson], [[VoiceChannel: [[Float]]]]) = try await withPrintLock(directory) {
            let people = try await store.people().filter(\.recognitionEnabled)
            return (people, try people.map { person in
                try Dictionary(uniqueKeysWithValues: VoiceChannel.allCases.map { ($0, try prints.vectors(person: person.id, channel: $0)) })
            })
        }
        guard !people.isEmpty else { return [:] }
        guard exemplars.contains(where: { $0.values.contains { !$0.isEmpty } }) else { return [:] }
        var speakers: [HWYDCore.Speaker] = []
        var candidates: [[VoiceResolver.Candidate?]] = []
        for speaker in recording.speakers where !speaker.ignored {
            do {
                let vector = try await embedding(recording: recording, speaker: speaker, audio: audio, embedder: embedder, audioOverrides: audioOverrides)
                speakers.append(speaker)
                candidates.append(exemplars.map { VoiceResolver.candidate(vector, channel: VoiceChannel(source: speaker.source), exemplars: $0) })
            } catch VoiceError.insufficientSpeech { continue }
        }
        let scores = candidates.map { row in row.map { $0?.adjusted ?? -1 } }
        let assignment = VoiceResolver.assign(scores: scores)
        var result: [String: VoiceMatch] = [:]
        for i in speakers.indices {
            guard let index = assignment[i], let candidate = candidates[i][index] else { continue }
            let ranked = scores[i].sorted(by: >)
            result[speakers[i].id.uuidString] = VoiceMatch(personID: people[index].id, score: candidate.score, margin: ranked.count > 1 ? ranked[0] - ranked[1] : nil,
                                                           channel: candidate.channel, crossChannel: candidate.crossChannel)
        }
        // Opposed or erased meanwhile: no longer proposed. The app checks again when it applies the result.
        let stillEnabled = Set(try await store.people().filter { $0.recognitionEnabled && !$0.channels.isEmpty }.map(\.id))
        return result.filter { stillEnabled.contains($0.value.personID) }
    }
}

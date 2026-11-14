import AVFoundation
import FluidAudio
import HWYDCore

/// Local enrollment and recognition. Jobs carry IDs and segments, never embeddings.
enum VoiceStage {
    static func embedding(recording: Recording, speaker: HWYDCore.Speaker, store: SessionStore, audioOverrides: [UUID: URL] = [:]) async throws -> [Float] {
        var samples: [Float] = []
        for segment in recording.segments.filter({ $0.speakerID == speaker.id }).sorted(by: { $0.start < $1.start }) {
            guard segment.end - segment.start >= 0.5,
                  !recording.segments.contains(where: { $0.id != segment.id && $0.source == segment.source && $0.speakerID != segment.speakerID && $0.start < segment.end && $0.end > segment.start }) else { continue }
            for chunk in recording.audioChunks.filter({ $0.source == speaker.source && $0.start < segment.end && $0.start + $0.duration > segment.start }).sorted(by: { $0.start < $1.start }) {
                let file = try AVAudioFile(forReading: audioOverrides[chunk.id] ?? store.audio.url(for: chunk), commonFormat: .pcmFormatFloat32, interleaved: false)
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
        ModelHub.offlineMode = true
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig().withSpeakers(exactly: 1))
        try await manager.prepareModels(directory: store.directory.appendingPathComponent("models/diarization"))
        let result = try await manager.process(audio: samples)
        guard let embeddings = result.speakerDatabase, embeddings.count == 1, let vector = embeddings.values.first else { throw VoiceError.insufficientSpeech }
        return try VoicePrints.normalized(vector)
    }
    /// Runs one voice command. The result is JSON: matches for enrollment and identification,
    /// contributions for `voice-sources`, nothing otherwise. It never carries a vector.
    static func run(command: String, store: SessionStore, prints: VoicePrints, job: VoiceJob) async throws -> Data {
        let empty = try JSONEncoder().encode([String: VoiceMatch]())
        switch command {
        case "probe-voice":
            guard job.recording.isDemo, let speaker = job.recording.speakers.first(where: { $0.id == job.speakerID }) else { throw VoiceError.insufficientSpeech }
            _ = try await embedding(recording: job.recording, speaker: speaker, store: store)
            return empty
        case "forget-voice":
            guard let id = job.personID else { throw StoreError.notFound }
            try prints.remove(person: id)
            try await updateChannels(person: id, store: store, channels: [])
            return empty
        case "forget-voice-source":
            guard let id = job.personID else { throw StoreError.notFound }
            let remaining = try prints.remove(person: id, recordingID: job.sourceRecordingID)
            try await updateChannels(person: id, store: store, channels: remaining)
            return empty
        case "voice-sources":
            guard let id = job.personID else { throw StoreError.notFound }
            return try JSONEncoder().encode(prints.contributions(person: id))
        default: break
        }
        let people = try await store.people().filter { $0.recognitionEnabled }
        let speaker = job.recording.speakers.first { $0.id == job.speakerID }
        let working = store.directory.appendingPathComponent("jobs/voice-audio-\(UUID())")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: working) }
        // Microphone audio needs the echo of the call removed, for enrollment and for the identification that follows.
        let prepared = job.recording.audioChunks.contains(where: { $0.source == .mic }) ? try EchoCancellation.prepare(
            TranscriptionRequest(recordingID: job.recording.id, chunks: job.recording.audioChunks), audio: store.audio, directory: working) : EchoPreparation()
        if command == "enroll-voice" {
            guard let person = people.first(where: { $0.id == job.personID }), let speaker else { throw VoiceError.consentRequired }
            let channel = VoiceChannel(source: speaker.source)
            let vector = try await embedding(recording: job.recording, speaker: speaker, store: store, audioOverrides: prepared.chunks)
            // Recheck enrollment eligibility after the expensive model run.
            guard try await store.people().contains(where: { $0.id == person.id && $0.recognitionEnabled }) else { throw VoiceError.consentRequired }
            try prints.add(vector, person: person.id, channel: channel, recordingID: job.recording.id, speakerID: speaker.id)
            guard var current = try await store.people().first(where: { $0.id == person.id }), current.recognitionEnabled else {
                try prints.remove(person: person.id); throw VoiceError.consentRequired
            }
            current.enrolledChannels = VoiceChannel.allCases.filter { current.channels.contains($0) || $0 == channel }
            current.lastEnrolledAt = Date()
            try await store.savePerson(current)
            // The new sample may name other voices of this session: look again. The sample is stored
            // already, so a failure here only costs the suggestions.
            do { return try JSONEncoder().encode(await identify(recording: job.recording, store: store, prints: prints, audioOverrides: prepared.chunks)) }
            catch { return empty }
        }
        return try JSONEncoder().encode(await identify(recording: job.recording, store: store, prints: prints, audioOverrides: prepared.chunks))
    }
    private static func updateChannels(person id: UUID, store: SessionStore, channels: [VoiceChannel]) async throws {
        guard var person = try await store.people().first(where: { $0.id == id }) else { return }
        person.enrolledChannels = channels.isEmpty ? nil : channels
        if channels.isEmpty { person.lastEnrolledAt = nil }
        try await store.savePerson(person)
    }
    /// Proposes a known person for each voice. A voice is compared with the exemplars of its own channel;
    /// a person known only on the other channel can still be proposed, above a stricter threshold.
    static func identify(recording: Recording, store: SessionStore, prints: VoicePrints, audioOverrides: [UUID: URL] = [:]) async throws -> [String: VoiceMatch] {
        let people = try await store.people().filter(\.recognitionEnabled)
        guard !people.isEmpty else { return [:] }
        let exemplars: [[VoiceChannel: [[Float]]]] = try people.map { person in
            try Dictionary(uniqueKeysWithValues: VoiceChannel.allCases.map { ($0, try prints.vectors(person: person.id, channel: $0)) })
        }
        guard exemplars.contains(where: { $0.values.contains { !$0.isEmpty } }) else { return [:] }
        var speakers: [HWYDCore.Speaker] = []
        var candidates: [[VoiceResolver.Candidate?]] = []
        for speaker in recording.speakers where !speaker.ignored {
            do {
                let vector = try await embedding(recording: recording, speaker: speaker, store: store, audioOverrides: audioOverrides)
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
        let stillEnabled = Set(try await store.people().filter(\.recognitionEnabled).map(\.id))
        return result.filter { stillEnabled.contains($0.value.personID) }
    }
}

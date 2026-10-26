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
                let file = try AVAudioFile(forReading: audioOverrides[chunk.id] ?? store.audioURL(for: chunk), commonFormat: .pcmFormatFloat32, interleaved: false)
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
        return try VoiceKeychain.normalized(vector)
    }
    static func run(command: String, store: SessionStore, job: VoiceJob) async throws -> [String: VoiceMatch] {
        if command == "probe-voice" {
            guard job.recording.isDemo, let speaker = job.recording.speakers.first(where: { $0.id == job.speakerID }) else { throw VoiceError.insufficientSpeech }
            _ = try await embedding(recording: job.recording, speaker: speaker, store: store)
            return [:]
        }
        if command == "forget-voice", let id = job.personID {
            try VoiceKeychain.remove(person: id); return [:]
        }
        let people = try await store.people().filter { $0.recognitionEnabled }
        let working = store.directory.appendingPathComponent("jobs/voice-audio-\(UUID())")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: working) }
        let prepared = job.channel == .remote ? EchoPreparation() : try EchoCancellation.prepare(
            TranscriptionRequest(recordingID: job.recording.id, chunks: job.recording.audioChunks), store: store, directory: working)
        if command == "enroll-voice" {
            guard let person = people.first(where: { $0.id == job.personID }), let speaker = job.recording.speakers.first(where: { $0.id == job.speakerID }) else { throw VoiceError.consentRequired }
            guard job.channel == .remote ? speaker.source == .system : speaker.source == .mic else { throw VoiceError.invalidVector }
            let vector = try await embedding(recording: job.recording, speaker: speaker, store: store, audioOverrides: prepared.chunks)
            // Recheck enrollment eligibility after the expensive model run.
            guard try await store.people().contains(where: { $0.id == person.id && $0.recognitionEnabled }) else { throw VoiceError.consentRequired }
            try VoiceKeychain.add(vector, person: person.id, channel: job.channel)
            guard var current = try await store.people().first(where: { $0.id == person.id }), current.recognitionEnabled else {
                try VoiceKeychain.remove(person: person.id); throw VoiceError.consentRequired
            }
            current.enrolledChannels = Array(Set((current.enrolledChannels ?? []) + [job.channel])).sorted { $0.rawValue < $1.rawValue }
            current.lastEnrolledAt = Date()
            try await store.savePerson(current)
            return [:]
        }
        return try await identify(recording: job.recording, store: store, channels: [job.channel], audioOverrides: prepared.chunks)
    }
    static func identify(recording: Recording, store: SessionStore, channels: [VoiceChannel] = VoiceChannel.allCases, audioOverrides: [UUID: URL] = [:]) async throws -> [String: VoiceMatch] {
        let people = try await store.people().filter(\.recognitionEnabled)
        guard !people.isEmpty else { return [:] }
        var exemplars: [VoiceChannel: [[[Float]]]] = [:]
        for channel in channels { exemplars[channel] = try people.map { try VoiceKeychain.vectors(person: $0.id, channel: channel) } }
        var speakers: [HWYDCore.Speaker] = []
        var scores: [[Double]] = []
        var winningChannels: [[VoiceChannel]] = []
        for speaker in recording.speakers {
            let eligible = channels.filter { speaker.source == .system ? $0 == .remote : $0 != .remote }
            guard eligible.contains(where: { exemplars[$0]?.contains(where: { !$0.isEmpty }) == true }) else { continue }
            do {
                let vector = try await embedding(recording: recording, speaker: speaker, store: store, audioOverrides: audioOverrides)
                var row: [Double] = [], bestChannels: [VoiceChannel] = []
                for personIndex in people.indices {
                    let ranked = eligible.map { channel in
                        (channel, VoiceResolver.score(vector, exemplars: exemplars[channel]![personIndex]))
                    }.sorted { $0.1 > $1.1 }
                    row.append(ranked[0].1); bestChannels.append(ranked[0].0)
                }
                speakers.append(speaker); scores.append(row); winningChannels.append(bestChannels)
            } catch VoiceError.insufficientSpeech { continue }
        }
        let assignment = VoiceResolver.assign(scores: scores)
        var result: [String: VoiceMatch] = [:]
        for i in speakers.indices {
            guard let candidate = assignment[i] else { continue }
            let ranked = scores[i].sorted(by: >)
            result[speakers[i].id.uuidString] = VoiceMatch(personID: people[candidate].id, score: scores[i][candidate], margin: ranked.count > 1 ? ranked[0] - ranked[1] : nil, channel: winningChannels[i][candidate])
        }
        let stillEnabled = Set(try await store.people().filter(\.recognitionEnabled).map(\.id))
        return result.filter { stillEnabled.contains($0.value.personID) }
    }
}

import AVFoundation
import FluidAudio
import HWYDCore

/// Explicit commands only. Jobs carry IDs and segments, never embeddings.
enum VoiceStage {
    static func embedding(recording: Recording, speaker: HWYDCore.Speaker, store: SessionStore) async throws -> [Float] {
        var samples: [Float] = []
        for segment in recording.segments.filter({ $0.speakerID == speaker.id }).sorted(by: { $0.start < $1.start }) {
            guard segment.end - segment.start >= 0.5,
                  !recording.segments.contains(where: { $0.id != segment.id && $0.source == segment.source && $0.speakerID != segment.speakerID && $0.start < segment.end && $0.end > segment.start }) else { continue }
            for chunk in recording.audioChunks.filter({ $0.source == speaker.source && $0.start < segment.end && $0.start + $0.duration > segment.start }).sorted(by: { $0.start < $1.start }) {
                let file = try AVAudioFile(forReading: store.audioURL(for: chunk), commonFormat: .pcmFormatFloat32, interleaved: false)
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else { throw VoiceError.insufficientSpeech }
                let start = Int64(max(0, segment.start - chunk.start) * 16000)
                let end = min(file.length, Int64((segment.end - chunk.start) * 16000))
                let frames = min(max(0, end - start), Int64(960_000 - samples.count))
                guard frames > 0 else { continue }
                file.framePosition = start
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
                try file.read(into: buffer)
                if let channel = buffer.floatChannelData?[0] { samples += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)) }
            }
            if samples.count >= 960_000 { break }
        }
        guard samples.count >= 320_000 else { throw VoiceError.insufficientSpeech }
        ModelHub.offlineMode = true
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
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
        let people = try await store.people().filter { $0.consentedAt != nil && !$0.opposed }
        if command == "enroll-voice" {
            guard let person = people.first(where: { $0.id == job.personID }), let speaker = job.recording.speakers.first(where: { $0.id == job.speakerID }) else { throw VoiceError.consentRequired }
            guard job.channel == .remote ? speaker.source == .system : speaker.source == .mic else { throw VoiceError.invalidVector }
            let vector = try await embedding(recording: job.recording, speaker: speaker, store: store)
            // Recheck consent immediately before persistence, after the expensive model run.
            guard try await store.people().contains(where: { $0.id == person.id && $0.consentedAt != nil && !$0.opposed }) else { throw VoiceError.consentRequired }
            try VoiceKeychain.add(vector, person: person.id, channel: job.channel); return [:]
        }
        var clusters: [(HWYDCore.Speaker, [Float])] = []
        for speaker in job.recording.speakers where (job.channel == .remote ? speaker.source == .system : speaker.source == .mic) {
            do { clusters.append((speaker, try await embedding(recording: job.recording, speaker: speaker, store: store))) }
            catch VoiceError.insufficientSpeech { continue }
        }
        let exemplars = try people.map { try VoiceKeychain.vectors(person: $0.id, channel: job.channel) }
        let scores = clusters.map { cluster in exemplars.map { VoiceResolver.score(cluster.1, exemplars: $0) } }
        let assignment = VoiceResolver.assign(scores: scores)
        var result: [String: VoiceMatch] = [:]
        for i in clusters.indices {
            guard let candidate = assignment[i] else { continue }
            let ranked = scores[i].sorted(by: >)
            result[clusters[i].0.id.uuidString] = VoiceMatch(personID: people[candidate].id, score: scores[i][candidate], margin: ranked.count > 1 ? ranked[0] - ranked[1] : nil, channel: job.channel)
        }
        return result
    }
}

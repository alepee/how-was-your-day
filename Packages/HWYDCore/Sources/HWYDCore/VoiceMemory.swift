import Foundation

/// Proposed people, by speaker ID.
public typealias VoiceMatches = [UUID: VoiceMatch]

/// The voice prints of known people. The app's adapter runs the bundled `hwyd-pipeline`, the only
/// process that reads the keychain; no vector crosses this interface. `InMemoryVoiceMemory`
/// answers in tests.
public protocol VoiceMemory: Sendable {
    /// Adds a sample of one voice of `recording` to the person's print, then looks again for its
    /// other voices. The person must be eligible in the people store (`recognitionEnabled`): callers
    /// go through `EnrollVoice`, which records the user's request first.
    func enroll(speakerID: UUID, in recording: Recording, as personID: UUID) async throws -> VoiceMatches
    /// Proposes a known person for the voices of `recording`.
    func identify(in recording: Recording) async throws -> VoiceMatches
    /// Erases every sample of the person.
    func forget(personID: UUID) async throws
    /// Withdraws what one session added (nil: samples of unknown origin).
    func forget(personID: UUID, source recordingID: UUID?) async throws
    /// What each session added to the person's print.
    func sources(personID: UUID) async throws -> [VoiceContribution]
}

/// Keeps who was enrolled from which session, never a vector. Identification answers `matches`.
public actor InMemoryVoiceMemory: VoiceMemory {
    public struct Sample: Equatable, Sendable {
        public var personID: UUID
        public var recordingID: UUID
        public var speakerID: UUID
        public var channel: VoiceChannel
    }
    public private(set) var samples: [Sample] = []
    public private(set) var matches: VoiceMatches
    public init(matches: VoiceMatches = [:]) { self.matches = matches }
    public func setMatches(_ matches: VoiceMatches) { self.matches = matches }
    public func enroll(speakerID: UUID, in recording: Recording, as personID: UUID) async throws -> VoiceMatches {
        guard let speaker = recording.speakers.first(where: { $0.id == speakerID }) else { throw StoreError.notFound }
        samples.append(Sample(personID: personID, recordingID: recording.id, speakerID: speakerID, channel: VoiceChannel(source: speaker.source)))
        return matches.filter { $0.key != speakerID }
    }
    public func identify(in recording: Recording) async throws -> VoiceMatches {
        let ids = Set(recording.speakers.map(\.id))
        return matches.filter { ids.contains($0.key) }
    }
    public func forget(personID: UUID) async throws { samples.removeAll { $0.personID == personID } }
    public func forget(personID: UUID, source recordingID: UUID?) async throws {
        samples.removeAll { $0.personID == personID && $0.recordingID == recordingID }
    }
    public func sources(personID: UUID) async throws -> [VoiceContribution] {
        let own = samples.filter { $0.personID == personID }
        return Dictionary(grouping: own) { [$0.recordingID.uuidString, $0.channel.rawValue] }.values.compactMap { group in
            group.first.map { VoiceContribution(recordingID: $0.recordingID, channel: $0.channel, count: group.count, addedAt: nil) }
        }.sorted { $0.id < $1.id }
    }
}

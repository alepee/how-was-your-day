import Foundation

/// Where known people and their enrollment state live: `SessionStore` in the app,
/// `InMemoryVoicePeople` in tests.
public protocol VoicePeople: Sendable {
    func people() async throws -> [VoicePerson]
    /// Refuses (`VoiceError.consentRequired`) to save an unopposed person over an opposed one.
    func savePerson(_ person: VoicePerson) async throws
}
extension SessionStore: VoicePeople {}

public actor InMemoryVoicePeople: VoicePeople {
    private var stored: [VoicePerson]
    public init(_ people: [VoicePerson] = []) { stored = people }
    public func people() async throws -> [VoicePerson] { stored }
    public func savePerson(_ person: VoicePerson) async throws {
        guard !person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidName }
        if !person.opposed, stored.contains(where: { $0.opposed && ($0.id == person.id || $0.name.compare(person.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame) }) {
            throw VoiceError.consentRequired
        }
        if let index = stored.firstIndex(where: { $0.id == person.id }) { stored[index] = person } else { stored.append(person) }
    }
}

/// Why a voice cannot be memorized under a name.
public enum EnrollmentRefusal: Error, Equatable, Sendable {
    /// Empty, or longer than 120 characters.
    case invalidName
    /// The person opposed recognition.
    case opposed(VoicePerson)
}

/// Memorizes a voice under a person's name, on the user's explicit request only. A speaker
/// correction never leads here: renaming, linking or merging voices reads and writes no print.
public struct EnrollVoice: Sendable {
    public struct Outcome: Sendable {
        /// The person as saved after enrollment.
        public var person: VoicePerson
        /// Everyone, after enrollment.
        public var people: [VoicePerson]
        /// Other voices of the session that now resemble a known person.
        public var matches: VoiceMatches
    }
    public let people: any VoicePeople
    public let memory: any VoiceMemory
    public init(people: any VoicePeople, memory: any VoiceMemory) { self.people = people; self.memory = memory }

    /// The person a voice is memorized as. The voice's current person keeps it when the name is
    /// unchanged; otherwise a person with the same name, ignoring case and accents; otherwise a
    /// new person. An opposed person is refused.
    public static func person(named name: String, for speaker: Speaker, among people: [VoicePerson]) throws(EnrollmentRefusal) -> VoicePerson {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw .invalidName }
        let person = people.first { $0.id == speaker.personID && $0.name == name }
            ?? people.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } ?? VoicePerson(name: name)
        guard !person.opposed else { throw .opposed(person) }
        return person
    }

    /// Records the user's request on the person, then adds the voice's sample to their print.
    public func callAsFunction(_ person: VoicePerson, speakerID: UUID, in recording: Recording, at date: Date = Date()) async throws -> Outcome {
        guard !person.opposed else { throw EnrollmentRefusal.opposed(person) }
        var person = person
        person.enrollmentRequestedAt = date
        try await people.savePerson(person)
        let matches = try await memory.enroll(speakerID: speakerID, in: recording, as: person.id)
        let everyone = try await people.people()
        return Outcome(person: everyone.first { $0.id == person.id } ?? person, people: everyone, matches: matches)
    }
}

extension Recording {
    /// After an enrollment: the voice is confirmed as the person, and the other voices show who
    /// they resemble. Returns how many were proposed.
    @discardableResult
    public mutating func applyEnrollment(_ outcome: EnrollVoice.Outcome, speakerID: UUID) throws -> Int {
        try linkSpeaker(speakerID, to: outcome.person)
        return proposeIdentities(outcome.matches, people: outcome.people)
    }
}

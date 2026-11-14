import Foundation

/// What a voice memory request did, for the presentation to tell the user.
public enum VoiceOutcome: Equatable, Sendable {
    /// The voice was memorized and `proposals` other voices of the session now resemble a known person.
    case enrolled(name: String, proposals: Int)
    /// The voice was memorized, but the session changed meanwhile: its transcript was left as it is.
    case enrolledSessionChanged(name: String)
    /// `proposals` voices of the session resemble a known person.
    case identified(proposals: Int)
    /// The session changed during recognition: nothing was proposed.
    case identificationSessionChanged
    /// What each session added to a person's print was read.
    case sourcesRead
    case forgotten(name: String)
    /// The opposition is recorded and the print erased.
    case opposed(name: String)
    /// What one session added to the print was withdrawn.
    case contributionWithdrawn(name: String)
    case oppositionLifted(name: String)
}

/// The result of a voice memory request: what happened, and the state the app shows next.
public struct VoiceResult: Equatable, Sendable {
    public var outcome: VoiceOutcome
    /// Everyone, as the people store holds them after the request.
    public var people: [VoicePerson]
    /// What changed in a person's contributions, when the request read or changed them.
    public var contributions: VoiceContributionChange?
}

/// What a request did to the contributions of one person's print.
public enum VoiceContributionChange: Equatable, Sendable {
    case read(personID: UUID, [VoiceContribution])
    /// The print is erased: nothing is left to list.
    case cleared(personID: UUID)
    /// What one session added (nil: samples of unknown origin) is gone.
    case withdrawn(personID: UUID, source: UUID?)
}

/// The app's voice memory requests as use cases. Each one goes through the people store and the
/// `VoiceMemory` port, applies what concerns a session through its `SessionLibrary` (an outdated
/// result changes nothing), and returns a typed `VoiceResult`; the presentation words the notice.
/// Enrollment goes through `EnrollVoice` only.
@MainActor public struct VoiceRequests {
    public let people: any VoicePeople
    public let memory: any VoiceMemory
    public init(people: any VoicePeople, memory: any VoiceMemory) { self.people = people; self.memory = memory }

    /// Memorizes a voice of `recording`, then shows who its other voices resemble.
    public func enroll(_ person: VoicePerson, speakerID: UUID, in recording: Recording, library: SessionLibrary) async throws -> VoiceResult {
        let outcome = try await EnrollVoice(people: people, memory: memory)(person, speakerID: speakerID, in: recording)
        let name = outcome.person.name
        var proposed = 0
        // A transcript edited meanwhile, here or elsewhere, keeps the user's version.
        do {
            try await library.apply(recording.id, ifStillAt: recording.transcriptVersion) { current in
                proposed = (try? current.applyEnrollment(outcome, speakerID: speakerID)) ?? 0
            }
        } catch is StaleResult {
            return VoiceResult(outcome: .enrolledSessionChanged(name: name), people: outcome.people)
        } catch is UnsavedResult {
            // The proposals stay pending; the library reported the save failure.
        }
        return VoiceResult(outcome: .enrolled(name: name, proposals: proposed), people: outcome.people)
    }

    /// Proposes a known person for the unconfirmed voices of `recording`.
    public func identify(in recording: Recording, library: SessionLibrary) async throws -> VoiceResult {
        let matches = try await memory.identify(in: recording)
        let everyone = try await people.people()
        var proposed = 0
        do {
            try await library.apply(recording.id, ifStillAt: recording.transcriptVersion) { proposed = $0.proposeIdentities(matches, people: everyone) }
        } catch is StaleResult {
            return VoiceResult(outcome: .identificationSessionChanged, people: everyone)
        } catch is UnsavedResult {
            // The proposals stay pending; the library reported the save failure.
        }
        return VoiceResult(outcome: .identified(proposals: proposed), people: everyone)
    }

    /// Reads what each session added to a person's print.
    public func sources(of personID: UUID) async throws -> VoiceResult {
        let sources = try await memory.sources(personID: personID)
        return VoiceResult(outcome: .sourcesRead, people: try await people.people(), contributions: .read(personID: personID, sources))
    }

    /// Erases a person's print. The name stays in sessions; the voice can be memorized again.
    public func forget(_ person: VoicePerson) async throws -> VoiceResult {
        try await memory.forget(personID: person.id)
        return VoiceResult(outcome: .forgotten(name: person.name), people: try await people.people(), contributions: .cleared(personID: person.id))
    }

    /// Records the person's opposition, then erases their print. Also retries an erasure that
    /// failed after an opposition: the opposition is saved first and stays if the erasure fails.
    public func oppose(_ person: VoicePerson) async throws -> VoiceResult {
        var opposed = person; opposed.opposed = true; opposed.consentedAt = nil
        try await people.savePerson(opposed)
        try await memory.forget(personID: opposed.id)
        return VoiceResult(outcome: .opposed(name: opposed.name), people: try await people.people(), contributions: .cleared(personID: opposed.id))
    }

    /// Withdraws what one session added to a person's print.
    public func withdraw(_ recordingID: UUID?, of person: VoicePerson) async throws -> VoiceResult {
        try await memory.forget(personID: person.id, source: recordingID)
        return VoiceResult(outcome: .contributionWithdrawn(name: person.name), people: try await people.people(),
                           contributions: .withdrawn(personID: person.id, source: recordingID))
    }

    /// Ends an opposition. Any sample left by an interrupted erasure goes first, so recognition
    /// resumes only after a new enrollment.
    public func liftOpposition(_ person: VoicePerson) async throws -> VoiceResult {
        try await memory.forget(personID: person.id)
        try await people.liftOpposition(person.id)
        return VoiceResult(outcome: .oppositionLifted(name: person.name), people: try await people.people(), contributions: .cleared(personID: person.id))
    }
}

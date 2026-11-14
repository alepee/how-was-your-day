import Foundation

/// Stands in for the pipeline helper while the examples show: every request is refused with
/// `WorkRefusal.examples`, before any work is queued, and nothing is read or written.
public struct ExamplePipeline: TranscriptionService, VoiceMemory, SpeechModelCatalog {
    public init() {}
    public var refusal: WorkRefusal? { .examples }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult { throw WorkRefusal.examples }

    public func enroll(speakerID: UUID, in recording: Recording, as personID: UUID) async throws -> VoiceMatches { throw WorkRefusal.examples }
    public func identify(in recording: Recording) async throws -> VoiceMatches { throw WorkRefusal.examples }
    public func forget(personID: UUID) async throws { throw WorkRefusal.examples }
    public func forget(personID: UUID, source recordingID: UUID?) async throws { throw WorkRefusal.examples }
    public func sources(personID: UUID) async throws -> [VoiceContribution] { throw WorkRefusal.examples }

    public func locales() async throws -> SpeechLocales { throw WorkRefusal.examples }
    public func install(locale: String) async throws { throw WorkRefusal.examples }
    public func diarizerReady() async -> Bool { false }
    public func installDiarizer() async throws { throw WorkRefusal.examples }
}

/// A summarizer that refuses to run in this mode. It shows the configured summarizer's
/// availability and disclosure, so the summary tab reads the same with the examples, and refuses
/// the request itself with `refusal`.
public struct RefusingSummarizer: Summarizer {
    public let shown: any Summarizer
    public let reason: WorkRefusal
    public init(showing shown: any Summarizer, refusal: WorkRefusal = .examples) { self.shown = shown; self.reason = refusal }
    public var refusal: WorkRefusal? { reason }
    public var availability: SummaryAvailability { shown.availability }
    public var disclosure: SummaryDisclosure { shown.disclosure }
    public func summarize(_ recording: Recording, progress: @escaping @Sendable (SummaryProgress) async -> Void) async throws -> SummaryProvenance {
        throw reason
    }
}

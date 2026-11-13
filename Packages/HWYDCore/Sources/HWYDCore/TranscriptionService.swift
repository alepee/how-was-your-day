import Foundation

/// Turns a session's audio into a transcript. The app's adapter runs the bundled `hwyd-pipeline`;
/// `InMemoryTranscriptionService` answers in tests. Cancelling the calling task stops the work.
public protocol TranscriptionService: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

extension TranscriptionRequest {
    /// The request for a session. The language is `language` when given, otherwise the session's
    /// choice, and French for sessions recorded before the choice existed. With automatic detection,
    /// candidates, fallback and installable languages come from `locales`, the languages the
    /// transcribing process can use.
    public init(session: Recording, language: String? = nil, diarize: Bool, locales: SpeechLocales,
                preferredLanguages: [String] = Locale.preferredLanguages) {
        self.init(recordingID: session.id, locale: language ?? session.speechLanguage ?? SpeechLanguage.defaultLocale,
                  chunks: session.audioChunks, diarize: diarize)
        self = resolvingLanguages(locales, preferredLanguages: preferredLanguages)
    }
}

/// Records each request and answers with `respond`. No audio is read.
public actor InMemoryTranscriptionService: TranscriptionService {
    public private(set) var requests: [TranscriptionRequest] = []
    private let respond: @Sendable (TranscriptionRequest) async throws -> TranscriptionResult
    public init(_ respond: @escaping @Sendable (TranscriptionRequest) async throws -> TranscriptionResult) { self.respond = respond }
    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        requests.append(request)
        try Task.checkCancellation()
        return try await respond(request)
    }
}

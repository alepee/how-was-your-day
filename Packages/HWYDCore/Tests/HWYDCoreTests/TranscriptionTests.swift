import XCTest
@testable import HWYDCore

final class TranscriptionTests: XCTestCase, @unchecked Sendable {
    func testResultsPreserveLatestNotesAndInvalidateSummary() throws {
        var recording = Recording(title: "Test", notes: "Notes pendant le traitement", summary: "Ancienne synthèse")
        recording.audioChunks = [.init(source: .mic, relativePath: "mic.caf", start: 300, duration: 5)]
        let request = TranscriptionRequest(recordingID: recording.id, chunks: recording.audioChunks)
        let segment = TranscriptSegment(start: 301, end: 302, speakerID: nil, source: .mic, text: "Bonjour")
        try recording.applyTranscription(.init(request: request, segments: [segment]))
        XCTAssertEqual(recording.notes, "Notes pendant le traitement")
        XCTAssertEqual(recording.transcriptVersion, 1)
        XCTAssertEqual(recording.transcriptState, .ready)
        XCTAssertNil(recording.summary)
        XCTAssertTrue(recording.speakers.isEmpty)
        XCTAssertNil(recording.segments.first?.speakerID)
    }
    func testRejectsResultFromDifferentAudio() throws {
        var recording = Recording(title: "Test")
        let request = TranscriptionRequest(recordingID: recording.id, chunks: [.init(source: .mic, relativePath: "old.caf", start: 0, duration: 1)])
        XCTAssertThrowsError(try recording.applyTranscription(.init(request: request, segments: [])))
        XCTAssertEqual(recording.transcriptVersion, 0)
    }
    func testOldPayloadWithoutWordsStillDecodes() throws {
        let segment = TranscriptSegment(start: 0, end: 1, speakerID: nil, source: .mic, text: "Bonjour")
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertNil(decoded.words)
    }
    func testPipelineMergesTracksBySessionTimeWithoutInventingSpeakers() async throws {
        let audio = try TemporaryAudioLocator()
        let request = TranscriptionRequest(recordingID: UUID(), chunks: [
            .init(source: .mic, relativePath: "mic.caf", start: 300, duration: 5),
            .init(source: .system, relativePath: "system.caf", start: 0, duration: 5)])
        let result = try await TranscriptionPipeline.run(request, audio: audio, recognizer: FakeRecognizer())
        XCTAssertEqual(result.segments.map(\.start), [1, 301])
        XCTAssertEqual(result.segments.map(\.source), [.system, .mic])
        XCTAssertTrue(result.segments.allSatisfy { $0.speakerID == nil })
    }
    private func detect(_ recognizer: LanguageFake, candidates: [String] = ["fr-FR", "en-US"], fallback: String = "fr-FR",
                        installable: [String] = ["es-ES", "de-DE"], system: Bool = false) async throws -> TranscriptionResult {
        let audio = try TemporaryAudioLocator()
        var chunks: [AudioChunk] = [.init(source: .mic, relativePath: "mic.caf", start: 0, duration: 5)]
        if system { chunks.append(.init(source: .system, relativePath: "system.caf", start: 0, duration: 5)) }
        let request = TranscriptionRequest(recordingID: UUID(), locale: SpeechLanguage.automatic, chunks: chunks,
                                           candidateLocales: candidates, fallbackLocale: fallback, installableLocales: installable)
        return try await TranscriptionPipeline.run(request, audio: audio, recognizer: recognizer)
    }
    func testDetectionSwitchesToEnglishWhenTextAndConfidenceAgree() async throws {
        let result = try await detect(LanguageFake(mic: "en"))
        XCTAssertEqual(result.request.locale, "en-US")
        XCTAssertEqual(result.languageDetection?.first?.method, .detected)
        XCTAssertEqual(result.segments.first?.text, "transcribed in en-US")
    }
    func testDetectionKeepsFallbackForFrenchSpeech() async throws {
        let result = try await detect(LanguageFake(mic: "fr"))
        XCTAssertEqual(result.request.locale, "fr-FR")
        XCTAssertEqual(result.languageDetection?.first?.method, .detected)
        XCTAssertNil(result.languageDetection?.first?.suggestedLocale)
    }
    func testDetectionFallsBackOnSilence() async throws {
        let result = try await detect(LanguageFake(mic: nil), fallback: "en-US")
        XCTAssertEqual(result.request.locale, "en-US")
        XCTAssertEqual(result.languageDetection?.first?.method, .fallback)
        XCTAssertNil(result.languageDetection?.first?.unrecognized)
    }
    func testDetectionKeepsFallbackWhenSecondPassIsLessConfident() async throws {
        let result = try await detect(LanguageFake(mic: "en", matchConfidence: 0.5))
        XCTAssertEqual(result.request.locale, "fr-FR")
    }
    func testEachTrackGetsItsOwnLanguage() async throws {
        let result = try await detect(LanguageFake(mic: "fr", system: "en"), system: true)
        XCTAssertEqual(result.languageDetection?.map(\.locale), ["fr-FR", "en-US"])
        XCTAssertEqual(result.segments.map(\.text).sorted(), ["transcribed in en-US", "transcribed in fr-FR"])
        let provenance = TranscriptionProvenance(engine: result.engine, locale: result.request.locale, createdAt: result.createdAt, languageDetection: result.languageDetection)
        XCTAssertEqual(provenance.locale(for: .system), "en-US")
        XCTAssertEqual(provenance.locale(for: .mic), "fr-FR")
    }
    func testSuggestsInstallingAnIdentifiedLanguage() async throws {
        let result = try await detect(LanguageFake(mic: "es"))
        XCTAssertEqual(result.languageDetection?.first?.suggestedLocale, "es-ES")
        XCTAssertEqual(result.languageDetection?.first?.method, .fallback)
    }
    func testDoesNotSuggestALanguageThatCannotBeInstalled() async throws {
        let result = try await detect(LanguageFake(mic: "es"), installable: ["de-DE"])
        XCTAssertNil(result.languageDetection?.first?.suggestedLocale)
    }
    func testFlagsSpeechNoInstalledModelFits() async throws {
        let result = try await detect(LanguageFake(mic: "unknown"))
        XCTAssertEqual(result.languageDetection?.first?.unrecognized, true)
        XCTAssertNil(result.languageDetection?.first?.suggestedLocale)
    }
    func testSingleCandidateStillTranscribesWithIt() async throws {
        let result = try await detect(LanguageFake(mic: "fr"), candidates: ["fr-FR", "fr-CA"])
        XCTAssertEqual(result.request.locale, "fr-FR")
        XCTAssertEqual(result.languageDetection?.first?.method, .fallback)
    }
    func testChineseIsMatchedThroughNaturalLanguageScripts() {
        let hypothesis = TranscriptionPipeline.hypothesis("好的，我们开始吧。第一个议题是季度计划。你能给我们介绍一下数据吗？", among: ["fr-FR", "zh-CN"])
        XCTAssertNotNil(hypothesis)
        XCTAssertTrue(SpeechLanguage.matches("zh-CN", hypothesis!.language))
        XCTAssertTrue(SpeechLanguage.matches("yue-CN", .traditionalChinese))
        XCTAssertFalse(SpeechLanguage.matches("fr-FR", .simplifiedChinese))
    }
    func testSampleSpansShortFirstChunks() async throws {
        let audio = try TemporaryAudioLocator()
        let recognizer = ChunkedFake()
        let request = TranscriptionRequest(recordingID: UUID(), locale: SpeechLanguage.automatic, chunks: [
            .init(source: .mic, relativePath: "a.caf", start: 0, duration: 3),
            .init(source: .mic, relativePath: "b.caf", start: 3, duration: 300)], candidateLocales: ["fr-FR", "en-US"], fallbackLocale: "fr-FR")
        let result = try await TranscriptionPipeline.run(request, audio: audio, recognizer: recognizer)
        XCTAssertEqual(result.request.locale, "en-US")
        XCTAssertEqual(recognizer.requestedSeconds.value.prefix(2).map { $0 }, [3, 87])
    }
    func testHelperResolvesLanguagesItCanUse() {
        let request = TranscriptionRequest(recordingID: UUID(), locale: SpeechLanguage.automatic, chunks: [], candidateLocales: [], fallbackLocale: nil)
        let resolved = request.resolvingLanguages(SpeechLocales(installed: ["en-GB", "en-US", "fr-FR"], supported: ["de-DE", "en-US", "fr-FR", "fr-CA"]), preferredLanguages: ["fr-FR"])
        XCTAssertEqual(resolved.fallbackLocale, "fr-FR")
        XCTAssertEqual(Set(resolved.candidateLocales ?? []).count, 2)
        XCTAssertEqual(resolved.installableLocales, ["de-DE"])
        let forced = TranscriptionRequest(recordingID: UUID(), locale: "fr-FR", chunks: [])
        XCTAssertNil(forced.resolvingLanguages(SpeechLocales(installed: [], supported: [])).candidateLocales)
    }
    func testProvenanceWithoutLanguageDetectionDecodes() throws {
        let json = #"{"engine":"apple-speech-transcriber-v1","locale":"fr-FR","createdAt":0}"#
        let provenance = try JSONDecoder().decode(TranscriptionProvenance.self, from: Data(json.utf8))
        XCTAssertNil(provenance.languageDetection)
        XCTAssertEqual(provenance.locale(for: .system), "fr-FR")
    }
    func testOneLocalePerLanguagePrefersUserRegionThenCanonical() {
        XCTAssertEqual(SpeechLanguage.oneLocalePerLanguage(["en_AU", "en_GB", "en_US", "fr_CA", "fr_FR"], preferredRegion: "GB"), ["en-GB", "fr-FR"])
        XCTAssertEqual(SpeechLanguage.oneLocalePerLanguage(["fr_CA", "fr_FR", "en_AU"], preferredRegion: "CA"), ["fr-CA", "en-AU"])
        XCTAssertEqual(SpeechLanguage.oneLocalePerLanguage(["en_AU", "en_US"], preferredRegion: nil), ["en-US"])
    }
    func testFallbackFollowsPreferredLanguages() {
        XCTAssertEqual(SpeechLanguage.fallback(installed: ["en_US", "fr_FR"], preferredLanguages: ["en-FR", "fr-FR"]), "en-US")
        XCTAssertEqual(SpeechLanguage.fallback(installed: ["en_US", "fr_FR"], preferredLanguages: ["de-DE"]), "fr-FR")
        XCTAssertEqual(SpeechLanguage.fallback(installed: [], preferredLanguages: ["de-DE"]), "fr-FR")
    }
    func testOldRecordingWithoutSpeechLanguageDecodes() throws {
        var recording = Recording(title: "Ancienne")
        recording.speechLanguage = nil
        let decoded = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(recording))
        XCTAssertNil(decoded.speechLanguage)
    }
}
/// Simulates a recognizer that writes what it hears with the requested model: the right model is
/// confident, the wrong one is not, and the text stays identifiable either way.
private struct LanguageFake: SpeechRecognizing {
    var mic: String?
    var system: String?
    var matchConfidence = 0.94
    static let texts = [
        "en": "Hi everyone, quick status on the project. The database migration is planned for Thursday and two tickets remain.",
        "fr": "Bonjour à tous, on fait le point sur le projet. La migration de la base est prévue jeudi et il reste deux tickets.",
        "es": "Bueno, empezamos. El primer punto es la planificación del trimestre. ¿Puedes presentarnos las cifras del mes pasado?",
        "unknown": "so they by hajime masho sai sho no gidai wa shihanki no keikaku desu sara san suji wo"]
    func sample(file: URL, chunk: AudioChunk, locale: String, seconds: Double) async throws -> SpeechSample {
        guard let spoken = chunk.source == .mic ? mic : system, let text = Self.texts[spoken] else { return SpeechSample(text: "", confidence: nil) }
        if spoken == "unknown" { return SpeechSample(text: text, confidence: 0.2) }
        let matches = SpeechLanguage.languageCode(of: locale) == spoken
        return SpeechSample(text: text, confidence: matches ? (spoken == "fr" ? 0.96 : matchConfidence) : 0.8)
    }
    func transcribe(file: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment] {
        [.init(start: chunk.start + 1, end: chunk.start + 2, speakerID: nil, source: chunk.source, text: "transcribed in \(locale)")]
    }
}
/// English speech spread over a 3 s chunk and a long one; records the seconds asked per sample.
private final class ChunkedFake: SpeechRecognizing, @unchecked Sendable {
    let requestedSeconds = Locked<[Double]>([])
    func sample(file: URL, chunk: AudioChunk, locale: String, seconds: Double) async throws -> SpeechSample {
        requestedSeconds.mutate { $0.append(seconds) }
        let matches = SpeechLanguage.languageCode(of: locale) == "en"
        let text = chunk.duration < 10 ? "Hi" : "Hi everyone, quick status on the project. The database migration is planned for Thursday."
        return SpeechSample(text: text, confidence: matches ? 0.95 : 0.8)
    }
    func transcribe(file: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment] { [] }
}
final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
private struct FakeRecognizer: SpeechRecognizing {
    func transcribe(file: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment] {
        [.init(start: chunk.start + 1, end: chunk.start + 2, speakerID: nil, source: chunk.source, text: "Bonjour")]
    }
}

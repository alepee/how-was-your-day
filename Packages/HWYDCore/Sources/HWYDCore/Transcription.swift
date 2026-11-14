import Foundation
import AVFoundation
import Speech
import NaturalLanguage

public struct TranscriptWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public struct TranscriptionRequest: Codable, Sendable {
    public var recordingID: UUID
    public var locale: String
    public var chunks: [AudioChunk]
    public var diarize: Bool?
    public var echoCancellation: Bool?
    /// With `locale == SpeechLanguage.automatic`, the languages the pipeline may detect. One locale per language.
    public var candidateLocales: [String]?
    /// Locale used when detection is not conclusive (silence, too little speech, single candidate).
    public var fallbackLocale: String?
    /// Supported but not installed locales, which detection may suggest installing.
    public var installableLocales: [String]?
    public init(recordingID: UUID, locale: String = "fr-FR", chunks: [AudioChunk], diarize: Bool = false,
                candidateLocales: [String]? = nil, fallbackLocale: String? = nil, installableLocales: [String]? = nil) {
        self.recordingID = recordingID; self.locale = locale; self.chunks = chunks; self.diarize = diarize
        self.candidateLocales = candidateLocales; self.fallbackLocale = fallbackLocale; self.installableLocales = installableLocales
    }
}
/// How one track's transcription locale was chosen when the session asked for automatic detection.
public struct LanguageDetection: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        /// The text of a sample agreed with the candidate's own confidence.
        case detected
        /// Too little speech, a single candidate, or an inconclusive sample.
        case fallback
    }
    public var source: AudioSource
    public var locale: String
    public var method: Method
    /// Mean word confidence of the retained locale on the sample, when measured.
    public var confidence: Double?
    /// A supported language that is not installed and that the sample appears to be in.
    public var suggestedLocale: String?
    /// No installed model fits the sample and its language could not be identified.
    public var unrecognized: Bool?
    public init(source: AudioSource, locale: String, method: Method, confidence: Double? = nil, suggestedLocale: String? = nil, unrecognized: Bool? = nil) {
        self.source = source; self.locale = locale; self.method = method; self.confidence = confidence
        self.suggestedLocale = suggestedLocale; self.unrecognized = unrecognized
    }
}
public struct TranscriptionProvenance: Codable, Equatable, Sendable {
    public var engine: String
    public var diarizationEngine: String?
    public var echoCancellationEngine: String?
    public var locale: String
    public var createdAt: Date
    /// One entry per track when the locale was detected rather than chosen.
    public var languageDetection: [LanguageDetection]?
    /// Locale of a track, which may differ from `locale` (the microphone's) after detection.
    public func locale(for source: AudioSource) -> String {
        languageDetection?.first { $0.source == source }?.locale ?? locale
    }
}
public struct TranscriptionResult: Codable, Sendable {
    public var identityWarning: String?
    public var request: TranscriptionRequest
    public var engine: String
    public var diarizationEngine: String?
    public var echoCancellationEngine: String?
    public var createdAt: Date
    public var segments: [TranscriptSegment]
    public var speakers: [Speaker]?
    public var languageDetection: [LanguageDetection]?
    public init(request: TranscriptionRequest, segments: [TranscriptSegment]) {
        self.request = request; self.segments = segments; engine = "apple-speech-transcriber-v1"; createdAt = Date()
    }
}
public enum TranscriptionError: LocalizedError {
    case unavailable, unsupportedLocale(String), missingAssets(String), invalidAudio, staleResult
    public var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "La transcription Apple n’est pas disponible sur ce Mac.", bundle: .hwyd)
        case .unsupportedLocale(let locale): String(localized: "La langue \(locale) n’est pas prise en charge par SpeechTranscriber sur ce Mac.", bundle: .hwyd)
        case .missingAssets(let locale): String(localized: "Le modèle \(locale) doit être installé. Installez cette langue dans Réglages, Audio et voix.", bundle: .hwyd)
        case .invalidAudio: String(localized: "Aucune tranche audio valide à transcrire.", bundle: .hwyd)
        case .staleResult: String(localized: "Le résultat ne correspond plus aux fichiers de cette session.", bundle: .hwyd)
        }
    }
}
public protocol SpeechRecognizing: Sendable {
    func transcribe(file: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment]
    /// Transcribes at most the first `seconds` of a chunk for language detection.
    func sample(file: URL, chunk: AudioChunk, locale: String, seconds: Double) async throws -> SpeechSample
}
public struct SpeechSample: Sendable, Equatable {
    public var text: String
    /// Mean word confidence in 0...1, nil when the engine reports none.
    public var confidence: Double?
    public init(text: String, confidence: Double?) { self.text = text; self.confidence = confidence }
}
extension SpeechRecognizing {
    public func sample(file: URL, chunk: AudioChunk, locale: String, seconds: Double) async throws -> SpeechSample {
        let text = try await transcribe(file: file, chunk: chunk, locale: locale).filter { $0.start - chunk.start < seconds }.map(\.text).joined(separator: " ")
        return SpeechSample(text: text, confidence: nil)
    }
}
public actor AppleSpeechRecognizer: SpeechRecognizing {
    public init() {}
    private func module(locale: String, confidence: Bool = false) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw TranscriptionError.unsupportedLocale(locale)
        }
        return SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                 attributeOptions: confidence ? [.audioTimeRange, .transcriptionConfidence] : [.audioTimeRange])
    }
    public func sample(file: URL, chunk: AudioChunk, locale: String, seconds: Double) async throws -> SpeechSample {
        let transcriber = try await module(locale: locale, confidence: true)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw TranscriptionError.missingAssets(locale) }
        let source = try AVAudioFile(forReading: file)
        let frames = AVAudioFrameCount(min(Double(source.length), seconds * source.processingFormat.sampleRate))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frames) else { return SpeechSample(text: "", confidence: nil) }
        try source.read(into: buffer, frameCount: frames)
        // The excerpt stays in memory: no copy of the audio is written outside the store.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw TranscriptionError.invalidAudio }
        let input = try Self.convert(buffer, to: format)
        let collector = Task { () throws -> SpeechSample in
            var text: [String] = [], confidences: [Double] = []
            for try await result in transcriber.results where result.isFinal {
                text.append(String(result.text.characters))
                for run in result.text.runs { if let value = run.transcriptionConfidence { confidences.append(value) } }
            }
            return SpeechSample(text: text.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                                confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count))
        }
        do {
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            continuation.yield(AnalyzerInput(buffer: input)); continuation.finish()
            try await analyzer.start(inputSequence: stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } catch {
            await analyzer.cancelAndFinishNow(); collector.cancel(); _ = try? await collector.value
            throw error
        }
    }
    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != format else { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1024) else {
            throw TranscriptionError.invalidAudio
        }
        nonisolated(unsafe) var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, failure == nil else { throw failure ?? TranscriptionError.invalidAudio }
        return output
    }
    public func install(locale: String) async throws {
        let transcriber = try await module(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
    public func transcribe(file: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment] {
        let transcriber = try await module(locale: locale)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw TranscriptionError.missingAssets(locale) }
        let audio = try AVAudioFile(forReading: file)
        guard audio.length > 0 else { return [] }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                guard start.isFinite, end.isFinite, start >= 0, end >= start else { throw TranscriptionError.invalidAudio }
                var segment = TranscriptSegment(start: chunk.start + start, end: chunk.start + end, speakerID: nil, source: chunk.source, text: text)
                segment.words = result.text.runs.compactMap { run in
                    guard let range = run.audioTimeRange, range.start.seconds.isFinite, range.end.seconds.isFinite else { return nil }
                    return TranscriptWord(text: String(result.text[run.range].characters), start: chunk.start + range.start.seconds, end: chunk.start + range.end.seconds)
                }
                segments.append(segment)
            }
            return segments
        }
        do {
            _ = try await analyzer.analyzeSequence(from: audio)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            _ = try? await collector.value
            throw error
        }
    }
    /// Locales usable by this process and locales it can install, in BCP 47 form. Apple Speech
    /// reserves assets per application: a language present on the Mac for another app still needs
    /// an install here, so only the calling process can answer. The app asks the pipeline helper.
    public static func locales() async -> SpeechLocales {
        guard SpeechTranscriber.isAvailable else { return SpeechLocales(installed: [], supported: []) }
        var installed: [String] = []
        for locale in await SpeechTranscriber.installedLocales {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            if await AssetInventory.status(forModules: [module]) == .installed { installed.append(SpeechLanguage.normalized(locale.identifier)) }
        }
        let supported = await SpeechTranscriber.supportedLocales.map { SpeechLanguage.normalized($0.identifier) }
        return SpeechLocales(installed: installed.sorted(), supported: supported.sorted())
    }
    public static func diagnostics() async -> String {
        let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
        return "available=\(SpeechTranscriber.isAvailable)\nsupported=\(supported.joined(separator: ","))\ninstalled=\(installed.joined(separator: ","))"
    }
}

public struct SpeechLocales: Codable, Equatable, Sendable {
    public var installed: [String]
    public var supported: [String]
    public init(installed: [String], supported: [String]) { self.installed = installed; self.supported = supported }
}

extension TranscriptionRequest {
    /// For automatic detection, replaces the languages known by the caller with what this process
    /// can actually use and install. Apple Speech reserves assets per process, so only the helper
    /// that transcribes knows which models are ready.
    public func resolvingLanguages(_ locales: SpeechLocales, preferredLanguages: [String] = Locale.preferredLanguages) -> TranscriptionRequest {
        guard locale == SpeechLanguage.automatic else { return self }
        var request = self
        let installed = SpeechLanguage.oneLocalePerLanguage(locales.installed)
        request.candidateLocales = installed
        request.fallbackLocale = SpeechLanguage.fallback(installed: locales.installed, preferredLanguages: preferredLanguages)
        let codes = Set(installed.map(SpeechLanguage.languageCode))
        request.installableLocales = locales.supported.filter { !codes.contains(SpeechLanguage.languageCode(of: $0)) }
        return request
    }
}

public enum TranscriptionPipeline {
    public static func run(_ request: TranscriptionRequest, audio: any AudioLocator, recognizer: any SpeechRecognizing, audioOverrides: [UUID: URL] = [:]) async throws -> TranscriptionResult {
        guard !request.chunks.isEmpty, request.chunks.allSatisfy({ $0.start.isFinite && $0.start >= 0 && $0.duration.isFinite && $0.duration > 0 }) else { throw TranscriptionError.invalidAudio }
        var resolved = request
        var detections: [LanguageDetection]?
        var locales: [AudioSource: String] = [:]
        if request.locale == SpeechLanguage.automatic {
            var found: [LanguageDetection] = []
            for source in [AudioSource.mic, .system] where request.chunks.contains(where: { $0.source == source }) {
                found.append(try await detectLanguage(request, source: source, audio: audio, recognizer: recognizer, audioOverrides: audioOverrides))
            }
            for detection in found { locales[detection.source] = detection.locale }
            resolved.locale = locales[.mic] ?? found.first?.locale ?? request.fallbackLocale ?? SpeechLanguage.defaultLocale
            detections = found
        }
        var segments: [TranscriptSegment] = []
        for chunk in request.chunks.sorted(by: { $0.start < $1.start }) {
            try Task.checkCancellation()
            segments += try await recognizer.transcribe(file: audioOverrides[chunk.id] ?? audio.url(for: chunk), chunk: chunk, locale: locales[chunk.source] ?? resolved.locale)
        }
        segments.sort { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }
        var result = TranscriptionResult(request: resolved, segments: segments)
        result.languageDetection = detections
        return result
    }
    /// Seconds read from the start of a track for detection.
    static let detectionSeconds: Double = 90
    /// Below this many letters, a sample says nothing reliable about its language.
    static let detectionMinimumLetters = 40
    /// A matching model is usually above 0.9 on clear speech; a wrong one stays below.
    static let confidentMatch = 0.88
    /// Below this, no installed model fits (unrelated script or phonology).
    static let noMatch = 0.5
    /// Chooses a track's locale among the candidates from its first seconds. The sample is first
    /// transcribed with the fallback locale; its text identifies the language even when the
    /// recognizer is wrong (a French model writes English speech as recognizable English words).
    /// When the text points to another candidate, the sample is transcribed again with it, and the
    /// higher mean word confidence decides. Anything inconclusive keeps the fallback. When no
    /// candidate fits well, the texts may still reveal an installable language to suggest.
    static func detectLanguage(_ request: TranscriptionRequest, source: AudioSource, audio: any AudioLocator, recognizer: any SpeechRecognizing,
                               audioOverrides: [UUID: URL]) async throws -> LanguageDetection {
        let candidates = SpeechLanguage.oneLocalePerLanguage(request.candidateLocales ?? [])
        let fallback = request.fallbackLocale ?? candidates.first ?? SpeechLanguage.defaultLocale
        let chunks = request.chunks.filter { $0.source == source }.sorted { $0.start < $1.start }
        guard !chunks.isEmpty else { return .init(source: source, locale: fallback, method: .fallback) }
        // A pause, a device change or a Bluetooth reconnection can leave a first chunk of a few
        // seconds: the sample spans successive chunks until it holds `detectionSeconds` of audio.
        var excerpt: [(chunk: AudioChunk, url: URL, seconds: Double)] = [], remaining = detectionSeconds
        for chunk in chunks where remaining > 0 {
            let seconds = min(chunk.duration, remaining)
            excerpt.append((chunk, try audioOverrides[chunk.id] ?? audio.url(for: chunk), seconds)); remaining -= seconds
        }
        func listen(_ locale: String) async throws -> SpeechSample {
            var texts: [String] = [], weighted = 0.0, weight = 0.0
            for part in excerpt {
                try Task.checkCancellation()
                let sample = try await recognizer.sample(file: part.url, chunk: part.chunk, locale: locale, seconds: part.seconds)
                texts.append(sample.text)
                if let confidence = sample.confidence, !sample.text.isEmpty { let letters = Double(sample.text.count); weighted += confidence * letters; weight += letters }
            }
            let text = texts.filter { !$0.isEmpty }.joined(separator: " ")
            return SpeechSample(text: text, confidence: weight > 0 ? weighted / weight : nil)
        }
        func audible(_ sample: SpeechSample) -> Bool { sample.text.filter(\.isLetter).count >= detectionMinimumLetters }
        var heard: [(locale: String, sample: SpeechSample)] = []
        let first = try await listen(fallback)
        heard.append((fallback, first))
        var chosen = LanguageDetection(source: source, locale: fallback, method: .fallback, confidence: first.confidence)
        if audible(first), candidates.count > 1,
           let language = hypothesis(first.text, among: candidates),
           let guess = candidates.first(where: { SpeechLanguage.matches($0, language.language) }) {
            if SpeechLanguage.languageCode(of: guess) == SpeechLanguage.languageCode(of: fallback) {
                chosen.method = .detected
            } else if let second = try? await listen(guess) {
                heard.append((guess, second))
                switch (first.confidence, second.confidence) {
                case let (a?, b?) where b >= a: chosen = .init(source: source, locale: guess, method: .detected, confidence: b)
                case (_?, _?): chosen.method = .detected
                default: if language.probability >= 0.8 { chosen = .init(source: source, locale: guess, method: .detected, confidence: second.confidence) }
                }
            }
        }
        // Weak or empty result: the other installed models may write this speech better, or at least
        // produce text that reveals its language (a French model writes Japanese as nothing at all).
        if !audible(first) || (chosen.confidence ?? 0) < confidentMatch {
            for other in candidates where !heard.contains(where: { $0.locale == other }) {
                guard let sample = try? await listen(other) else { continue }
                heard.append((other, sample))
                if audible(sample), let confidence = sample.confidence, confidence > (chosen.confidence ?? 0) {
                    let fits = confidence >= confidentMatch && hypothesis(sample.text, among: [other]) != nil
                    if fits { chosen = .init(source: source, locale: other, method: .detected, confidence: confidence) }
                }
            }
        }
        // Silence everywhere: nothing to say about the language.
        guard heard.contains(where: { audible($0.sample) || ($0.sample.confidence.map { $0 < noMatch } ?? false) && !$0.sample.text.isEmpty }) else {
            return .init(source: source, locale: fallback, method: .fallback, confidence: first.confidence)
        }
        let best = heard.compactMap(\.sample.confidence).max() ?? 0
        guard best < confidentMatch, (chosen.confidence ?? 0) < confidentMatch else { return chosen }
        // No installed model fits well: look for another language in what the models wrote.
        let installable = SpeechLanguage.oneLocalePerLanguage(request.installableLocales ?? [])
        for (_, sample) in heard {
            if let other = hypothesis(sample.text, among: nil), other.probability >= 0.9,
               !candidates.contains(where: { SpeechLanguage.matches($0, other.language) }),
               let locale = installable.first(where: { SpeechLanguage.matches($0, other.language) }) {
                chosen.suggestedLocale = locale; chosen.method = .fallback; return chosen
            }
        }
        if best < noMatch { chosen.unrecognized = true; chosen.method = .fallback }
        return chosen
    }
    /// Most likely language of a text, optionally among the languages of some speech locales.
    static func hypothesis(_ text: String, among locales: [String]?) -> (language: NLLanguage, probability: Double)? {
        let recognizer = NLLanguageRecognizer()
        if let locales { recognizer.languageConstraints = Array(Set(locales.flatMap(SpeechLanguage.naturalLanguages))) }
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 1).first.map { ($0.key, $0.value) }
    }
}
extension Recording {
    public mutating func applyTranscription(_ result: TranscriptionResult) throws {
        guard id == result.request.recordingID, audioChunks == result.request.chunks, state != .recording else { throw TranscriptionError.staleResult }
        transcription = .init(engine: result.engine, diarizationEngine: result.diarizationEngine, echoCancellationEngine: result.echoCancellationEngine, locale: result.request.locale, createdAt: result.createdAt, languageDetection: result.languageDetection)
        segments = result.segments; speakers = result.speakers ?? []; absorbedSpeakers = nil; transcriptVersion += 1; transcriptState = .ready; summary = nil
    }
}

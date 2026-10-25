import Foundation
import AVFoundation
import Speech

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
    public init(recordingID: UUID, locale: String = "fr-FR", chunks: [AudioChunk], diarize: Bool = false) {
        self.recordingID = recordingID; self.locale = locale; self.chunks = chunks; self.diarize = diarize
    }
}
public struct TranscriptionProvenance: Codable, Equatable, Sendable {
    public var engine: String
    public var diarizationEngine: String?
    public var locale: String
    public var createdAt: Date
}
public struct TranscriptionResult: Codable, Sendable {
    public var request: TranscriptionRequest
    public var engine: String
    public var diarizationEngine: String?
    public var createdAt: Date
    public var segments: [TranscriptSegment]
    public var speakers: [Speaker]?
    public init(request: TranscriptionRequest, segments: [TranscriptSegment]) {
        self.request = request; self.segments = segments; engine = "apple-speech-transcriber-v1"; createdAt = Date()
    }
}
public enum TranscriptionError: LocalizedError {
    case unavailable, unsupportedLocale(String), missingAssets(String), invalidAudio, staleResult
    public var errorDescription: String? {
        switch self {
        case .unavailable: "La transcription Apple n’est pas disponible sur ce Mac."
        case .unsupportedLocale(let locale): "La langue \(locale) n’est pas prise en charge par SpeechTranscriber sur ce Mac."
        case .missingAssets(let locale): "Le modèle \(locale) doit être installé. Utilisez « Installer le modèle français » dans les réglages."
        case .invalidAudio: "Aucune tranche audio valide à transcrire."
        case .staleResult: "Le résultat ne correspond plus aux fichiers de cette session."
        }
    }
}
public protocol SpeechRecognizing: Sendable {
    func transcribe(file: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment]
}
public actor AppleSpeechRecognizer: SpeechRecognizing {
    public init() {}
    private func module(locale: String) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw TranscriptionError.unsupportedLocale(locale)
        }
        return SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
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
    public static func diagnostics() async -> String {
        let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
        return "available=\(SpeechTranscriber.isAvailable)\nsupported=\(supported.joined(separator: ","))\ninstalled=\(installed.joined(separator: ","))"
    }
}

public enum TranscriptionPipeline {
    public static func run(_ request: TranscriptionRequest, store: SessionStore, recognizer: any SpeechRecognizing) async throws -> TranscriptionResult {
        guard !request.chunks.isEmpty, request.chunks.allSatisfy({ $0.start.isFinite && $0.start >= 0 && $0.duration.isFinite && $0.duration > 0 }) else { throw TranscriptionError.invalidAudio }
        var segments: [TranscriptSegment] = []
        for chunk in request.chunks.sorted(by: { $0.start < $1.start }) {
            try Task.checkCancellation()
            segments += try await recognizer.transcribe(file: store.audioURL(for: chunk), chunk: chunk, locale: request.locale)
        }
        segments.sort { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }
        return TranscriptionResult(request: request, segments: segments)
    }
}
extension Recording {
    public mutating func applyTranscription(_ result: TranscriptionResult) throws {
        guard id == result.request.recordingID, audioChunks == result.request.chunks, state != .recording else { throw TranscriptionError.staleResult }
        transcription = .init(engine: result.engine, diarizationEngine: result.diarizationEngine, locale: result.request.locale, createdAt: result.createdAt)
        segments = result.segments; speakers = result.speakers ?? []; transcriptVersion += 1; transcriptState = .ready; summary = nil
    }
}

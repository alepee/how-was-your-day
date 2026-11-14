import Foundation

/// The speech and voice models this Mac can use, and their installation. Apple Speech reserves
/// assets per process, so the app's adapter asks the bundled `hwyd-pipeline`, the process that
/// transcribes. `InMemorySpeechModelCatalog` answers in tests.
public protocol SpeechModelCatalog: Sendable {
    /// Languages installed for transcription and languages that can be installed.
    func locales() async throws -> SpeechLocales
    /// Downloads one transcription language.
    func install(locale: String) async throws
    /// Whether the voice separation models are on disk, read from the models themselves.
    func diarizerReady() async -> Bool
    /// Downloads the voice separation models.
    func installDiarizer() async throws
}

/// Answers from memory: installing a language or the diarizer marks it installed.
public actor InMemorySpeechModelCatalog: SpeechModelCatalog {
    public private(set) var installed: [String]
    public private(set) var supported: [String]
    public private(set) var diarizerInstalled: Bool
    public private(set) var installRequests: [String] = []
    /// Thrown by the next installation, then cleared.
    private var failure: (any Error)?
    public init(installed: [String] = [], supported: [String] = [], diarizerInstalled: Bool = false) {
        self.installed = installed; self.supported = supported; self.diarizerInstalled = diarizerInstalled
    }
    public func failNextInstall(with error: any Error) { failure = error }
    public func locales() async throws -> SpeechLocales { SpeechLocales(installed: installed.sorted(), supported: supported.sorted()) }
    public func install(locale: String) async throws {
        installRequests.append(locale)
        if let failure { self.failure = nil; throw failure }
        guard supported.contains(locale) else { throw TranscriptionError.unsupportedLocale(locale) }
        if !installed.contains(locale) { installed.append(locale) }
    }
    public func diarizerReady() async -> Bool { diarizerInstalled }
    public func installDiarizer() async throws {
        installRequests.append("diarizer")
        if let failure { self.failure = nil; throw failure }
        diarizerInstalled = true
    }
}

/// What `hwyd-pipeline diarizer-status` prints.
public struct DiarizerStatus: Codable, Equatable, Sendable {
    public var installed: Bool
    public init(installed: Bool) { self.installed = installed }
}

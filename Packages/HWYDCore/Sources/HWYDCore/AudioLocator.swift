import Foundation

/// Where recorded audio lives. Capture, playback, waveforms and transcription ask it for paths
/// instead of holding a store or a data directory.
///
/// Every path stays inside the audio root: a chunk whose relative path leaves it (`..`, an
/// absolute path, a symbolic link pointing out) is refused with `StoreError.invalidPath`.
public protocol AudioLocator: Sendable {
    /// The file of a recorded chunk.
    func url(for chunk: AudioChunk) throws -> URL
    /// The folder a new session's chunks are written to, created private (0700).
    func sessionFolder(for session: UUID) throws -> AudioFolder
    /// Where waveform envelopes may be cached on disk; nil keeps them in memory only.
    var waveformCache: URL? { get }
    /// The file a capture holds locked while it writes, so that no second capture and no recovery
    /// of interrupted sessions touches the files being written.
    var captureLockFile: URL { get }
}

/// A session's audio folder: where to write, and the relative path its chunks record.
public struct AudioFolder: Equatable, Sendable {
    public let url: URL
    public let relativePath: String
    public init(url: URL, relativePath: String) { self.url = url; self.relativePath = relativePath }
    /// The relative path a chunk named `name` records.
    public func chunkPath(_ name: String) -> String { relativePath + "/" + name }
}

/// Audio under a data directory, the layout every version wrote: `audio/<session>/<chunk>.caf`,
/// waveforms in `cache/waveforms`. The store, the helper and `hwyd-mcp` share this directory.
public struct DataDirectoryAudio: AudioLocator, Equatable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// Relative folder holding every session's audio folder.
    public static let audioRoot = "audio"
    /// Relative folder of the waveform envelopes.
    public static let waveformFolder = "cache/waveforms"
    /// Relative folder of one session's chunks.
    public static func relativeFolder(for session: UUID) -> String { audioRoot + "/" + session.uuidString.lowercased() }

    public func url(for chunk: AudioChunk) throws -> URL {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(chunk.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"), !chunk.relativePath.hasPrefix("/") else { throw StoreError.invalidPath }
        return url
    }

    public func sessionFolder(for session: UUID) throws -> AudioFolder {
        let relative = Self.relativeFolder(for: session)
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return AudioFolder(url: url, relativePath: relative)
    }

    public var waveformCache: URL? { directory.appendingPathComponent(Self.waveformFolder) }
    public var captureLockFile: URL { directory.appendingPathComponent("capture.lock") }
}

/// Test double: a fresh temporary directory with the data directory layout, removed when the
/// locator goes away. The same path rules apply; waveforms stay in memory.
public final class TemporaryAudioLocator: AudioLocator {
    public let directory: URL
    private let layout: DataDirectoryAudio

    public init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hwyd-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        layout = DataDirectoryAudio(directory: directory)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    public func url(for chunk: AudioChunk) throws -> URL { try layout.url(for: chunk) }
    public func sessionFolder(for session: UUID) throws -> AudioFolder { try layout.sessionFolder(for: session) }
    public var waveformCache: URL? { nil }
    public var captureLockFile: URL { layout.captureLockFile }
}

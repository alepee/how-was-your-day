import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where note images live, relative to the data directory or to an export folder.
public enum NoteImageFiles {
    /// Relative folder holding every session's note images in the data directory.
    public static let root = "notes"
    /// Relative folder holding every session's note images in an export folder.
    public static let exportRoot = "attachments"
    /// The longest side an image keeps; larger images are scaled down.
    public static let maxPixelSize = 4096
    /// Pasted data larger than this is refused before decoding.
    public static let maxBytes = 50 * 1024 * 1024

    public static func relativeFolder(for session: UUID) -> String { root + "/" + session.uuidString.lowercased() }
    public static func fileName(_ image: NoteImage) -> String { image.id.uuidString.lowercased() + ".png" }
    public static func relativePath(_ image: NoteImage, session: UUID) -> String { relativeFolder(for: session) + "/" + fileName(image) }
    /// The image's path in an export folder, relative to that folder.
    public static func exportPath(_ image: NoteImage, session: UUID) -> String {
        exportRoot + "/" + session.uuidString.lowercased() + "/" + fileName(image)
    }

    /// Decodes any image ImageIO reads (PNG, TIFF, JPEG, HEIC…) and encodes it again as PNG, applying its orientation.
    /// Metadata (location, camera, author) is not carried over. Nil when `data` is not an image or is too large.
    public static func normalized(_ data: Data) -> (png: Data, image: NoteImage)? {
        guard data.count <= maxBytes, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), image.width > 0, image.height > 0 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, NoteImage(width: image.width, height: image.height))
    }
}

public enum NoteImageError: LocalizedError, Equatable {
    case notAnImage
    public var errorDescription: String? { String(localized: "Ce contenu n’est pas une image lisible.", bundle: .hwyd) }
}

/// Keeps the images pasted into a session's notes. `FolderNoteImageStore` writes them to the data
/// directory; `InMemoryNoteImageStore` serves the examples, previews and checks, which never write.
public protocol NoteImageStore: Sendable {
    /// Keeps `data` as an image of `session`. Throws `NoteImageError.notAnImage` when it is not one.
    func add(_ data: Data, to session: UUID) async throws -> NoteImage
    /// The PNG of `image`, nil when it is missing.
    func data(of image: NoteImage, in session: UUID) async -> Data?
}

public struct FolderNoteImageStore: NoteImageStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    @concurrent public func add(_ data: Data, to session: UUID) async throws -> NoteImage {
        guard let (png, image) = NoteImageFiles.normalized(data) else { throw NoteImageError.notAnImage }
        let folder = directory.appendingPathComponent(NoteImageFiles.relativeFolder(for: session))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try png.write(to: folder.appendingPathComponent(NoteImageFiles.fileName(image)), options: .withoutOverwriting)
        return image
    }
    @concurrent public func data(of image: NoteImage, in session: UUID) async -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(NoteImageFiles.relativePath(image, session: session)))
    }
}

public actor InMemoryNoteImageStore: NoteImageStore {
    private var images: [UUID: Data] = [:]
    public init() {}
    public func add(_ data: Data, to session: UUID) throws -> NoteImage {
        guard let (png, image) = NoteImageFiles.normalized(data) else { throw NoteImageError.notAnImage }
        images[image.id] = png
        return image
    }
    public func data(of image: NoteImage, in session: UUID) -> Data? { images[image.id] }
}

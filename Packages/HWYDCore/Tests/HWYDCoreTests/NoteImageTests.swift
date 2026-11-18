import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import HWYDCore

/// Synthetic images only: a small TIFF drawn here stands in for a pasted screenshot.
final class NoteImageTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HWYD-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func picture(width: Int, height: Int, type: UTType = .tiff) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.6, green: 0.8, blue: 0.7, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testNormalizesToPNGAndBoundsTheSize() throws {
        let small = try XCTUnwrap(NoteImageFiles.normalized(try picture(width: 40, height: 30)))
        XCTAssertEqual([small.image.width, small.image.height], [40, 30])
        XCTAssertEqual(small.png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        let large = try XCTUnwrap(NoteImageFiles.normalized(try picture(width: 5000, height: 1000)))
        XCTAssertEqual(large.image.width, NoteImageFiles.maxPixelSize)
        XCTAssertNil(NoteImageFiles.normalized(Data("pas une image".utf8)))
    }

    func testFolderStoreKeepsImagesWithTheSessionAndDeletionRemovesThem() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        var item = try await store.save(Recording(title: "Images", state: .sealed))
        let images = FolderNoteImageStore(directory: root)
        let image = try await images.add(try picture(width: 20, height: 10), to: item.id)
        item.noteEntries.append(NoteEntry(offset: 12, text: "Schéma", image: image))
        item = try await store.save(item)
        let stored = try await store.all().first { $0.id == item.id }
        XCTAssertEqual(stored?.noteEntries.first?.image, image)
        let saved = await images.data(of: image, in: item.id)
        XCTAssertNotNil(saved)
        do { _ = try await images.add(Data("texte".utf8), to: item.id); XCTFail("Text accepted as an image") }
        catch { XCTAssertEqual(error as? NoteImageError, .notAnImage) }
        let removal = try await store.remove(item.id)
        XCTAssertTrue(removal.files?.removed.contains(NoteImageFiles.relativeFolder(for: item.id)) == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(NoteImageFiles.relativeFolder(for: item.id)).path))
    }

    func testOrphanSweepRemovesImagesOfUnknownSessions() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        _ = try await store.save(Recording(title: "Vivante", state: .sealed))
        let orphan = UUID(), folder = root.appendingPathComponent(NoteImageFiles.relativeFolder(for: orphan))
        _ = try await FolderNoteImageStore(directory: root).add(try picture(width: 8, height: 8), to: orphan)
        let report = try await store.removeOrphanFiles(now: Date.now.addingTimeInterval(2 * SessionFiles.orphanQuietPeriod))
        XCTAssertEqual(report?.removed, [NoteImageFiles.relativeFolder(for: orphan)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testExportCopiesImagesAndLinksThem() async throws {
        let root = try directory(), output = try directory()
        var item = Recording(title: "Export", state: .sealed)
        let image = try await FolderNoteImageStore(directory: root).add(try picture(width: 16, height: 9), to: item.id)
        item.noteEntries = [NoteEntry(offset: 3, text: "Avant"), NoteEntry(offset: 65, text: "Tableau [v2]", image: image)]
        try SessionExporter.export(item, to: output, noteImages: root)
        let path = NoteImageFiles.exportPath(image, session: item.id)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(path)), try Data(contentsOf: root.appendingPathComponent(NoteImageFiles.relativePath(image, session: item.id))))
        let base = "session-\(item.startedAt.ISO8601Format().prefix(10))-\(item.id.uuidString.lowercased())"
        let markdown = try String(contentsOf: output.appendingPathComponent(base + ".md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("- [00:01:05] ![Tableau \\[v2\\]](\(path))"), markdown)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent(base + ".json"))) as? [String: Any])
        let entries = try XCTUnwrap((json["notes"] as? [String: Any])?["entries"] as? [[String: Any]])
        XCTAssertNil(entries[0]["image"], "A text entry keeps the shape it was published with")
        XCTAssertEqual((entries[1]["image"] as? [String: Any])?["path"] as? String, path)
        // Search and MCP name the image without a link to a file they cannot serve.
        XCTAssertTrue(RecordingText.artifact(item, "notes").contains("- [00:01:05] [Image : Tableau \\[v2\\]]"))
        try SessionExporter.delete(id: item.id.uuidString.lowercased(), revision: item.revision + 1, from: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent(path).path))
    }

    func testSessionsSavedBeforeImagesStillDecode() throws {
        let legacy = Data(#"{"id":"6F1C2A44-0D8B-4C59-9E4E-2B0C1D3E4F50","offset":4.5,"text":"note"}"#.utf8)
        let entry = try JSONDecoder().decode(NoteEntry.self, from: legacy)
        XCTAssertNil(entry.image)
        XCTAssertEqual(entry.text, "note")
    }
}

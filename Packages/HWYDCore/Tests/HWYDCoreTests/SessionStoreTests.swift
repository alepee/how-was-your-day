import XCTest
@testable import HWYDCore

final class SessionStoreTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HWYD-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testPersistsNotesAndVersionHistoryAcrossReopen() async throws {
        let path = try directory()
        let store = try SessionStore(directory: path)
        var item = try await store.save(Recording(title: "Une conversation", notes: "Première note"))
        item.notes = "Note corrigée"
        item = try await store.save(item)
        let reopened = try SessionStore(directory: path)
        let values = try await reopened.all()
        XCTAssertEqual(values.first?.notes, "Note corrigée")
        XCTAssertEqual(values.first?.revision, 2)
        let versions = try await reopened.versions(for: item.id)
        XCTAssertEqual(versions.map(\.notes), ["Première note", "Note corrigée"])
    }
    func testRejectsStaleWriterWithoutOverwritingNotes() async throws {
        let path = try directory()
        let first = try SessionStore(directory: path), second = try SessionStore(directory: path)
        let original = try await first.save(Recording(title: "Test"))
        var changed = original; changed.notes = "Correction conservée"
        _ = try await first.save(changed)
        do { _ = try await second.save(original); XCTFail("Stale writer accepted") }
        catch { XCTAssertEqual(error as? StoreError, .conflict) }
        let saved = try await second.all()
        XCTAssertEqual(saved.first?.notes, "Correction conservée")
    }
    func testRecoversInterruptedCaptureWithoutDiscardingNotes() async throws {
        let store = try SessionStore(directory: directory())
        _ = try await store.save(Recording(title: "En cours", state: .recording, notes: "À garder"))
        let count = try await store.recoverInterrupted()
        let items = try await store.all()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(items.first?.state, .interrupted)
        XCTAssertEqual(items.first?.notes, "À garder")
    }
    func testSpeakerCorrectionKeepsSegmentClusterAndInvalidatesSummary() throws {
        var item = DemoContent.recordings()[0]
        let unknown = try XCTUnwrap(item.speakers.first { !$0.confirmed })
        let segmentIDs = item.segments.filter { $0.speakerID == unknown.id }.map(\.id)
        try item.renameSpeaker(unknown.id, to: " Léa ")
        XCTAssertEqual(item.speakers.first { $0.id == unknown.id }?.label, "Léa")
        XCTAssertEqual(item.transcriptVersion, 2)
        XCTAssertNil(item.summary)
        XCTAssertEqual(item.segments.filter { $0.speakerID == unknown.id }.map(\.id), segmentIDs)
    }
    func testAudioPathCannotEscapeStore() throws {
        let store = try SessionStore(directory: directory())
        XCTAssertThrowsError(try store.audioURL(for: .init(source: .mic, relativePath: "../outside.caf", start: 0, duration: 1)))
    }
    func testExportPublishesMatchingFilesAndPreservesPreviousExport() throws {
        let path = try directory()
        let item = DemoContent.recordings()[0]
        try SessionExporter.export(item, to: path)
        try SessionExporter.export(item, to: path)
        let index = try String(contentsOf: path.appendingPathComponent("index.jsonl"), encoding: .utf8)
        XCTAssertEqual(index.split(separator: "\n").count, 1)
        let folder = path.appendingPathComponent(".hwyd/generations/\(item.id.uuidString.lowercased())/\(item.revision)")
        let json = try Data(contentsOf: folder.appendingPathComponent("session.json"))
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(exported["id"] as? String, item.id.uuidString.lowercased())
        XCTAssertEqual(exported["hwyd_schema"] as? Int, 1)
        let markdown = try String(contentsOf: folder.appendingPathComponent("session.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Transcript"))
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("relativePath"))
    }
}

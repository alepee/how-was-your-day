import XCTest
@testable import HWYDCore

/// The integration settings shared with `hwyd-mcp` live in SQLite under their historical keys.
final class IntegrationSettingsTests: XCTestCase {
    func testTypedAccessorsReadTheExistingRows() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hwyd-settings-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SessionStore(directory: path)
        var writes = try await store.mcpWritesEnabled()
        var export = try await store.exportDirectory()
        XCTAssertFalse(writes); XCTAssertNil(export)
        try await store.database.write { db in
            try db.execute(sql: "INSERT INTO integration_settings VALUES ('mcp_writes_enabled','true'),('export_directory','/tmp/hwyd-export')")
        }
        writes = try await store.mcpWritesEnabled()
        export = try await store.exportDirectory()
        XCTAssertTrue(writes); XCTAssertEqual(export?.path, "/tmp/hwyd-export")
        try await store.setMCPWritesEnabled(false)
        try await store.setExportDirectory(path)
        let raw = try await store.database.read { try String.fetchAll($0, sql: "SELECT value FROM integration_settings ORDER BY key") }
        XCTAssertEqual(raw, [path.path, "false"])
    }
}

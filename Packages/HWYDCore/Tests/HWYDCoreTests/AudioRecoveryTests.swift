import XCTest
import AVFoundation
import Darwin
@testable import HWYDCore

final class AudioRecoveryTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (URL, UUID, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HWYD-recovery-\(UUID())")
        let id = UUID(), folder = root.appendingPathComponent("audio")
        let directory = folder.appendingPathComponent(id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(["start_frames": "4800000"]).write(to: directory.appendingPathComponent("000001.json"))
        return (root, id, directory)
    }
    private func audio(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        for i in 0..<1600 { buffer.floatChannelData![0][i] = 0.25 }
        try file.write(from: buffer)
    }
    func testRecoversPartialPairWithoutDestroyingOriginalsAndIsIdempotent() throws {
        let (root, id, directory) = try fixture()
        for source in ["mic", "system"] { try audio(directory.appendingPathComponent("\(source)-000001.partial.caf")) }
        let recovered = try AudioRecovery.recover(in: root, recordingID: id)
        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(recovered.map(\.start), [300, 300])
        XCTAssertEqual(recovered.map(\.duration), [0.1, 0.1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("mic-000001.partial.caf").path))
        XCTAssertEqual(try AudioRecovery.recover(in: root, recordingID: id), recovered)
    }
    func testRecoversSealedFilesWhenCrashPrecedesManifest() throws {
        let (root, id, directory) = try fixture()
        for source in ["mic", "system"] { try audio(directory.appendingPathComponent("\(source)-000001.caf")) }
        XCTAssertEqual(try AudioRecovery.recover(in: root, recordingID: id).count, 2)
    }
    func testUnreadablePairIsNotPublished() throws {
        let (root, id, directory) = try fixture()
        try audio(directory.appendingPathComponent("mic-000001.partial.caf"))
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("system-000001.partial.caf"))
        XCTAssertTrue(try AudioRecovery.recover(in: root, recordingID: id).isEmpty)
        let skipped = try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent("recovery-skipped.json")))
        XCTAssertEqual(skipped, ["000001.json"])
    }
    func testSecondInstanceDoesNotInterruptActiveCapture() async throws {
        let (root, _, _) = try fixture()
        let store = try SessionStore(directory: root)
        _ = try await store.save(Recording(title: "Active", state: .recording))
        let lock = open(root.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        let recovered = try await store.recoverInterrupted()
        XCTAssertEqual(recovered, 0)
        let items = try await store.all()
        XCTAssertEqual(items.first?.state, .recording)
    }
}

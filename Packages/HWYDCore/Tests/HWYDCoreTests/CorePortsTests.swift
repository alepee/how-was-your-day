import XCTest
@testable import HWYDCore

/// `AudioLocator` and `SecretVault`: path rules, item names, and the doubles. No test here reads
/// or writes the keychain.
final class CorePortsTests: XCTestCase {
    private func chunk(_ path: String) -> AudioChunk { AudioChunk(source: .mic, relativePath: path, start: 0, duration: 1) }

    func testAudioPathsStayInsideTheDataDirectory() throws {
        let audio = try TemporaryAudioLocator()
        let root = audio.directory.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(try audio.url(for: chunk("audio/a/000001-mic.caf")).path, root + "/audio/a/000001-mic.caf")
        for escaping in ["../outside.caf", "/etc/passwd", "audio/../../outside.caf"] {
            XCTAssertThrowsError(try audio.url(for: chunk(escaping)), escaping) { XCTAssertEqual($0 as? StoreError, .invalidPath) }
        }
    }

    func testSymbolicLinkOutOfTheDataDirectoryIsRefused() throws {
        let audio = try TemporaryAudioLocator()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("hwyd-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appendingPathComponent("a.caf"))
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: audio.directory.appendingPathComponent("audio"), withDestinationURL: outside)
        XCTAssertThrowsError(try audio.url(for: chunk("audio/a.caf")))
    }

    func testSessionFolderUsesTheStoredLayout() throws {
        let audio = try TemporaryAudioLocator()
        let session = UUID()
        let folder = try audio.sessionFolder(for: session)
        XCTAssertEqual(folder.relativePath, "audio/\(session.uuidString.lowercased())")
        XCTAssertEqual(folder.relativePath, DataDirectoryAudio.relativeFolder(for: session))
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
        XCTAssertEqual(try audio.url(for: chunk(folder.chunkPath("000001-mic.caf"))).lastPathComponent, "000001-mic.caf")
        XCTAssertNil(audio.waveformCache, "The double keeps waveforms in memory")
        XCTAssertEqual(DataDirectoryAudio(directory: audio.directory).waveformCache, audio.directory.appendingPathComponent("cache/waveforms"))
    }

    func testTemporaryLocatorRemovesItsDirectory() throws {
        var audio: TemporaryAudioLocator? = try TemporaryAudioLocator()
        let directory = try XCTUnwrap(audio?.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        audio = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// The names earlier versions wrote: changing them would orphan stored keys and voice prints.
    func testKeychainItemNamesAreUnchanged() {
        XCTAssertEqual(SummaryKeys.item(.anthropic), SecretItem(service: "dev.lepee.hwyd.summary-api-key", account: "anthropic"))
        let person = UUID()
        XCTAssertEqual(VoicePrints.item(person, VoiceChannel.mic.rawValue),
                       SecretItem(service: "dev.lepee.hwyd.voice.we-speaker-v1", account: person.uuidString + ".mic"))
        XCTAssertEqual(VoicePrints.legacyAccounts[.mic], ["near", "room"])
    }

    func testSummaryKeysTrimAndRemove() throws {
        let vault = InMemorySecretVault()
        let keys = SummaryKeys(vault: vault)
        XCTAssertFalse(keys.hasKey(for: .openai))
        XCTAssertNil(try keys.key(for: .openai))
        try keys.setKey("  sk-test \n", for: .openai)
        XCTAssertTrue(keys.hasKey(for: .openai))
        XCTAssertEqual(try keys.key(for: .openai), "sk-test")
        XCTAssertFalse(keys.hasKey(for: .anthropic))
        try keys.removeKey(for: .openai)
        try keys.removeKey(for: .openai)
        XCTAssertTrue(vault.stored.isEmpty)
    }

    func testVaultFailureKeepsEachCallersMessage() {
        let keys = SummaryKeys(vault: FailingVault()), prints = VoicePrints(vault: FailingVault())
        XCTAssertThrowsError(try keys.key(for: .openai)) { XCTAssertEqual(($0 as? SummaryKeys.Failure)?.status, -25308) }
        XCTAssertThrowsError(try prints.vectors(person: UUID(), channel: .mic)) {
            guard case VoiceError.keychain(let status) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(status, -25308)
        }
    }

    private func unit(_ index: Int) -> [Float] { var vector = [Float](repeating: 0, count: 256); vector[index] = 1; return vector }

    func testVoicePrintsLiveInTheVaultOnly() throws {
        let vault = InMemorySecretVault(), prints = VoicePrints(vault: vault)
        let person = UUID(), session = UUID()
        try prints.add(unit(0), person: person, channel: .mic, recordingID: session)
        try prints.add(unit(1), person: person, channel: .remote, recordingID: session)
        XCTAssertEqual(try prints.vectors(person: person, channel: .mic), [unit(0)])
        XCTAssertEqual(vault.stored, [VoicePrints.item(person, "mic"), VoicePrints.item(person, "remote")])
        XCTAssertEqual(try prints.contributions(person: person).map(\.count), [1, 1])
        XCTAssertEqual(try prints.remove(person: person, recordingID: session), [])
        XCTAssertTrue(vault.stored.isEmpty, "An emptied channel removes its item")
    }

    func testFormerMicrophoneAccountsFoldIntoMic() throws {
        let person = UUID()
        let legacy = try JSONEncoder().encode([unit(3)])
        let vault = InMemorySecretVault([VoicePrints.item(person, "near"): legacy])
        let prints = VoicePrints(vault: vault)
        XCTAssertEqual(try prints.vectors(person: person, channel: .mic), [unit(3)])
        XCTAssertEqual(vault.stored, [VoicePrints.item(person, "mic")])
        try prints.remove(person: person)
        XCTAssertTrue(vault.stored.isEmpty)
    }
}

private struct FailingVault: SecretVault {
    func read(_ item: SecretItem) throws -> Data? { throw SecretVaultFailure(status: -25308) }
    func contains(_ item: SecretItem) -> Bool { false }
    func write(_ data: Data, for item: SecretItem) throws { throw SecretVaultFailure(status: -25308) }
    func remove(_ item: SecretItem) throws { throw SecretVaultFailure(status: -25308) }
}

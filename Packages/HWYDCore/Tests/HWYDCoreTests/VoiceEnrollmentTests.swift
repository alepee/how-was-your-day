import XCTest
@testable import HWYDCore

final class VoiceEnrollmentTests: XCTestCase {
    func testExplicitLocalEnrollmentIsSeparateFromConsentAndHonorsOpposition() throws {
        var person = VoicePerson(name: "Synthetic speaker")
        XCTAssertFalse(person.recognitionEnabled)
        person.enrollmentRequestedAt = Date()
        XCTAssertTrue(person.recognitionEnabled)
        XCTAssertNil(person.consentedAt)
        person.enrolledChannels = [.near, .remote]
        let roundtrip = try JSONDecoder().decode(VoicePerson.self, from: JSONEncoder().encode(person))
        XCTAssertEqual(roundtrip, person)
        person.opposed = true
        XCTAssertFalse(person.recognitionEnabled)
    }
    func testLegacyPersonRemainsReadable() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","consentedAt":0,"opposed":false}"#.utf8)
        let person = try JSONDecoder().decode(VoicePerson.self, from: data)
        XCTAssertTrue(person.recognitionEnabled)
        XCTAssertNil(person.enrollmentRequestedAt)
        XCTAssertNil(person.enrolledChannels)
    }
    func testRevisionPollingDetectsSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(directory: root)
        let initial = try await store.recordingRevisions()
        XCTAssertTrue(initial.isEmpty)
        let recording = try await store.save(Recording(title: "Synthetic"))
        let revisions = try await store.recordingRevisions()
        XCTAssertEqual(revisions[recording.id], recording.revision)
    }
}

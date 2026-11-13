import XCTest
@testable import HWYDCore

final class VoiceEnrollmentTests: XCTestCase {
    func testExplicitLocalEnrollmentIsSeparateFromConsentAndHonorsOpposition() throws {
        var person = VoicePerson(name: "Synthetic speaker")
        XCTAssertFalse(person.recognitionEnabled)
        person.enrollmentRequestedAt = Date()
        XCTAssertTrue(person.recognitionEnabled)
        XCTAssertNil(person.consentedAt)
        person.enrolledChannels = [.mic, .remote]
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
        let initial = try await store.revisions()
        XCTAssertTrue(initial.isEmpty)
        let recording = try await store.save(Recording(title: "Synthetic"))
        let revisions = try await store.revisions()
        XCTAssertEqual(revisions[recording.id], recording.revision)
    }
    func testLiftingAnOppositionRequiresANewEnrollment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(directory: root)
        var person = VoicePerson(name: "Brice")
        person.enrollmentRequestedAt = Date(); person.enrolledChannels = [.mic]; person.opposed = true
        try await store.savePerson(person)
        var retry = person; retry.opposed = false
        do { try await store.savePerson(retry); XCTFail("An opposition must not be lifted by a plain save") } catch {}
        try await store.liftOpposition(person.id)
        let afterLift = try await store.people()
        let lifted = try XCTUnwrap(afterLift.first)
        XCTAssertFalse(lifted.opposed)
        XCTAssertFalse(lifted.recognitionEnabled)
        XCTAssertNil(lifted.enrolledChannels)
        var enrolled = lifted; enrolled.enrollmentRequestedAt = Date()
        try await store.savePerson(enrolled)
        let people = try await store.people()
        XCTAssertTrue(people.first?.recognitionEnabled == true)
    }
}

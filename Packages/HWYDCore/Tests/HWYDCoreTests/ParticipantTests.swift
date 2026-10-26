import XCTest
@testable import HWYDCore

final class ParticipantTests: XCTestCase {
    func testMultipleClustersRepresentTwoPeople() throws {
        let people = [UUID(), UUID()]
        let speakers = (0..<4).map { index in
            var speaker = Speaker(label: index % 2 == 0 ? "Antoine" : "Clément", confirmed: true,
                                  source: index < 2 ? .mic : .system)
            speaker.personID = people[index % 2]
            return speaker
        }
        let recording = Recording(title: "Conversation", speakers: speakers)
        XCTAssertEqual(recording.participants.count, 2)
        XCTAssertEqual(recording.participantNames, "Antoine, Clément")
        XCTAssertEqual(recording.speakers.count, 4)
        let document = try SessionExporter.document(recording)
        XCTAssertEqual((document["participants"] as? [[String: Any]])?.count, 2)
    }

    func testNamesAndSuggestionsDoNotMergeIdentities() {
        let named = [Speaker(label: "Camille", confirmed: true), Speaker(label: "Camille", confirmed: true)]
        var unknown = Speaker(label: "Camille")
        unknown.personID = UUID()
        let recording = Recording(title: "Conversation", speakers: named + [unknown])
        XCTAssertEqual(recording.participants.count, 2)
        XCTAssertEqual(recording.participantNames, "Camille, Camille, 1 voix à nommer")
    }
}

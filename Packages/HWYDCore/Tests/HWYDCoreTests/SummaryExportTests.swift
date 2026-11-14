import XCTest
@testable import HWYDCore

final class SummaryExportTests: XCTestCase {
    private func recording(summary: String?) -> Recording {
        let me = Speaker(label: "Vous", confirmed: true), camille = Speaker(label: "Camille", confirmed: true, source: .system)
        var item = Recording(title: "Point produit", duration: 1800, speakers: [me, camille, Speaker(label: "Voix 3")], summary: summary)
        item.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return item
    }

    func testNoSummaryExportsNothing() {
        XCTAssertNil(SummaryExport.markdown(recording(summary: nil)))
        XCTAssertNil(SummaryExport.markdown(recording(summary: "  \n")))
    }

    func testMarkdownStartsWithTitleAndConfirmedParticipants() throws {
        let text = try XCTUnwrap(SummaryExport.markdown(recording(summary: "## Résumé\n\nTout va bien.")))
        XCTAssertTrue(text.hasPrefix("# Point produit\n\n"))
        XCTAssertTrue(text.contains("30 min · Participants : Vous, Camille"))
        XCTAssertFalse(text.contains("Voix 3"))
        XCTAssertTrue(text.hasSuffix("## Résumé\n\nTout va bien.\n"))
    }

    func testContextNotesStayOutOfTheExport() throws {
        let summary = "## Résumé\n\nTout va bien.\n\n## Contexte\n\n### Projet perso\n\nNote privée.\n\n## Suite\n\nGardé."
        let text = try XCTUnwrap(SummaryExport.markdown(recording(summary: summary)))
        XCTAssertFalse(text.contains("Contexte"))
        XCTAssertFalse(text.contains("Note privée"))
        XCTAssertTrue(text.contains("Tout va bien.\n\n## Suite\n\nGardé."))
        XCTAssertNil(SummaryExport.markdown(recording(summary: "## Contexte\n\nNote privée.")))
    }

    func testAStaleSummarySaysTheTranscriptChanged() throws {
        var item = DemoContent.recordings()[0]; item.isDemo = false
        XCTAssertFalse(try XCTUnwrap(SummaryExport.markdown(item)).contains(SummaryExport.staleNotice))
        try item.renameSpeaker(item.speakers.first { !$0.confirmed }!.id, to: "Léa")
        XCTAssertTrue(item.summaryIsStale)
        XCTAssertTrue(try XCTUnwrap(SummaryExport.markdown(item)).contains("_Le transcript a changé depuis cette synthèse._"))
    }

    func testFileNameDropsPathSeparators() {
        var item = recording(summary: "x"); item.title = "Q3/Q4: bilan"
        XCTAssertEqual(SummaryExport.fileName(item), "Q3-Q4- bilan - synthèse")
    }
}

import XCTest
@testable import HWYDCore

/// Helper paths and ACP agent detection, without starting a process.
final class HelperDiscoveryTests: XCTestCase {
    func testHelperLocatorFindsBothHelpersInTheAppBundle() {
        let helpers = HelperLocator(appBundle: URL(fileURLWithPath: "/Applications/How Was Your Day.app"))
        XCTAssertEqual(helpers.pipeline.path, "/Applications/How Was Your Day.app/Contents/Helpers/hwyd-pipeline")
        XCTAssertEqual(helpers.mcp.path, "/Applications/How Was Your Day.app/Contents/Helpers/hwyd-mcp")
    }

    func testAgentDetectionOutputKeepsPresetOrderAndIgnoresUnknownLines() async {
        XCTAssertTrue(ACPAgentPreset.detectionScript.contains("command -v codex-acp"))
        XCTAssertEqual(ACPAgentPreset.installed(fromDetectionOutput: "gemini\nsomething-else\nclaude-agent-acp\n"),
                       ["claude-agent-acp", "gemini --experimental-acp"])
        XCTAssertEqual(ACPAgentPreset.installed(fromDetectionOutput: ""), [])
        let installed = await FixedAgentDiscovery(["codex-acp"]).installedAgents()
        XCTAssertEqual(installed, ["codex-acp"])
    }
}

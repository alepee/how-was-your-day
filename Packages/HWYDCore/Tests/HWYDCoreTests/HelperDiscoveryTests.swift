import XCTest
@testable import HWYDCore

/// Helper paths and ACP agent detection, without starting a process.
final class HelperDiscoveryTests: XCTestCase {
    func testHelperLocatorFindsBothHelpersInTheAppBundle() {
        let helpers = HelperLocator(appBundle: URL(fileURLWithPath: "/Applications/How Was Your Day.app"))
        XCTAssertEqual(helpers.pipeline.path, "/Applications/How Was Your Day.app/Contents/Helpers/hwyd-pipeline")
        XCTAssertEqual(helpers.mcp.path, "/Applications/How Was Your Day.app/Contents/Helpers/hwyd-mcp")
    }

    func testHelperVaultIsTheKeychainUnlessMemoryIsAsked() {
        var helpers = HelperLocator(appBundle: URL(fileURLWithPath: "/Applications/How Was Your Day.app"))
        XCTAssertEqual(helpers.secrets, .keychain)
        XCTAssertEqual(HelperSecrets(environment: [:]), .keychain)
        XCTAssertEqual(HelperSecrets(environment: ["HWYD_SECRET_VAULT": "unknown"]), .keychain)
        helpers.secrets = .memory
        XCTAssertEqual(HelperSecrets(environment: helpers.environment), .memory)
        XCTAssertTrue(HelperSecrets.memory.makeVault() is InMemorySecretVault)
        XCTAssertTrue(HelperSecrets.keychain.makeVault() is KeychainVault)
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

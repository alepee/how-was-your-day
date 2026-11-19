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
        XCTAssertTrue(ACPAgentPreset.detectionScript.contains("command -v claude "))
        XCTAssertEqual(ACPAgentPreset.inventory(fromDetectionOutput: "gemini\nsomething-else\nclaude-agent-acp\n"),
                       AgentInventory(ready: ["claude-agent-acp", "gemini --experimental-acp"]))
        XCTAssertEqual(ACPAgentPreset.inventory(fromDetectionOutput: ""), AgentInventory())
        let inventory = await FixedAgentDiscovery(["codex-acp"]).inventory()
        XCTAssertEqual(inventory.ready, ["codex-acp"])
    }

    /// An agent whose tool is there but not its adapter can be installed; one without an adapter package cannot.
    func testAgentWithoutItsAdapterIsInstallable() {
        let inventory = ACPAgentPreset.inventory(fromDetectionOutput: "claude\ncodex\ncodex-acp\nvibe\n")
        XCTAssertEqual(inventory.ready, ["codex-acp"])
        XCTAssertEqual(inventory.installable, ["claude-agent-acp"])
        XCTAssertEqual(ACPAgentPreset.preset(for: "claude-agent-acp")?.adapterInstallCommand, "npm install -g @agentclientprotocol/claude-agent-acp")
    }
}

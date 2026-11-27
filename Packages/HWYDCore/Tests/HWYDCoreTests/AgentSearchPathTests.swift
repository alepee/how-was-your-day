import XCTest
@testable import HWYDCore

/// The `PATH` agent processes get: the user's shell `PATH`, then the usual install locations.
final class AgentSearchPathTests: XCTestCase {
    /// Claude Code's installer and nvm add their directory in `~/.zshrc`, which a login shell does not read.
    func testMergeKeepsTheShellPathFirstAndAddsTheUsualInstallLocations() {
        let merged = AgentSearchPath.merge(shellPath: "/Users/u/.nvm/versions/node/v22/bin:/usr/bin", inherited: "/usr/bin:/bin", home: "/Users/u")
        let directories = merged.split(separator: ":").map(String.init)
        XCTAssertEqual(directories.first, "/Users/u/.nvm/versions/node/v22/bin")
        XCTAssertTrue(directories.contains("/Users/u/.local/bin"))
        XCTAssertTrue(directories.contains("/opt/homebrew/bin"))
        XCTAssertEqual(directories.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertEqual(directories.last, "/bin")
    }

    func testMergeWithoutShellPathStillFindsTheUsualInstallLocations() {
        let directories = AgentSearchPath.merge(shellPath: nil, inherited: nil, home: "/Users/u").split(separator: ":").map(String.init)
        XCTAssertEqual(directories.first, "/opt/homebrew/bin")
        XCTAssertTrue(directories.contains("/Users/u/.local/bin"))
        XCTAssertTrue(directories.contains("/usr/bin"))
    }

    func testProbeOutputIsReadBetweenMarkersWhateverTheStartupFilesPrint() {
        XCTAssertEqual(AgentSearchPath.parse(probeOutput: "Welcome!\n__HWYD_PATH__/a:/b__HWYD_PATH__\nbye"), "/a:/b")
        XCTAssertNil(AgentSearchPath.parse(probeOutput: "Welcome!\n__HWYD_PATH__/a:/b"))
        XCTAssertNil(AgentSearchPath.parse(probeOutput: "__HWYD_PATH____HWYD_PATH__"))
    }

    /// A fake shell that prints noise, then runs the probe, then leaves a background process holding
    /// the output open: the `PATH` is returned without waiting for the output to close.
    func testUserShellPathReturnsAsSoonAsThePathIsComplete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hwyd-shell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("fake-shell")
        try """
        #!/bin/sh
        # Called as: fake-shell -i -l -c <script>
        echo "startup noise"
        PATH=/fake/bin:/usr/bin:/bin /bin/sh -c "$4"
        sleep 600 &
        wait
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        // The timeout only bounds a failure; success comes from the markers.
        let path = await UserShellPath.run(shell: shell.path, timeout: .seconds(120))
        XCTAssertEqual(path, "/fake/bin:/usr/bin:/bin")
    }

    /// The adapter installs globally, or under `~/.local` when the global prefix is not writable;
    /// a missing npm is told apart so the user is asked for Node.js.
    func testAdapterInstallScriptFallsBackToTheUserPrefix() {
        let script = ACPAgentPreset.preset(for: "claude-agent-acp")?.adapterInstallScript
        XCTAssertEqual(script, "command -v npm >/dev/null 2>&1 || exit 127; "
            + "npm install -g @agentclientprotocol/claude-agent-acp >/dev/null 2>&1 || "
            + "npm install -g --prefix \"$HOME/.local\" @agentclientprotocol/claude-agent-acp >/dev/null 2>&1")
        XCTAssertNil(ACPAgentPreset.preset(for: "vibe-acp")?.adapterInstallScript)
    }
}

import Foundation

/// The `PATH` HWYD gives agent processes (detection, adapter install, launch).
///
/// An app opened from the Finder inherits a minimal `PATH`, and a login shell (`zsh -lc`) does not
/// read `~/.zshrc`, where the Claude Code installer, nvm, fnm or Volta usually put their directory.
/// So HWYD asks the user's interactive shell for its `PATH` once, then adds the usual install
/// locations in case that shell does not answer.
public enum AgentSearchPath {
    /// Delimits the `PATH` in the probe's output: an interactive shell's startup files may print anything.
    static let marker = "__HWYD_PATH__"
    /// Prints the shell's `PATH` between markers. Works in zsh, bash and fish (which joins `$PATH` with colons when quoted).
    public static var probeScript: String { "printf '%s%s%s' \(marker) \"$PATH\" \(marker)" }

    /// The `PATH` printed by `probeScript`, or nil while it is incomplete.
    public static func parse(probeOutput output: String) -> String? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Where agent tools and npm adapters usually land, for when the shell does not tell.
    public static func fallbackDirectories(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.claude/local",
         home + "/.npm-global/bin", home + "/.volta/bin", home + "/.bun/bin"]
    }

    /// The shell's `PATH` first, then the usual install locations, then the inherited `PATH`; each directory once.
    public static func merge(shellPath: String?, inherited: String?, home: String) -> String {
        let directories = (shellPath ?? "").split(separator: ":").map(String.init)
            + fallbackDirectories(home: home)
            + (inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The environment of an agent process: this process's, with the merged `PATH`.
    public static func environment(shellPath: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = merge(shellPath: shellPath, inherited: environment["PATH"],
                                    home: FileManager.default.homeDirectoryForCurrentUser.path)
        return environment
    }
}

/// Asks the user's interactive login shell for its `PATH`, once per launch. Answers nil when the
/// shell cannot start or takes longer than `timeout`; callers then rely on the usual install locations.
public actor UserShellPath {
    public static let shared = UserShellPath()
    private let timeout: Duration
    private var probe: Task<String?, Never>?

    public init(timeout: Duration = .seconds(10)) { self.timeout = timeout }

    public func value() async -> String? {
        if let probe { return await probe.value }
        let timeout = timeout
        let task = Task.detached(priority: .utility) { await Self.run(shell: Self.loginShell(), timeout: timeout) }
        probe = task
        return await task.value
    }

    /// The user's shell when HWYD knows how to ask it, zsh otherwise.
    static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if ["zsh", "bash", "fish"].contains((shell as NSString).lastPathComponent),
               FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }

    /// Runs the probe in an interactive login shell. Stops reading as soon as the `PATH` is complete,
    /// since a startup file may leave a background process holding the output open.
    static func run(shell: String, timeout: Duration) async -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-i", "-l", "-c", AgentSearchPath.probeScript]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let probe = ProbeOutput()
        return await withCheckedContinuation { continuation in
            probe.onFinish = { path in
                pipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                continuation.resume(returning: path)
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { probe.finish() } else { probe.append(chunk) }
            }
            do { try process.run() } catch { probe.finish(); return }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { probe.finish() }
        }
    }
}

/// The probe's output, finished once: when the `PATH` is complete, the output closes, or the timeout fires.
private final class ProbeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    var onFinish: (@Sendable (String?) -> Void)?

    func append(_ chunk: Data) {
        let path: String? = lock.withLock {
            data.append(chunk)
            return AgentSearchPath.parse(probeOutput: String(decoding: data, as: UTF8.self))
        }
        if path != nil { finish() }
    }
    func finish() {
        let callback: (@Sendable (String?) -> Void)?, path: String?
        (callback, path) = lock.withLock {
            guard !finished else { return (nil, nil) }
            finished = true
            return (onFinish, AgentSearchPath.parse(probeOutput: String(decoding: data, as: UTF8.self)))
        }
        callback?(path)
    }
}

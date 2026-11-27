import Foundation
import CryptoKit

/// The agent summary task shared by the app (prompt, result) and `hwyd-mcp` (`submit_summary`).
/// Both sides derive `S<n>` references from the same ordered segments, so references stay short
/// and an agent never handles segment UUIDs.
public enum AgentSummaryTask {
    public static let promptVersion = "agent-summary-v2"
    public static let handoffFileName = "summary.json"
    /// French keeps the historical version; English has its own.
    static func promptVersion(for language: SummaryLanguage) -> String { language == .english ? Self.promptVersion + "+english" : Self.promptVersion }
    /// Hash of the fixed instructions, without the session-specific title, transcript and notes.
    static func promptHash(for language: SummaryLanguage) -> String {
        let text = (try? prompt(Recording(title: ""), language: language)) ?? promptVersion(for: language)
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static let maximumEvidenceReferences = 5
    static let maximumDetails = 32
    static let maximumContextNotes = 8
    /// Images sent with the prompt, in note order; the others are described by their caption only.
    static let maximumImages = 8
    /// Larger images are described by their caption only: hosted models refuse them.
    static let maximumImageBytes = 5 * 1024 * 1024

    /// What the session sends: title, voice labels, passages and the user's notes, never audio or vectors.
    static func segments(_ recording: Recording) -> [TranscriptSegment] { recording.withoutIgnoredVoices.segments }
    static func references(_ recording: Recording) -> [String: String] {
        Dictionary(uniqueKeysWithValues: segments(recording).enumerated().map { ("S\($0.offset + 1)", $0.element.id.uuidString) })
    }

    /// Whether the prompt carries any note of the user's.
    static func hasNotes(_ recording: Recording) -> Bool {
        !recording.noteEntries.isEmpty || !recording.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Timed note entries in order, numbered `N<n>`.
    static func noteEntries(_ recording: Recording) -> [(id: String, entry: NoteEntry)] {
        recording.noteEntries.sorted { $0.offset == $1.offset ? $0.id.uuidString < $1.id.uuidString : $0.offset < $1.offset }
            .enumerated().map { ("N\($0.offset + 1)", $0.element) }
    }

    /// The images to attach, labelled by their note: the first `maximumImages` that exist and fit.
    static func images(_ recording: Recording, store: any NoteImageStore) async -> [(id: String, png: Data)] {
        var attached: [(id: String, png: Data)] = []
        for (id, entry) in noteEntries(recording) where attached.count < maximumImages {
            guard let image = entry.image, let png = await store.data(of: image, in: recording.id), png.count <= maximumImageBytes else { continue }
            attached.append((id, png))
        }
        return attached
    }

    /// `attached` lists the notes whose image follows the prompt.
    public static func prompt(_ recording: Recording, language: SummaryLanguage = .french, attached: Set<String> = []) throws -> String {
        let labels = Dictionary(uniqueKeysWithValues: recording.speakers.map { ($0.id, $0.label) })
        // `resumed`, absent unless recording resumed just before the passage, tells the agent the session was cut there.
        struct Row: Encodable { let id: String; let speaker: String; let start: String; let text: String; let resumed: String? }
        let passages = segments(recording)
        let markers = SessionResume.markers(recording.boundaries, before: passages.sorted { $0.start < $1.start })
        let rows = passages.enumerated().map { index, segment in
            Row(id: "S\(index + 1)", speaker: segment.speakerID.flatMap { labels[$0] } ?? language.unidentifiedSpeaker, start: timeLabel(segment.start), text: segment.text,
                resumed: markers[segment.id].map { $0.map { SessionResume.exportLabel($0) }.joined(separator: ", ") })
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let transcript = String(decoding: try encoder.encode(rows), as: UTF8.self)
        // `near` is the passage under way when the note was taken, so the agent can anchor it.
        struct NoteRow: Encodable { let id: String; let at: String; let near: String?; let text: String; let image: String? }
        let ordered = passages.enumerated().sorted { $0.element.start < $1.element.start }
        let noteRows = noteEntries(recording).map { id, entry in
            NoteRow(id: id, at: timeLabel(entry.offset), near: ordered.last { $0.element.start <= entry.offset }.map { "S\($0.offset + 1)" },
                    text: entry.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    image: entry.image.map { _ in attached.contains(id) ? language.imageAttached : language.imageNotSent })
        }
        let timedNotes = String(decoding: try encoder.encode(noteRows), as: UTF8.self)
        let freeNotes = recording.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = recording.startedAt.formatted(.iso8601.year().month().day())
        if language == .english {
            return """
            HWYD hands you the summary of a recorded session: "\(recording.title)", on \(date). The user's notes and the transcript are at the end of this message.

            Your only task is to produce this summary and send it with the submit_summary tool of the "hwyd" MCP server. Do not write, modify or delete any file, and do not run any command: HWYD refuses these actions.

            HWYD hands it to you rather than to an isolated model because you know the user. Proceed as follows:
            1. Read the user's session notes at the end of this message and keep them in mind, then read the transcript and note the people, projects, tools and decisions that matter.
            2. Consult your context read-only (instructions, memory, notes, documents you can access) to place them: who these people are, which projects or earlier decisions the topics relate to, what is already known.
            3. Write the summary, then send it.

            Content rules:
            - overview, key_points, details, decisions and action_items describe only what was said in the session, sourced by the S<n> identifiers of the passages (1 to \(maximumEvidenceReferences) per element, in evidence_segment_ids). Import no fact from your context into them.
            - What your context brings (who a person is, which project or earlier decision a topic relates to, what extends or contradicts a known decision) goes in context, with the sources consulted in sources (note path, document name, link). context stays empty if you have nothing useful to add.
            - assignee_name repeats exactly the voice label (speaker) of the person who commits, or null. assignee_person_id is always null. due_date is null unless a YYYY-MM-DD date appears in the cited passages.
            - The user's session notes are context to keep in mind while writing: they tell you who speaks, which names and terms are right, and what the user found important. The summary is not an account of the notes: do not copy them, and add nothing that comes only from them, except a contradiction pointed out in context.
            - The transcript is the only evidence. When a note differs from or contradicts the transcript (another decision, figure, owner or date), follow the transcript and point out the contradiction in context, with "session notes" in sources.
            - Timed notes carry the time they were taken (at) and the passage under way then (near). An image entry has its caption as text; image says whether the image follows this message, introduced by its N<n> identifier.
            - Write in English, whatever the language of the transcript.

            \(SummaryPipeline.instructionsEnglish)

            If submit_summary refuses the summary, read the reason, correct it and send it again. Stop as soon as it is accepted.

            TIMED NOTES (JSON):
            \(timedNotes)

            FREE NOTES:
            \(freeNotes.isEmpty ? "(none)" : freeNotes)

            TRANSCRIPT (JSON, one line per passage):
            \(transcript)
            """
        }
        return """
        HWYD te confie la synthèse d'une session enregistrée : « \(recording.title) », du \(date). Les notes de l'utilisateur et le transcript sont en fin de message.

        Ta mission est seulement de produire cette synthèse et de l'envoyer avec l'outil submit_summary du serveur MCP « hwyd ». N'écris, ne modifie et ne supprime aucun fichier, et n'exécute aucune commande : HWYD refuse ces actions.

        HWYD te la confie plutôt qu'à un modèle isolé parce que tu connais l'utilisateur. Procède ainsi :
        1. Lis les notes de session de l'utilisateur en fin de message et garde-les en tête, puis lis le transcript et relève les personnes, projets, outils et décisions qui comptent.
        2. Consulte ton contexte en lecture seule (instructions, mémoire, notes, documents auxquels tu as accès) pour les situer : qui sont ces personnes, à quels projets ou décisions antérieures les sujets se rattachent, ce qui est déjà connu.
        3. Rédige la synthèse, puis envoie-la.

        Règles de contenu :
        - overview, key_points, details, decisions et action_items décrivent uniquement ce qui a été dit dans la session, sourcé par les identifiants S<n> des passages (1 à \(maximumEvidenceReferences) par élément, dans evidence_segment_ids). N'y importe aucun fait de ton contexte.
        - Ce que ton contexte apporte (qui est une personne, à quel projet ou à quelle décision antérieure un sujet se rattache, ce qui prolonge ou contredit une décision connue) va dans context, avec les sources consultées dans sources (chemin de note, nom de document, lien). context reste vide si tu n'as rien d'utile à ajouter.
        - assignee_name reprend exactement le libellé de voix (speaker) de la personne qui s'engage, ou null. assignee_person_id est toujours null. due_date est null sauf si une date AAAA-MM-JJ figure dans les passages cités.
        - Les notes de session de l'utilisateur sont un contexte à garder en tête pendant la rédaction : elles t'indiquent qui parle, quels noms et termes sont justes, et ce que l'utilisateur a jugé important. La synthèse n'est pas un compte rendu des notes : ne les recopie pas, et n'ajoute rien qui ne viendrait que d'elles, sauf une contradiction signalée dans context.
        - Le transcript est la seule preuve. Quand une note diffère du transcript ou le contredit (autre décision, chiffre, responsable ou date), suis le transcript et signale la contradiction dans context, avec « notes de session » dans sources.
        - Les notes horodatées portent l'heure de prise (at) et le passage en cours à ce moment (near). Une entrée image a sa légende pour texte ; image indique si l'image suit ce message, introduite par son identifiant N<n>.
        - Écris en français.

        \(SummaryPipeline.instructions)

        Si submit_summary refuse la synthèse, lis la raison, corrige et renvoie-la. Arrête-toi dès qu'elle est acceptée.

        NOTES HORODATÉES (JSON) :
        \(timedNotes)

        NOTES LIBRES :
        \(freeNotes.isEmpty ? "(aucune)" : freeNotes)

        TRANSCRIPT (JSON, une ligne par passage) :
        \(transcript)
        """
    }

    /// Validates a submitted summary against the current session. Thrown errors carry the reason the
    /// agent needs to correct its submission.
    public static func accept(_ submission: Data, recording: Recording) throws -> SummaryContent {
        let references = references(recording)
        guard let object = try? JSONSerialization.jsonObject(with: submission) as? [String: Any] else { throw SummaryFailure.invalidContent("la synthèse doit être un objet JSON") }
        var output = object
        for key in ["key_points", "decisions", "action_items", "details", "context"] where output[key] == nil || output[key] is NSNull { output[key] = [Any]() }
        // Optional fields may be omitted by the agent; the stored form is always complete.
        output["action_items"] = (output["action_items"] as? [[String: Any]])?.map { action in
            var action = action
            action["assignee_person_id"] = NSNull()
            for key in ["assignee_name", "due_date"] where action[key] == nil { action[key] = NSNull() }
            return action
        } ?? output["action_items"]
        output["context"] = (output["context"] as? [[String: Any]])?.map { note in
            var note = note
            if note["sources"] == nil || note["sources"] is NSNull { note["sources"] = [String]() }
            return note
        } ?? output["context"]
        let content = try SummaryStageRequest.decode(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self), references: references)
        try SummaryPipeline.validate(content, segments: segments(recording), speakers: recording.speakers,
                                     maximumEvidenceReferences: maximumEvidenceReferences, maximumDetails: maximumDetails)
        let notes = content.context ?? []
        guard notes.count <= maximumContextNotes else { throw SummaryFailure.invalidContent("plus de \(maximumContextNotes) notes de contexte") }
        for note in notes {
            guard !note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.title.count <= 160,
                  !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.text.count <= 2200 else { throw SummaryFailure.invalidContent("note de contexte vide ou trop longue") }
            guard note.sources.count <= 10, note.sources.allSatisfy({ !$0.isEmpty && $0.count <= 300 }) else { throw SummaryFailure.invalidContent("sources de contexte invalides pour « \(note.title.prefix(60)) »") }
        }
        return content
    }

    /// The outermost JSON object in an agent's text answer, Markdown fences allowed, if any.
    static func jsonObject(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let data = Data(text[start...end].utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        // An agent may wrap the object in {"summary": …}, as the tool input does.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["overview"] == nil, let inner = object["summary"] as? [String: Any] {
            return try? JSONSerialization.data(withJSONObject: inner)
        }
        return data
    }
    public struct Handoff: Codable, Sendable {
        public var inputHash: String
        public var summary: SummaryContent
    }
    /// Written by `hwyd-mcp` into the private directory HWYD created for this run.
    public static func writeHandoff(_ summary: SummaryContent, inputHash: String, directory: URL) throws {
        let url = directory.appendingPathComponent(handoffFileName)
        try JSONEncoder().encode(Handoff(inputHash: inputHash, summary: summary)).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func readHandoff(directory: URL) throws -> Handoff? {
        let url = directory.appendingPathComponent(handoffFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Handoff.self, from: Data(contentsOf: url))
    }
}

/// ACP agents HWYD knows how to start. The command runs in a login shell; any other ACP agent can be typed.
public struct ACPAgentPreset: Identifiable, Hashable, Sendable {
    public let name: String
    public let command: String
    /// The agent's own command line tool, whose presence tells that the user has the agent.
    public let cli: String
    /// npm package of the ACP adapter, for agents whose tool does not speak ACP itself.
    public let adapterPackage: String?
    public var id: String { command }
    /// The executable whose presence tells that HWYD can start the agent.
    public var executable: String { String(command.split(separator: " ").first ?? "") }
    public init(name: String, command: String, cli: String, adapterPackage: String? = nil) {
        self.name = name; self.command = command; self.cli = cli; self.adapterPackage = adapterPackage
    }
    public static let all: [ACPAgentPreset] = [
        .init(name: "Claude Code", command: "claude-agent-acp", cli: "claude", adapterPackage: "@agentclientprotocol/claude-agent-acp"),
        .init(name: "Codex", command: "codex-acp", cli: "codex", adapterPackage: "@agentclientprotocol/codex-acp"),
        // vibe-acp ships with Mistral Vibe; Grok and Gemini CLI speak ACP themselves.
        .init(name: "Mistral Vibe", command: "vibe-acp", cli: "vibe"),
        .init(name: "Grok", command: "grok agent stdio", cli: "grok"),
        .init(name: "Gemini CLI", command: "gemini --experimental-acp", cli: "gemini"),
    ]
    public static func preset(for command: String) -> ACPAgentPreset? { all.first { $0.command == command } }
    /// The command that installs the adapter, for the user to run when HWYD cannot.
    public var adapterInstallCommand: String? { adapterPackage.map { "npm install -g \($0)" } }
    /// Exit status of `adapterInstallScript` when npm is not installed.
    public static let npmMissingStatus: Int32 = 127
    /// Installs the adapter globally, or under `~/.local` when the global prefix is not writable
    /// (Node.js installed with the nodejs.org package). `~/.local/bin` is on the agent's search path.
    public var adapterInstallScript: String? {
        adapterPackage.map { package in
            "command -v npm >/dev/null 2>&1 || exit \(Self.npmMissingStatus); "
                + "npm install -g \(package) >/dev/null 2>&1 || npm install -g --prefix \"$HOME/.local\" \(package) >/dev/null 2>&1"
        }
    }
}

public enum AgentSummaryFailure: LocalizedError, Equatable {
    case commandMissing, launchFailed(String), exited(String), protocolError(String), authenticationRequired(String)
    case noSummary(String), timedOut, stale
    public var errorDescription: String? {
        switch self {
        case .commandMissing: String(localized: "Indiquez la commande de l’agent ACP dans les réglages de synthèse.", bundle: .hwyd)
        case .launchFailed(let detail): String(localized: "Impossible de lancer l’agent : \(detail)", bundle: .hwyd)
        case .exited(let detail): String(localized: "L’agent s’est arrêté avant la fin.", bundle: .hwyd) + (detail.isEmpty ? "" : " " + detail)
        case .protocolError(let detail): String(localized: "L’agent a renvoyé une réponse ACP inattendue : \(detail)", bundle: .hwyd)
        case .authenticationRequired(let detail): String(localized: "L’agent demande une connexion. Lancez-le une fois dans un terminal pour vous authentifier.", bundle: .hwyd) + (detail.isEmpty ? "" : " " + detail)
        case .noSummary(let detail): detail.isEmpty ? String(localized: "L’agent n’a pas envoyé de synthèse.", bundle: .hwyd) : String(localized: "L’agent n’a pas envoyé de synthèse. Dernier message : « \(detail) »", bundle: .hwyd)
        case .timedOut: String(localized: "L’agent n’a pas terminé dans le temps imparti (20 minutes).", bundle: .hwyd)
        case .stale: String(localized: "La session a changé pendant la synthèse de l’agent. Relancez-la.", bundle: .hwyd)
        }
    }
}

/// HWYD's answer to `session/request_permission`. Reading and searching are allowed so the agent
/// can use its own context; HWYD's own tool is allowed; anything that edits, deletes, moves,
/// executes or changes mode is rejected.
public enum ACPPermissionPolicy {
    static let allowedKinds: Set<String> = ["read", "search", "think", "fetch"]
    static func isHWYDTool(_ toolCall: [String: Any]) -> Bool {
        let text = [toolCall["title"], toolCall["name"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
        return text.contains("submit_summary")
    }
    public static func allows(_ toolCall: [String: Any]) -> Bool {
        isHWYDTool(toolCall) || allowedKinds.contains(toolCall["kind"] as? String ?? "other")
    }
    /// Builds the `RequestPermissionResponse` result for these request params.
    static func response(to params: [String: Any]) -> [String: Any] {
        let options = params["options"] as? [[String: Any]] ?? []
        let allow = allows(params["toolCall"] as? [String: Any] ?? [:])
        let preferred = allow ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        for kind in preferred {
            if let option = options.first(where: { $0["kind"] as? String == kind }), let id = option["optionId"] as? String {
                return ["outcome": ["outcome": "selected", "optionId": id]]
            }
        }
        return ["outcome": ["outcome": "cancelled"]]
    }
}

/// Minimal ACP client over newline-delimited JSON-RPC on the agent's stdio.
actor ACPConnection {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var stderrTail = ""
    private var exited = false
    private let onNotification: @Sendable (String, Data) async -> Void

    init(command: String, workingDirectory: URL, shellPath: String?, onNotification: @escaping @Sendable (String, Data) async -> Void) {
        self.onNotification = onNotification
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A login shell finds agents installed with Homebrew, npm or uv; stdout stays the protocol channel.
        process.arguments = ["-lc", "exec " + command]
        process.currentDirectoryURL = workingDirectory
        process.environment = AgentSearchPath.environment(shellPath: shellPath)
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
    }

    func start() throws {
        do { try process.run() } catch { throw AgentSummaryFailure.launchFailed(error.localizedDescription) }
        let lines = Self.lines(of: output.fileHandleForReading), errorLines = Self.lines(of: errors.fileHandleForReading)
        Task { [weak self] in
            for await line in lines { await self?.receive(line) }
            await self?.closed()
        }
        Task { [weak self] in
            for await line in errorLines { await self?.appendError(String(decoding: line, as: UTF8.self)) }
        }
    }
    /// Newline-delimited messages from a pipe, delivered as soon as each line is complete.
    static func lines(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let buffer = LineBuffer()
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if let rest = buffer.flush() { continuation.yield(rest) }
                    continuation.finish()
                } else {
                    for line in buffer.append(chunk) { continuation.yield(line) }
                }
            }
        }
    }
    private func appendError(_ line: String) { stderrTail = String((stderrTail + line + "\n").suffix(2000)) }
    var errorTail: String { stderrTail.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").suffix(3).joined(separator: " ") }

    func request(_ method: String, params: Data) async throws -> Data {
        guard !exited else { throw AgentSummaryFailure.exited(errorTail) }
        let id = nextID; nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try send(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":"# + String(decoding: params, as: UTF8.self) + "}") }
            catch { pending[id] = nil; continuation.resume(throwing: error) }
        }
    }
    func notify(_ method: String, params: Data) {
        try? send(#"{"jsonrpc":"2.0","method":"\#(method)","params":"# + String(decoding: params, as: UTF8.self) + "}")
    }
    private func send(_ line: String) throws {
        guard !exited else { throw AgentSummaryFailure.exited(errorTail) }
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    private func receive(_ line: Data) async {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let method = message["method"] as? String {
            let params = (try? JSONSerialization.data(withJSONObject: message["params"] ?? [String: Any]())) ?? Data("{}".utf8)
            if let id = message["id"] {
                let idText = String(decoding: (try? JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed])) ?? Data("null".utf8), as: UTF8.self)
                try? send(Self.answer(method: method, params: params, id: idText))
            } else {
                await onNotification(method, params)
            }
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            let text = error["message"] as? String ?? "erreur"
            let code = (error["code"] as? NSNumber)?.intValue ?? 0
            continuation.resume(throwing: code == -32000 || text.lowercased().contains("auth") ? AgentSummaryFailure.authenticationRequired(text) : AgentSummaryFailure.protocolError(text))
        } else {
            continuation.resume(returning: (try? JSONSerialization.data(withJSONObject: message["result"] ?? NSNull(), options: [.fragmentsAllowed])) ?? Data("null".utf8))
        }
    }

    /// Answers requests from the agent. HWYD offers no file system or terminal access.
    static func answer(method: String, params: Data, id: String) -> String {
        if method == "session/request_permission", let object = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
           let result = try? JSONSerialization.data(withJSONObject: ACPPermissionPolicy.response(to: object)) {
            return #"{"jsonrpc":"2.0","id":\#(id),"result":"# + String(decoding: result, as: UTF8.self) + "}"
        }
        return #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"Method not supported by HWYD"}}"#
    }

    private func closed() {
        exited = true
        let failure = AgentSummaryFailure.exited(errorTail)
        for continuation in pending.values { continuation.resume(throwing: failure) }
        pending = [:]
    }
    func terminate() {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }
}

/// Runs one agent summary: launch the agent, give it the transcript and a restricted `hwyd-mcp`,
/// wait for its turn to end, then read and re-validate what `submit_summary` accepted.
public enum ACPSummaryAgent {
    public static let timeout: Duration = .seconds(20 * 60)

    public static func run(_ recording: Recording, command: String, workingDirectory: URL, mcpExecutable: URL, storeDirectory: URL,
                           language: SummaryLanguage = .french, noteImages: (any NoteImageStore)? = nil, shellPath: String? = nil,
                           progress: @escaping @Sendable (SummaryProgress) async -> Void = { _ in }) async throws -> SummaryProvenance {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { throw AgentSummaryFailure.commandMissing }
        guard !recording.withoutIgnoredVoices.segments.isEmpty else { throw SummaryFailure.noTranscript }
        let inputHash = try SummaryPipeline.inputHash(recording)
        let handoff = FileManager.default.temporaryDirectory.appendingPathComponent("hwyd-agent-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: handoff, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: handoff) }

        let lastMessage = MessageTail()
        let connection = ACPConnection(command: command, workingDirectory: workingDirectory, shellPath: shellPath) { method, params in
            guard method == "session/update", let object = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
                  let update = object["update"] as? [String: Any] else { return }
            switch update["sessionUpdate"] as? String {
            case "tool_call":
                if let title = update["title"] as? String { await progress(.init(stage: String(localized: "Agent : \(title)", bundle: .hwyd), completed: 0, total: 1, cached: false)) }
            case "agent_message_chunk":
                if let text = (update["content"] as? [String: Any])?["text"] as? String { await lastMessage.append(text) }
            default: break
            }
        }
        try await connection.start()
        let watchdog = Task { do { try await Task.sleep(for: timeout) } catch { return }; await connection.terminate() }
        defer { watchdog.cancel(); Task { await connection.terminate() } }
        let started = ContinuousClock.now

        await progress(.init(stage: String(localized: "Démarrage de l’agent", bundle: .hwyd), completed: 0, total: 1, cached: false))
        let initialize = try await connection.request("initialize", params: try json([
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "hwyd", "title": "How Was Your Day", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"]]))
        let agentInfo = (try? JSONSerialization.jsonObject(with: initialize) as? [String: Any])?["agentInfo"] as? [String: Any]
        let capabilities = (try? JSONSerialization.jsonObject(with: initialize) as? [String: Any])?["agentCapabilities"] as? [String: Any]
        let acceptsImages = (capabilities?["promptCapabilities"] as? [String: Any])?["image"] as? Bool == true
        let agentName = [agentInfo?["name"] as? String, agentInfo?["version"] as? String].compactMap { $0 }.joined(separator: " ")

        let server: [String: Any] = ["name": "hwyd", "command": mcpExecutable.path, "env": [Any](),
            "args": ["--store", storeDirectory.path, "--summary-handoff", handoff.path, "--recording", recording.id.uuidString, "--input-hash", inputHash]]
        let session = try await connection.request("session/new", params: try json(["cwd": workingDirectory.path, "mcpServers": [server]]))
        guard let sessionID = (try? JSONSerialization.jsonObject(with: session) as? [String: Any])?["sessionId"] as? String else { throw AgentSummaryFailure.protocolError("session/new sans sessionId") }

        await progress(.init(stage: String(localized: "L’agent rédige la synthèse", bundle: .hwyd), completed: 0, total: 1, cached: false))
        // Images go only to an agent that declares it reads them; otherwise their caption stands in.
        let images = acceptsImages ? await AgentSummaryTask.images(recording, store: noteImages ?? FolderNoteImageStore(directory: storeDirectory)) : []
        let text = try AgentSummaryTask.prompt(recording, language: language, attached: Set(images.map(\.id)))
        let blocks: [[String: Any]] = [["type": "text", "text": text]] + images.flatMap { id, png in
            [["type": "text", "text": id], ["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()]]
        }
        let promptParams = try json(["sessionId": sessionID, "prompt": blocks])
        let response: Data
        do {
            response = try await withTaskCancellationHandler {
                try await connection.request("session/prompt", params: promptParams)
            } onCancel: {
                Task {
                    await connection.notify("session/cancel", params: (try? json(["sessionId": sessionID])) ?? Data())
                    try? await Task.sleep(for: .seconds(2)); await connection.terminate()
                }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if ContinuousClock.now - started >= timeout { throw AgentSummaryFailure.timedOut }
            // A submission accepted before the agent exited still counts.
            guard (try? AgentSummaryTask.readHandoff(directory: handoff)) != nil else { throw error }
            response = Data("{}".utf8)
        }
        try Task.checkCancellation()
        let stopReason = (try? JSONSerialization.jsonObject(with: response) as? [String: Any])?["stopReason"] as? String
        var handed = try AgentSummaryTask.readHandoff(directory: handoff)
        if handed == nil {
            // Some agents answer with the summary as text instead of calling the tool. The same
            // validation applies; a rejected text summary fails with its reason.
            let message = await lastMessage.full
            if let json = AgentSummaryTask.jsonObject(in: message) {
                handed = .init(inputHash: inputHash, summary: try AgentSummaryTask.accept(json, recording: recording))
            } else {
                let tail = await lastMessage.text
                throw AgentSummaryFailure.noSummary(tail.isEmpty ? (stopReason.map { String(localized: "arrêt : \($0)", bundle: .hwyd) } ?? "") : tail)
            }
        }
        guard let result = handed else { throw AgentSummaryFailure.noSummary("") }
        guard result.inputHash == inputHash else { throw AgentSummaryFailure.stale }
        // Defense in depth: the app re-validates what the helper accepted.
        try SummaryPipeline.validate(result.summary, segments: AgentSummaryTask.segments(recording), speakers: recording.speakers,
                                     maximumEvidenceReferences: AgentSummaryTask.maximumEvidenceReferences, maximumDetails: AgentSummaryTask.maximumDetails)
        await progress(.init(stage: String(localized: "Compte rendu prêt", bundle: .hwyd), completed: 1, total: 1, cached: false))
        return SummaryProvenance(provider: "acp|" + command, model: agentName.isEmpty ? command : agentName,
                                 promptVersion: AgentSummaryTask.promptVersion(for: language), promptHash: AgentSummaryTask.promptHash(for: language),
                                 generatedAt: Date(), transcriptVersion: recording.transcriptVersion, inputHash: inputHash, structured: result.summary,
                                 language: language.code, usedNotes: AgentSummaryTask.hasNotes(recording) ? true : nil)
    }

    private static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) }
}

/// Splits a byte stream on newlines. Only touched from one pipe's readability handler at a time.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
    func flush() -> Data? { defer { pending = Data() }; return pending.isEmpty ? nil : pending }
}

private actor MessageTail {
    private var value = ""
    func append(_ text: String) { value = String((value + text).suffix(400_000)) }
    var full: String { value }
    var text: String { String(value.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines) }
}

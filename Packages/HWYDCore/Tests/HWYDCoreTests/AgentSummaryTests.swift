import XCTest
@testable import HWYDCore

/// Agent summaries without a real agent: a scripted ACP agent stands in, and no network is used.
final class AgentSummaryTests: XCTestCase {
    private func recording() -> Recording {
        let camille = Speaker(label: "Camille", confirmed: true)
        var echo = Speaker(label: "Écho"); echo.ignored = true
        var recording = Recording(title: "Atelier", speakers: [camille, echo], isDemo: true)
        recording.segments = [
            TranscriptSegment(start: 0, end: 5, speakerID: camille.id, source: .mic, text: "On valide le lancement."),
            TranscriptSegment(start: 5, end: 8, speakerID: echo.id, source: .mic, text: "écho"),
            TranscriptSegment(start: 8, end: 12, speakerID: camille.id, source: .mic, text: "Je rédigerai l'annonce."),
        ]
        return recording
    }
    private let valid = #"{"overview":"Camille valide le lancement.","decisions":[{"text":"Le lancement est validé.","evidence_segment_ids":["S1"]}],"action_items":[{"text":"Rédiger l'annonce.","assignee_name":"Camille","evidence_segment_ids":["S2"]}],"details":[{"title":"Lancement","text":"Le lancement est validé et Camille rédigera l'annonce.","evidence_segment_ids":["S1","S2"]}],"context":[{"title":"Projet Atlas","text":"Le lancement prolonge la décision du comité de mars.","sources":["notes/atlas.md"]}]}"#

    func testPromptSendsHeardPassagesWithShortReferencesOnly() throws {
        let item = recording()
        let prompt = try AgentSummaryTask.prompt(item)
        XCTAssertTrue(prompt.contains(#""id":"S2","speaker":"Camille""#))
        XCTAssertFalse(prompt.contains("écho"), "Ignored voices never reach the agent")
        XCTAssertFalse(prompt.contains(item.segments[0].id.uuidString))
        XCTAssertTrue(prompt.contains("submit_summary"))
    }

    func testAcceptedSubmissionMapsReferencesAndKeepsContextApart() throws {
        let item = recording()
        let content = try AgentSummaryTask.accept(Data(valid.utf8), recording: item)
        XCTAssertEqual(content.action_items.first?.evidence_segment_ids, [item.segments[2].id])
        XCTAssertNil(content.action_items.first?.due_date)
        XCTAssertEqual(content.context?.first?.sources, ["notes/atlas.md"])
        XCTAssertTrue(content.markdown.contains("## Contexte"))
        XCTAssertFalse(content.markdown.contains("S1"))
    }

    func testRejectedSubmissionsExplainWhy() {
        let item = recording()
        func reason(_ json: String) -> String? {
            do { _ = try AgentSummaryTask.accept(Data(json.utf8), recording: item); return nil }
            catch { return error.localizedDescription }
        }
        XCTAssertTrue(reason(valid.replacingOccurrences(of: #"["S2"]"#, with: #"["S9"]"#))?.contains("S9") == true)
        XCTAssertTrue(reason(valid.replacingOccurrences(of: #""assignee_name":"Camille""#, with: #""assignee_name":"Jordan""#))?.contains("Jordan") == true)
        XCTAssertNotNil(reason("[]"))
    }

    func testTextAnswerFallbackFindsTheSummaryObject() throws {
        let item = recording()
        let wrapped = "Voici la synthèse :\n```json\n{\"summary\": " + valid + "}\n```"
        let data = try XCTUnwrap(AgentSummaryTask.jsonObject(in: wrapped))
        XCTAssertEqual(try AgentSummaryTask.accept(data, recording: item).overview, "Camille valide le lancement.")
        XCTAssertNil(AgentSummaryTask.jsonObject(in: "Je ne trouve pas l'outil."))
    }

    func testPermissionPolicyAllowsReadingAndRejectsChanges() {
        let options: [[String: Any]] = [["optionId": "yes", "name": "Allow", "kind": "allow_once"], ["optionId": "no", "name": "Reject", "kind": "reject_once"]]
        func outcome(_ toolCall: [String: Any]) -> String? {
            ((ACPPermissionPolicy.response(to: ["sessionId": "s", "toolCall": toolCall, "options": options])["outcome"]) as? [String: Any])?["optionId"] as? String
        }
        XCTAssertEqual(outcome(["toolCallId": "1", "kind": "read", "title": "Read notes.md"]), "yes")
        XCTAssertEqual(outcome(["toolCallId": "2", "kind": "edit", "title": "Write summary.md"]), "no")
        XCTAssertEqual(outcome(["toolCallId": "3", "kind": "execute", "title": "rm -rf"]), "no")
        XCTAssertEqual(outcome(["toolCallId": "4", "kind": "other", "title": "mcp__hwyd__submit_summary"]), "yes")
        XCTAssertEqual(outcome(["toolCallId": "5", "kind": "other", "title": "mcp__notion__create_page"]), "no")
        XCTAssertTrue(ACPConnection.answer(method: "fs/write_text_file", params: Data("{}".utf8), id: "7").contains("-32601"))
    }

    /// End to end over real pipes: initialize, session/new with the restricted MCP server,
    /// a rejected write permission, then the handoff that `submit_summary` would write.
    func testScriptedAgentCompletesARun() async throws {
        let item = recording()
        let content = try AgentSummaryTask.accept(Data(valid.utf8), recording: item)
        let handoff = String(decoding: try JSONEncoder().encode(AgentSummaryTask.Handoff(inputHash: SummaryPipeline.inputHash(item), summary: content)), as: UTF8.self)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acp-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("permission.txt")
        let script = directory.appendingPathComponent("agent.py")
        try """
        import json, sys, os
        HANDOFF = \(String(decoding: try JSONSerialization.data(withJSONObject: [handoff], options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self))[0]
        def send(obj): sys.stdout.write(json.dumps(obj) + "\\n"); sys.stdout.flush()
        def read():
            line = sys.stdin.readline()
            return json.loads(line) if line else None
        handoff_dir = None
        while True:
            msg = read()
            if msg is None: break
            m = msg.get("method")
            if m == "initialize":
                assert msg["params"]["clientCapabilities"]["fs"]["writeTextFile"] is False
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1, "agentInfo": {"name": "scripted-agent", "version": "1.0"}}})
            elif m == "session/new":
                args = msg["params"]["mcpServers"][0]["args"]
                handoff_dir = args[args.index("--summary-handoff") + 1]
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "s1"}})
            elif m == "session/prompt":
                assert "submit_summary" in msg["params"]["prompt"][0]["text"]
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Lecture du transcript", "kind": "read"}}})
                send({"jsonrpc": "2.0", "id": "perm-1", "method": "session/request_permission", "params": {"sessionId": "s1", "toolCall": {"toolCallId": "t2", "kind": "edit", "title": "Write notes.md"}, "options": [{"optionId": "ok", "name": "Allow", "kind": "allow_once"}, {"optionId": "ko", "name": "Reject", "kind": "reject_once"}]}})
                answer = read()
                open(\(String(decoding: try JSONSerialization.data(withJSONObject: [log.path], options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self))[0], "w").write(answer["result"]["outcome"]["optionId"])
                open(os.path.join(handoff_dir, "summary.json"), "w").write(HANDOFF)
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": "end_turn"}})
        """.write(to: script, atomically: true, encoding: .utf8)
        let stages = StageLog()
        let result = try await ACPSummaryAgent.run(item, command: "python3 " + script.path, workingDirectory: directory,
            mcpExecutable: URL(fileURLWithPath: "/usr/bin/true"), storeDirectory: directory) { await stages.add($0.stage) }
        XCTAssertEqual(result.structured, content)
        XCTAssertEqual(result.model, "scripted-agent 1.0")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "ko", "Write permissions are rejected")
        let seen = await stages.values
        XCTAssertTrue(seen.contains("Agent : Lecture du transcript"))
    }

    func testAgentThatNeverSubmitsReportsItsLastMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acp-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("agent.py")
        try """
        import json, sys
        for line in sys.stdin:
            msg = json.loads(line); m = msg.get("method")
            reply = lambda r: (sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": r}) + "\\n"), sys.stdout.flush())
            if m == "initialize": reply({"protocolVersion": 1})
            elif m == "session/new": reply({"sessionId": "s"})
            elif m == "session/prompt":
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Je ne trouve pas l'outil."}}}}) + "\\n")
                reply({"stopReason": "end_turn"})
        """.write(to: script, atomically: true, encoding: .utf8)
        do {
            _ = try await ACPSummaryAgent.run(recording(), command: "python3 " + script.path, workingDirectory: directory,
                                              mcpExecutable: URL(fileURLWithPath: "/usr/bin/true"), storeDirectory: directory)
            XCTFail("No submission must fail")
        } catch let failure as AgentSummaryFailure {
            XCTAssertEqual(failure, .noSummary("Je ne trouve pas l'outil."))
        }
    }
}

extension AgentSummaryTests {
    func testAgentThatCrashesReportsItsError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acp-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("agent.py")
        try """
        import json, sys
        for line in sys.stdin:
            msg = json.loads(line); m = msg.get("method")
            if m == "initialize": print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1}}), flush=True)
            elif m == "session/new": print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "s"}}), flush=True)
            else:
                print(json.dumps({"jsonrpc": "2.0", "id": "p", "method": "session/request_permission", "params": {"sessionId": "s", "toolCall": {"toolCallId": "t", "kind": "edit"}, "options": [{"optionId": "ko", "name": "No", "kind": "reject_once"}]}}), flush=True)
                sys.stdin.readline()
                sys.stderr.write("boom: model unavailable\\n"); sys.exit(3)
        """.write(to: script, atomically: true, encoding: .utf8)
        do {
            _ = try await ACPSummaryAgent.run(recording(), command: "python3 " + script.path, workingDirectory: directory,
                                              mcpExecutable: URL(fileURLWithPath: "/usr/bin/true"), storeDirectory: directory)
            XCTFail("A crash must fail")
        } catch let failure as AgentSummaryFailure {
            guard case .exited(let detail) = failure else { return XCTFail("Unexpected \(failure)") }
            XCTAssertTrue(detail.contains("boom"), detail)
        }
    }
}

extension AgentSummaryTests {
    /// Opt-in run with a real ACP agent on a stored session. The agent uses the user's account.
    func testRealAgentWhenExplicitlyRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let command = env["HWYD_AGENT_COMMAND"], let store = env["HWYD_SUMMARY_STORE"], let helper = env["HWYD_AGENT_MCP"],
              let id = env["HWYD_SUMMARY_RECORDING_ID"].flatMap(UUID.init(uuidString:)), let output = env["HWYD_SUMMARY_OUTPUT"] else { throw XCTSkip("Real agent run not requested") }
        let recording = try await SessionStore(directory: URL(fileURLWithPath: store), readOnly: true, migrate: false).recording(id)
        let started = Date()
        do {
            let result = try await ACPSummaryAgent.run(recording, command: command,
                workingDirectory: URL(fileURLWithPath: env["HWYD_AGENT_CWD"] ?? NSHomeDirectory()), mcpExecutable: URL(fileURLWithPath: helper),
                storeDirectory: URL(fileURLWithPath: store)) { print("AGENT \($0.stage)") }
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            try result.structured.markdown.write(to: URL(fileURLWithPath: output).appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            print("AGENT DONE \(result.model) in \(Int(Date().timeIntervalSince(started))) s")
        } catch {
            print("AGENT FAILURE: \(error.localizedDescription)")
            throw error
        }
    }
}

private actor StageLog {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

/// Notes anchor the agent summary: timed entries tied to a passage, free notes, and images when the agent reads them.
extension AgentSummaryTests {
    private struct FixedImages: NoteImageStore {
        let files: [UUID: Data]
        func add(_ data: Data, to session: UUID) async throws -> NoteImage { throw NoteImageError.notAnImage }
        func data(of image: NoteImage, in session: UUID) async -> Data? { files[image.id] }
    }

    private func notedRecording() -> (Recording, NoteImage) {
        var item = recording()
        let whiteboard = NoteImage(width: 2, height: 2)
        item.noteEntries = [
            NoteEntry(offset: 9, text: "Annonce : Camille"),
            NoteEntry(offset: 6, text: "Tableau du plan", image: whiteboard),
        ]
        item.notes = "Penser au budget Atlas"
        return (item, whiteboard)
    }

    func testPromptCarriesNotesAnchoredToThePassageUnderWay() throws {
        let (item, _) = notedRecording()
        let prompt = try AgentSummaryTask.prompt(item, attached: ["N1"])
        // Ordered by time; S2 is the second heard passage (the echo voice is left out), started at 8 s.
        XCTAssertTrue(prompt.contains(#"{"at":"00:06","id":"N1","image":"jointe","near":"S1","text":"Tableau du plan"}"#), prompt)
        XCTAssertTrue(prompt.contains(#"{"at":"00:09","id":"N2","near":"S2","text":"Annonce : Camille"}"#), prompt)
        XCTAssertTrue(prompt.contains("Penser au budget Atlas"))
        XCTAssertTrue(try AgentSummaryTask.prompt(item).contains(#""image":"non transmise""#))
        XCTAssertTrue(try AgentSummaryTask.prompt(recording()).contains("NOTES LIBRES :\n(aucune)"))
    }

    func testNotesChangeTheInputHashOnlyWhenPresent() throws {
        let plain = recording()
        var noted = plain
        noted.noteEntries = [NoteEntry(offset: 1, text: "x")]
        XCTAssertNotEqual(try SummaryPipeline.inputHash(plain), try SummaryPipeline.inputHash(noted))
        noted.noteEntries = []
        XCTAssertEqual(try SummaryPipeline.inputHash(plain), try SummaryPipeline.inputHash(noted), "Sessions without timed notes keep their hash")
    }

    func testImagesAreCappedAndOversizedOnesLeftOut() async {
        var item = recording()
        let images = (0..<(AgentSummaryTask.maximumImages + 2)).map { _ in NoteImage(width: 1, height: 1) }
        item.noteEntries = images.enumerated().map { NoteEntry(offset: Double($0.offset), image: $0.element) }
        var files = Dictionary(uniqueKeysWithValues: images.map { ($0.id, Data([1])) })
        files[images[0].id] = Data(count: AgentSummaryTask.maximumImageBytes + 1)
        let attached = await AgentSummaryTask.images(item, store: FixedImages(files: files))
        XCTAssertEqual(attached.map(\.id), (2...(AgentSummaryTask.maximumImages + 1)).map { "N\($0)" })
    }

    /// The scripted agent records the prompt blocks it receives, then stops without submitting.
    private func promptBlocks(acceptsImages: Bool) async throws -> [[String: Any]] {
        let (item, whiteboard) = notedRecording()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acp-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("prompt.json")
        let script = directory.appendingPathComponent("agent.py")
        try """
        import json, sys
        for line in sys.stdin:
            msg = json.loads(line); m = msg.get("method")
            reply = lambda r: (sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": r}) + "\\n"), sys.stdout.flush())
            if m == "initialize": reply({"protocolVersion": 1, "agentCapabilities": {"promptCapabilities": {"image": \(acceptsImages ? "True" : "False")}}})
            elif m == "session/new": reply({"sessionId": "s"})
            elif m == "session/prompt":
                open(sys.argv[1], "w").write(json.dumps(msg["params"]["prompt"]))
                reply({"stopReason": "end_turn"})
        """.write(to: script, atomically: true, encoding: .utf8)
        _ = try? await ACPSummaryAgent.run(item, command: "python3 " + script.path + " " + output.path, workingDirectory: directory,
                                           mcpExecutable: URL(fileURLWithPath: "/usr/bin/true"), storeDirectory: directory,
                                           noteImages: FixedImages(files: [whiteboard.id: Data("png".utf8)]))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [[String: Any]])
    }

    func testImagesFollowThePromptOnlyForAnAgentThatReadsThem() async throws {
        let reading = try await promptBlocks(acceptsImages: true)
        XCTAssertEqual(reading.count, 3)
        XCTAssertEqual(reading[1]["text"] as? String, "N1")
        XCTAssertEqual(reading[2]["type"] as? String, "image")
        XCTAssertEqual(reading[2]["data"] as? String, Data("png".utf8).base64EncodedString())
        XCTAssertTrue((reading[0]["text"] as? String)?.contains(#""image":"jointe""#) == true)

        let blind = try await promptBlocks(acceptsImages: false)
        XCTAssertEqual(blind.count, 1)
        XCTAssertTrue((blind[0]["text"] as? String)?.contains(#""image":"non transmise""#) == true)
    }
}

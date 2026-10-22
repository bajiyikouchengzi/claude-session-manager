import XCTest
@testable import 会话管家

final class ProviderScanTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testLegacySessionJSONDecodesAsClaude() throws {
        let json = """
        {"id":"abc","source":"merged","title":"旧会话","byteSize":3,"isArchived":false,"isFavorite":true,"tags":["a"]}
        """.data(using: .utf8)!
        let session = try JSONDecoder().decode(SessionRecord.self, from: json)
        XCTAssertEqual(session.provider, .claude)
        XCTAssertEqual(session.title, "旧会话")
        XCTAssertTrue(session.isFavorite)
        XCTAssertNil(session.containerURL)
        XCTAssertTrue(session.canEditSource)
    }

    func testMissingForeignStoresStayEmpty() {
        var settings = AppSettings.detectDefaults()
        settings.scanCodex = true
        settings.scanGrok = true
        settings.scanOpenCode = true
        settings.codexHome = temporaryRoot.appendingPathComponent("no-codex").path
        settings.grokHome = temporaryRoot.appendingPathComponent("no-grok").path
        settings.openCodeDatabase = temporaryRoot.appendingPathComponent("no-opencode.db").path

        let loaded = ForeignSessionScanner.load(settings: settings, includeBodies: false, maxBodyBytes: 10_000)
        XCTAssertTrue(loaded.sessions.isEmpty)
        XCTAssertTrue(loaded.errors.isEmpty)
    }

    func testCodexGrokAndOpenCodeScan() throws {
        let codexID = "11111111-1111-1111-1111-111111111111"
        let archivedID = "33333333-3333-3333-3333-333333333333"
        let grokID = "22222222-2222-2222-2222-222222222222"
        let openCodeID = "44444444-4444-4444-4444-444444444444"

        let codexRoot = temporaryRoot.appendingPathComponent("codex", isDirectory: true)
        let liveDir = codexRoot.appendingPathComponent("sessions/2026/10/20", isDirectory: true)
        let archivedDir = codexRoot.appendingPathComponent("archived_sessions/2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)
        let liveFile = liveDir.appendingPathComponent("rollout-2026-10-20T11-29-00-\(codexID).jsonl")
        try """
        {"type":"session_meta","timestamp":"2026-10-20T03:29:00Z","payload":{"session_id":"\(codexID)","cwd":"/tmp/codex-proj","timestamp":"2026-10-20T03:29:00Z"}}
        {"type":"turn_context","timestamp":"2026-10-20T03:29:01Z","payload":{"model":"gpt-test","effort":"high","cwd":"/tmp/codex-proj"}}
        {"type":"response_item","timestamp":"2026-10-20T03:29:02Z","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"hidden instructions"}]}}
        {"type":"response_item","timestamp":"2026-10-20T03:29:03Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the login button"}]}}
        {"type":"response_item","timestamp":"2026-10-20T03:29:04Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}
        {"type":"response_item","timestamp":"2026-10-20T03:29:05Z","payload":{"type":"reasoning","summary":"hidden reasoning"}}
        """.write(to: liveFile, atomically: true, encoding: .utf8)
        let archivedFile = archivedDir.appendingPathComponent("rollout-2026-10-01T01-00-00-\(archivedID).jsonl")
        try """
        {"type":"session_meta","payload":{"session_id":"\(archivedID)","cwd":"/tmp/old-proj","timestamp":"2026-10-01T01:00:00Z"}}
        """.write(to: archivedFile, atomically: true, encoding: .utf8)

        let grokDir = temporaryRoot
            .appendingPathComponent("grok/sessions/%2Ftmp%2Fgrok-proj/\(grokID)", isDirectory: true)
        try FileManager.default.createDirectory(at: grokDir, withIntermediateDirectories: true)
        try """
        {"info":{"id":"\(grokID)","cwd":"/tmp/grok-proj"},"generated_title":"菜单栏静音","created_at":"2026-10-21T01:02:03Z","updated_at":"2026-10-21T02:02:03Z","last_active_at":"2026-10-21T02:02:03Z","num_chat_messages":4,"current_model_id":"grok-test","reasoning_effort":"medium","head_branch":"main"}
        """.write(to: grokDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try """
        {"type":"system","content":"secret system prompt"}
        {"type":"user","content":"hello grok"}
        {"type":"assistant","content":"hi there"}
        {"type":"reasoning","content":"hidden chain"}
        """.write(to: grokDir.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let database = temporaryRoot.appendingPathComponent("opencode.db")
        try makeOpenCodeDatabase(at: database, sessionID: openCodeID)

        var settings = AppSettings.detectDefaults()
        settings.scanCodex = true
        settings.scanGrok = true
        settings.scanOpenCode = true
        settings.codexHome = codexRoot.path
        settings.grokHome = temporaryRoot.appendingPathComponent("grok").path
        settings.openCodeDatabase = database.path

        let loaded = ForeignSessionScanner.load(settings: settings, includeBodies: true, maxBodyBytes: 20_000)
        XCTAssertTrue(loaded.errors.isEmpty, loaded.errors.joined(separator: " | "))

        let codex = try XCTUnwrap(loaded.sessions.first { $0.provider == .codex && $0.nativeSessionID == codexID })
        XCTAssertEqual(codex.title, "fix the login button")
        XCTAssertEqual(codex.cwd, "/tmp/codex-proj")
        XCTAssertEqual(codex.model, "gpt-test")
        XCTAssertEqual(codex.effort, "high")
        XCTAssertFalse(codex.isArchived)
        XCTAssertFalse(codex.canEditSource)
        XCTAssertEqual(ResumeAction.command(for: codex), "cd '/tmp/codex-proj' && codex resume \(codexID)")
        let codexPreview = TranscriptText.previewTurns(for: codex, limit: 12).map(\.text).joined(separator: "\n")
        XCTAssertTrue(codexPreview.contains("fix the login button"))
        XCTAssertFalse(codexPreview.contains("hidden instructions"))
        XCTAssertFalse(codexPreview.contains("hidden reasoning"))

        let archived = try XCTUnwrap(loaded.sessions.first { $0.nativeSessionID == archivedID })
        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(archived.provider, .codex)

        let grok = try XCTUnwrap(loaded.sessions.first { $0.provider == .grok })
        XCTAssertEqual(grok.title, "菜单栏静音")
        XCTAssertEqual(grok.cwd, "/tmp/grok-proj")
        XCTAssertEqual(grok.model, "grok-test")
        XCTAssertEqual(grok.gitBranch, "main")
        XCTAssertEqual(grok.messageCount, 4)
        XCTAssertEqual(ResumeAction.command(for: grok), "cd '/tmp/grok-proj' && grok --resume \(grokID)")
        let grokPreview = TranscriptText.previewTurns(for: grok, limit: 12)
        XCTAssertEqual(grokPreview.map(\.role), ["user", "assistant"])
        XCTAssertFalse(grokPreview.contains { $0.text.contains("secret system prompt") })
        XCTAssertFalse(grokPreview.contains { $0.text.contains("hidden chain") })
        let grokBody = TranscriptText.searchableBody(for: grok, maxBytes: 20_000)
        XCTAssertTrue(grokBody.contains("hello grok"))
        XCTAssertFalse(grokBody.contains("secret system prompt"))

        let openCode = try XCTUnwrap(loaded.sessions.first { $0.provider == .opencode && $0.nativeSessionID == openCodeID })
        XCTAssertEqual(openCode.title, "打开数据库")
        XCTAssertEqual(openCode.cwd, "/tmp/opencode-proj")
        XCTAssertEqual(openCode.projectName, "DemoProj")
        XCTAssertEqual(openCode.model, "test/demo")
        XCTAssertFalse(openCode.isArchived)
        XCTAssertEqual(openCode.containerURL?.path, database.path)
        XCTAssertEqual(ResumeAction.command(for: openCode), "cd '/tmp/opencode-proj' && opencode -s \(openCodeID)")
        XCTAssertGreaterThan(openCode.byteSize, 0)
        let openPreview = TranscriptText.previewTurns(for: openCode, limit: 12)
        XCTAssertEqual(openPreview.map(\.text), ["open me", "opened"])
        let openBody = loaded.bodies[openCode.id, default: ""]
        XCTAssertTrue(openBody.contains("open me"))
        XCTAssertFalse(openBody.contains("hidden chain"))
        XCTAssertFalse(openBody.contains("super-secret-token"))
        XCTAssertFalse(loaded.sessions.contains { ($0.title + ($0.model ?? "")).contains("super-secret-token") })

        let archivedOpen = try XCTUnwrap(loaded.sessions.first { $0.nativeSessionID == "55555555-5555-5555-5555-555555555555" })
        XCTAssertTrue(archivedOpen.isArchived)
    }

    func testTrashRefusesNonClaudeSession() throws {
        let sourceDir = temporaryRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let transcript = sourceDir.appendingPathComponent("session.jsonl")
        try "{\"type\":\"user\"}\n".write(to: transcript, atomically: true, encoding: .utf8)
        var session = SessionRecord(
            id: "codex:abc",
            provider: .codex,
            source: .external,
            title: "Codex",
            cwd: temporaryRoot.path,
            projectName: "tmp",
            model: nil,
            effort: nil,
            createdAt: nil,
            lastActivityAt: nil,
            byteSize: 1,
            messageCount: 1,
            completedTurns: nil,
            isArchived: false,
            isFavorite: false,
            tags: [],
            gitBranch: nil,
            desktopSessionId: nil,
            cliSessionId: "abc",
            metaURL: nil,
            transcriptURL: transcript,
            parseError: nil,
            titleSource: nil
        )
        let service = TrashService(root: temporaryRoot.appendingPathComponent("Trash"))
        XCTAssertThrowsError(try service.moveToTrash(session)) { error in
            guard case TrashError.readOnlyProvider = error else {
                return XCTFail("Expected readOnlyProvider, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
        XCTAssertTrue(service.list().isEmpty)
        session.provider = .claude
        _ = try service.moveToTrash(session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
    }

    private func makeOpenCodeDatabase(at database: URL, sessionID: String) throws {
        let sql = """
        CREATE TABLE session (
          id TEXT PRIMARY KEY,
          project_id TEXT,
          directory TEXT,
          title TEXT,
          model TEXT,
          time_created INTEGER,
          time_updated INTEGER,
          time_archived INTEGER
        );
        CREATE TABLE project (
          id TEXT PRIMARY KEY,
          name TEXT,
          worktree TEXT
        );
        CREATE TABLE message (
          id TEXT PRIMARY KEY,
          session_id TEXT,
          time_created INTEGER,
          data TEXT
        );
        CREATE TABLE part (
          id TEXT PRIMARY KEY,
          message_id TEXT,
          session_id TEXT,
          time_created INTEGER,
          data TEXT
        );
        CREATE TABLE credential (
          id TEXT PRIMARY KEY,
          value TEXT
        );
        INSERT INTO credential VALUES ('cred', 'super-secret-token');
        INSERT INTO project VALUES ('P1', 'DemoProj', '/tmp/opencode-proj');
        INSERT INTO session VALUES ('\(sessionID)', 'P1', '/tmp/opencode-proj', '打开数据库', '{"id":"demo","providerID":"test"}', 1781662142972, 1781662326209, NULL);
        INSERT INTO session VALUES ('55555555-5555-5555-5555-555555555555', 'P1', '/tmp/opencode-proj', '已归档', NULL, 1780000000000, 1780000001000, 1780000002000);
        INSERT INTO message VALUES ('M1', '\(sessionID)', 1000, '{"role":"user"}');
        INSERT INTO message VALUES ('M2', '\(sessionID)', 2000, '{"role":"assistant"}');
        INSERT INTO part VALUES ('P1', 'M1', '\(sessionID)', 1000, '{"type":"text","text":"open me"}');
        INSERT INTO part VALUES ('P2', 'M2', '\(sessionID)', 2000, '{"type":"reasoning","text":"hidden chain"}');
        INSERT INTO part VALUES ('P3', 'M2', '\(sessionID)', 2001, '{"type":"text","text":"opened"}');
        """
        let script = temporaryRoot.appendingPathComponent("opencode.sql")
        try sql.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path]
        process.standardInput = try FileHandle(forReadingFrom: script)
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

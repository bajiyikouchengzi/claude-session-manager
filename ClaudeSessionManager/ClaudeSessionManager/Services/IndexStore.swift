import Foundation
import SQLite3

/// Lightweight SQLite + FTS5 index for session metadata and body search.
/// Uses the system SQLite (no third-party deps) to stay lightweight.
final class IndexStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "csm.index", qos: .userInitiated)
    private let path: String

    init(url: URL = AppPaths.indexDB) {
        path = url.path
        openAndMigrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func openAndMigrate() {
        if sqlite3_open(path, &db) != SQLITE_OK {
            db = nil
            return
        }
        exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS sessions (
          id TEXT PRIMARY KEY,
          source TEXT,
          title TEXT,
          cwd TEXT,
          project_name TEXT,
          model TEXT,
          effort TEXT,
          created_at REAL,
          last_activity_at REAL,
          byte_size INTEGER,
          message_count INTEGER,
          completed_turns INTEGER,
          is_archived INTEGER,
          git_branch TEXT,
          desktop_session_id TEXT,
          cli_session_id TEXT,
          meta_path TEXT,
          transcript_path TEXT,
          parse_error TEXT,
          title_source TEXT
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
          id UNINDEXED,
          title,
          cwd,
          body,
          tokenize = 'unicode61'
        );
        CREATE INDEX IF NOT EXISTS idx_sessions_activity ON sessions(last_activity_at DESC);
        CREATE INDEX IF NOT EXISTS idx_sessions_cwd ON sessions(cwd);
        """)
    }

    func replaceAll(_ sessions: [SessionRecord], bodyByID: [String: String]) {
        queue.sync {
            exec("BEGIN")
            exec("DELETE FROM sessions")
            exec("DELETE FROM sessions_fts")
            for s in sessions {
                insertLocked(s, body: bodyByID[s.id] ?? "")
            }
            exec("COMMIT")
        }
    }

    func upsert(_ session: SessionRecord, body: String?) {
        queue.sync {
            exec("BEGIN")
            exec("DELETE FROM sessions WHERE id = \(sqlString(session.id))")
            exec("DELETE FROM sessions_fts WHERE id = \(sqlString(session.id))")
            insertLocked(session, body: body ?? "")
            exec("COMMIT")
        }
    }

    func delete(id: String) {
        queue.sync {
            exec("DELETE FROM sessions WHERE id = \(sqlString(id))")
            exec("DELETE FROM sessions_fts WHERE id = \(sqlString(id))")
        }
    }

    func allSessions() -> [SessionRecord] {
        queue.sync {
            var result: [SessionRecord] = []
            let sql = "SELECT * FROM sessions ORDER BY COALESCE(last_activity_at, created_at, 0) DESC"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let s = rowToSession(stmt) { result.append(s) }
            }
            return result
        }
    }

    /// Quick search on title/cwd (no body).
    func searchMeta(query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return queue.sync {
            let like = "%\(q.replacingOccurrences(of: "%", with: "\\%"))%"
            let sql = """
            SELECT id FROM sessions
            WHERE title LIKE \(sqlString(like)) ESCAPE '\\'
               OR cwd LIKE \(sqlString(like)) ESCAPE '\\'
               OR project_name LIKE \(sqlString(like)) ESCAPE '\\'
               OR id LIKE \(sqlString(like)) ESCAPE '\\'
            ORDER BY COALESCE(last_activity_at, 0) DESC
            LIMIT 500
            """
            return selectIDs(sql)
        }
    }

    /// Full-text search including body (FTS5).
    func searchFullText(query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return queue.sync {
            // Quote tokens loosely for FTS; fall back to prefix.
            let sanitized = ftsQuery(from: q)
            let sql = """
            SELECT id FROM sessions_fts
            WHERE sessions_fts MATCH \(sqlString(sanitized))
            ORDER BY rank
            LIMIT 500
            """
            return selectIDs(sql)
        }
    }

    // MARK: - Internals

    private func insertLocked(_ s: SessionRecord, body: String) {
        let sql = """
        INSERT INTO sessions (
          id, source, title, cwd, project_name, model, effort,
          created_at, last_activity_at, byte_size, message_count, completed_turns,
          is_archived, git_branch, desktop_session_id, cli_session_id,
          meta_path, transcript_path, parse_error, title_source
        ) VALUES (
          \(sqlString(s.id)),
          \(sqlString(s.source.rawValue)),
          \(sqlString(s.title)),
          \(sqlString(s.cwd)),
          \(sqlString(s.projectName)),
          \(sqlString(s.model)),
          \(sqlString(s.effort)),
          \(sqlDouble(s.createdAt)),
          \(sqlDouble(s.lastActivityAt)),
          \(s.byteSize),
          \(sqlInt(s.messageCount)),
          \(sqlInt(s.completedTurns)),
          \(s.isArchived ? 1 : 0),
          \(sqlString(s.gitBranch)),
          \(sqlString(s.desktopSessionId)),
          \(sqlString(s.cliSessionId)),
          \(sqlString(s.metaURL?.path)),
          \(sqlString(s.transcriptURL?.path)),
          \(sqlString(s.parseError)),
          \(sqlString(s.titleSource))
        );
        INSERT INTO sessions_fts (id, title, cwd, body) VALUES (
          \(sqlString(s.id)),
          \(sqlString(s.title)),
          \(sqlString(s.cwd)),
          \(sqlString(body))
        );
        """
        exec(sql)
    }

    private func selectIDs(_ sql: String) -> [String] {
        var ids: [String] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                ids.append(String(cString: c))
            }
        }
        return ids
    }

    private func rowToSession(_ stmt: OpaquePointer?) -> SessionRecord? {
        guard let stmt else { return nil }
        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            let s = String(cString: c)
            return s.isEmpty ? nil : s
        }
        func date(_ i: Int32) -> Date? {
            if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
            let v = sqlite3_column_double(stmt, i)
            if v == 0 { return nil }
            return Date(timeIntervalSince1970: v)
        }
        func intOpt(_ i: Int32) -> Int? {
            if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
            return Int(sqlite3_column_int64(stmt, i))
        }

        guard let id = text(0) else { return nil }
        let source = SessionSource(rawValue: text(1) ?? "") ?? .codeJsonl
        return SessionRecord(
            id: id,
            source: source,
            title: text(2) ?? "",
            cwd: text(3),
            projectName: text(4),
            model: text(5),
            effort: text(6),
            createdAt: date(7),
            lastActivityAt: date(8),
            byteSize: sqlite3_column_int64(stmt, 9),
            messageCount: intOpt(10),
            completedTurns: intOpt(11),
            isArchived: sqlite3_column_int(stmt, 12) != 0,
            isFavorite: false,
            tags: [],
            gitBranch: text(13),
            desktopSessionId: text(14),
            cliSessionId: text(15),
            metaURL: text(16).map { URL(fileURLWithPath: $0) },
            transcriptURL: text(17).map { URL(fileURLWithPath: $0) },
            parseError: text(18),
            titleSource: text(19)
        )
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "sqlite error \(rc)"
            if let err { sqlite3_free(err) }
            #if DEBUG
            print("[IndexStore] SQL error: \(message)")
            #endif
            AuditLog.write("index.sql.error \(message)")
            return false
        }
        return true
    }

    private func sqlString(_ value: String?) -> String {
        guard let value else { return "NULL" }
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    private func sqlDouble(_ date: Date?) -> String {
        guard let date else { return "NULL" }
        return String(date.timeIntervalSince1970)
    }

    private func sqlInt(_ value: Int?) -> String {
        guard let value else { return "NULL" }
        return String(value)
    }

    private func ftsQuery(from raw: String) -> String {
        let parts = raw
            .split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }
        if parts.isEmpty { return raw }
        // AND together token prefixes; quote tokens containing special chars simply by stripping.
        return parts.map { token -> String in
            let cleaned = token.replacingOccurrences(of: "\"", with: "")
            if cleaned.isEmpty { return "" }
            return "\"\(cleaned)\"*"
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

import Foundation
import SQLite3

struct ForeignScanResult: Sendable {
    var sessions: [SessionRecord] = []
    var bodies: [String: String] = [:]
    var errors: [String] = []
}

/// Read-only discovery for Codex, Grok, and OpenCode session stores.
enum ForeignSessionScanner {
    static func load(settings: AppSettings, includeBodies: Bool, maxBodyBytes: Int) -> ForeignScanResult {
        var result = ForeignScanResult()
        if settings.scanCodex {
            let loaded = loadCodex(home: settings.codexHomeURL)
            result.sessions.append(contentsOf: loaded.sessions)
            result.errors.append(contentsOf: loaded.errors)
        }
        if settings.scanGrok {
            let loaded = loadGrok(home: settings.grokHomeURL)
            result.sessions.append(contentsOf: loaded.sessions)
            result.errors.append(contentsOf: loaded.errors)
        }
        if settings.scanOpenCode {
            let loaded = OpenCodeReader.sessions(
                database: settings.openCodeDatabaseURL,
                includeBodies: includeBodies,
                maxBodyBytes: maxBodyBytes
            )
            result.sessions.append(contentsOf: loaded.sessions)
            result.bodies.merge(loaded.bodies) { _, new in new }
            result.errors.append(contentsOf: loaded.errors)
        }
        return result
    }

    // MARK: - Codex

    private static func loadCodex(home: URL) -> (sessions: [SessionRecord], errors: [String]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: home.path) else { return ([], []) }
        var byID: [String: SessionRecord] = [:]
        var errors: [String] = []
        var notedMissingZstd = false
        let roots = [
            home.appendingPathComponent("archived_sessions", isDirectory: true),
            home.appendingPathComponent("sessions", isDirectory: true)
        ]
        for root in roots where fm.fileExists(atPath: root.path) {
            let archived = root.lastPathComponent == "archived_sessions"
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") else { continue }
                let isCompressed = name.hasSuffix(".zst")
                if isCompressed && BinaryLocator.zstd == nil {
                    if !notedMissingZstd {
                        errors.append("未找到 zstd，压缩的 Codex rollout 只显示文件名信息")
                        notedMissingZstd = true
                    }
                }
                let record = codexRecord(url: url, archived: archived, compressedWithoutZstd: isCompressed && BinaryLocator.zstd == nil)
                merge(record, into: &byID)
            }
        }
        return (Array(byID.values), errors)
    }

    private static func codexRecord(url: URL, archived: Bool, compressedWithoutZstd: Bool) -> SessionRecord {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = attrs?[.modificationDate] as? Date
        let filenameID = TranscriptText.lastUUID(in: url.lastPathComponent)
        let inspection = compressedWithoutZstd
            ? TranscriptText.CodexInspection()
            : TranscriptText.inspectCodex(url: url, maxBytes: 1024 * 1024)
        let nativeID = inspection.nativeID ?? filenameID ?? url.lastPathComponent
        let cwd = inspection.cwd
        let title = inspection.title ?? ""
        return SessionRecord(
            id: SessionProvider.codex.storageID(nativeID),
            provider: .codex,
            source: .external,
            title: title,
            cwd: cwd,
            projectName: SessionScanner.projectName(from: cwd),
            model: inspection.model,
            effort: inspection.effort,
            createdAt: inspection.createdAt ?? TranscriptText.codexFilenameDate(url.lastPathComponent),
            lastActivityAt: mtime ?? inspection.createdAt,
            byteSize: size,
            messageCount: inspection.messageCount,
            completedTurns: nil,
            isArchived: archived,
            isFavorite: false,
            tags: [],
            gitBranch: nil,
            desktopSessionId: nil,
            cliSessionId: nativeID,
            metaURL: nil,
            transcriptURL: url,
            parseError: compressedWithoutZstd ? "未安装 zstd，尚未读取正文" : nil,
            titleSource: inspection.title == nil ? "filename" : "rollout",
            containerURL: nil
        )
    }

    // MARK: - Grok

    private static func loadGrok(home: URL) -> (sessions: [SessionRecord], errors: [String]) {
        let fm = FileManager.default
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return ([], []) }
        guard let projects = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        var sessions: [SessionRecord] = []
        var errors: [String] = []
        for project in projects {
            guard isDirectory(project) else { continue }
            guard let children = try? fm.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for sessionDir in children where isDirectory(sessionDir) {
                let summaryURL = sessionDir.appendingPathComponent("summary.json")
                guard fm.fileExists(atPath: summaryURL.path) else { continue }
                do {
                    sessions.append(try grokRecord(summaryURL: summaryURL, sessionDir: sessionDir, encodedCwd: project.lastPathComponent))
                } catch {
                    errors.append("Grok 会话解析失败 \(sessionDir.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return (sessions, errors)
    }

    private static func grokRecord(summaryURL: URL, sessionDir: URL, encodedCwd: String) throws -> SessionRecord {
        let data = try Data(contentsOf: summaryURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let info = object["info"] as? [String: Any] ?? [:]
        let nativeID = (info["id"] as? String) ?? sessionDir.lastPathComponent
        let decodedCwd = encodedCwd.removingPercentEncoding
        let cwd = (info["cwd"] as? String) ?? decodedCwd
        var title = (object["generated_title"] as? String) ?? ""
        let chatURL = sessionDir.appendingPathComponent("chat_history.jsonl")
        let transcript = FileManager.default.fileExists(atPath: chatURL.path) ? chatURL : nil
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let transcript {
            let firstUser = TranscriptText.turns(
                for: placeholder(provider: .grok, nativeID: nativeID, transcript: transcript),
                maxBytes: 256 * 1024
            ).first { $0.role == "user" }
            if let firstUser { title = TranscriptText.summarize(firstUser.text) }
        }
        let messageCount = (object["num_chat_messages"] as? Int)
            ?? (object["num_chat_messages"] as? NSNumber)?.intValue
        return SessionRecord(
            id: SessionProvider.grok.storageID(nativeID),
            provider: .grok,
            source: .external,
            title: title,
            cwd: cwd,
            projectName: SessionScanner.projectName(from: cwd),
            model: object["current_model_id"] as? String,
            effort: object["reasoning_effort"] as? String,
            createdAt: SessionScanner.parseTimestamp(object["created_at"]),
            lastActivityAt: SessionScanner.parseTimestamp(object["last_active_at"])
                ?? SessionScanner.parseTimestamp(object["updated_at"]),
            byteSize: directoryByteSize(sessionDir),
            messageCount: messageCount,
            completedTurns: nil,
            isArchived: false,
            isFavorite: false,
            tags: [],
            gitBranch: object["head_branch"] as? String,
            desktopSessionId: nil,
            cliSessionId: nativeID,
            metaURL: summaryURL,
            transcriptURL: transcript,
            parseError: nil,
            titleSource: (object["generated_title"] as? String)?.isEmpty == false ? "summary" : "chat",
            containerURL: nil
        )
    }

    // MARK: - Helpers

    private static func merge(_ record: SessionRecord, into byID: inout [String: SessionRecord]) {
        guard let existing = byID[record.id] else {
            byID[record.id] = record
            return
        }
        let existingDate = existing.lastActivityAt ?? .distantPast
        let newDate = record.lastActivityAt ?? .distantPast
        if existing.isArchived && !record.isArchived {
            byID[record.id] = record
        } else if existing.isArchived == record.isArchived && newDate > existingDate {
            byID[record.id] = record
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func directoryByteSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    private static func placeholder(provider: SessionProvider, nativeID: String, transcript: URL) -> SessionRecord {
        SessionRecord(
            id: provider.storageID(nativeID),
            provider: provider,
            source: .external,
            title: "",
            cwd: nil,
            projectName: nil,
            model: nil,
            effort: nil,
            createdAt: nil,
            lastActivityAt: nil,
            byteSize: 0,
            messageCount: nil,
            completedTurns: nil,
            isArchived: false,
            isFavorite: false,
            tags: [],
            gitBranch: nil,
            desktopSessionId: nil,
            cliSessionId: nativeID,
            metaURL: nil,
            transcriptURL: transcript,
            parseError: nil,
            titleSource: nil,
            containerURL: nil
        )
    }
}

enum OpenCodeReader {
    static func sessions(
        database: URL,
        includeBodies: Bool,
        maxBodyBytes: Int
    ) -> (sessions: [SessionRecord], bodies: [String: String], errors: [String]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: database.path) else { return ([], [:], []) }
        guard let db = ReadOnlySQLite(path: database.path) else {
            return ([], [:], ["无法只读打开 OpenCode 数据库: \(database.path)"])
        }
        let sql = """
        SELECT s.id, s.title, s.directory, s.model, s.time_created, s.time_updated,
               s.time_archived, p.name, p.worktree
        FROM session s
        LEFT JOIN project p ON p.id = s.project_id
        """
        guard let rows = db.query(sql) else {
            return ([], [:], ["OpenCode session 表无法读取"])
        }
        let counts = db.groupedInt64("SELECT session_id, COUNT(*), COALESCE(SUM(LENGTH(data)), 0) FROM message GROUP BY session_id")
        let partSizes = db.groupedInt64("SELECT session_id, 0, COALESCE(SUM(LENGTH(data)), 0) FROM part GROUP BY session_id")

        var sessions: [SessionRecord] = []
        var bodies: [String: String] = [:]
        for row in rows {
            guard let nativeID = row.string(0), !nativeID.isEmpty else { continue }
            let cwd = row.string(2) ?? row.string(8)
            let archivedAt = row.int64(6)
            let messageStats = counts[nativeID]
            let partSize = partSizes[nativeID]?.size ?? 0
            let record = SessionRecord(
                id: SessionProvider.opencode.storageID(nativeID),
                provider: .opencode,
                source: .external,
                title: row.string(1) ?? "",
                cwd: cwd,
                projectName: row.string(7) ?? SessionScanner.projectName(from: cwd),
                model: modelLabel(row.string(3)),
                effort: nil,
                createdAt: SessionScanner.millisDate(row.int64(4)),
                lastActivityAt: SessionScanner.millisDate(row.int64(5)) ?? SessionScanner.millisDate(row.int64(4)),
                byteSize: (messageStats?.size ?? 0) + partSize,
                messageCount: messageStats.map { Int($0.count) },
                completedTurns: nil,
                isArchived: archivedAt != nil && archivedAt != 0,
                isFavorite: false,
                tags: [],
                gitBranch: nil,
                desktopSessionId: nil,
                cliSessionId: nativeID,
                metaURL: nil,
                transcriptURL: nil,
                parseError: nil,
                titleSource: (row.string(1)?.isEmpty == false) ? "session" : nil,
                containerURL: database
            )
            sessions.append(record)
            if includeBodies {
                let text = turns(database: database, sessionID: nativeID, maxCharacters: maxBodyBytes, connection: db)
                    .map { $0.text.replacingOccurrences(of: "\n", with: " ") }
                    .joined(separator: "\n")
                if !text.isEmpty { bodies[record.id] = text }
            }
        }
        return (sessions, bodies, [])
    }

    static func turns(database: URL, sessionID: String, maxCharacters: Int) -> [TranscriptTurn] {
        guard let db = ReadOnlySQLite(path: database.path) else { return [] }
        return turns(database: database, sessionID: sessionID, maxCharacters: maxCharacters, connection: db)
    }

    private static func turns(
        database: URL,
        sessionID: String,
        maxCharacters: Int,
        connection: ReadOnlySQLite
    ) -> [TranscriptTurn] {
        let quoted = sessionID.replacingOccurrences(of: "'", with: "''")
        guard let messages = connection.query("""
        SELECT id, data FROM message
        WHERE session_id = '\(quoted)'
        ORDER BY time_created ASC
        """) else { return [] }
        guard let parts = connection.query("""
        SELECT message_id, data FROM part
        WHERE session_id = '\(quoted)'
        ORDER BY time_created ASC
        """) else { return [] }

        var textByMessage: [String: [String]] = [:]
        for part in parts {
            guard let messageID = part.string(0), let raw = part.string(1),
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["type"] as? String) == "text",
                  let text = object["text"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            textByMessage[messageID, default: []].append(trimmed)
        }

        var turns: [TranscriptTurn] = []
        var used = 0
        for message in messages {
            if used >= maxCharacters { break }
            guard let messageID = message.string(0), let raw = message.string(1),
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = object["role"] as? String,
                  role == "user" || role == "assistant" else { continue }
            let text = textByMessage[messageID, default: []].joined(separator: "\n")
            if text.isEmpty { continue }
            turns.append(TranscriptTurn(role: role, text: text, timestamp: nil))
            used += text.utf8.count
        }
        return turns
    }

    private static func modelLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return raw
        }
        let id = object["id"] as? String
        let provider = object["providerID"] as? String
        switch (provider, id) {
        case let (provider?, id?):
            return "\(provider)/\(id)"
        case let (provider?, nil):
            return provider
        case let (nil, id?):
            return id
        default:
            return raw
        }
    }
}

private struct GroupedStat {
    var count: Int64
    var size: Int64
}

private final class ReadOnlySQLite {
    private var db: OpaquePointer?

    init?(path: String) {
        var uri = URLComponents()
        uri.scheme = "file"
        uri.path = path
        uri.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uriString = uri.string else { return nil }
        if sqlite3_open_v2(uriString, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
            if let db { sqlite3_close(db) }
            self.db = nil
            return nil
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func query(_ sql: String) -> [SQLiteRow]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [SQLiteRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(SQLiteRow(statement: statement))
        }
        return rows
    }

    func groupedInt64(_ sql: String) -> [String: GroupedStat] {
        guard let rows = query(sql) else { return [:] }
        var result: [String: GroupedStat] = [:]
        for row in rows {
            guard let id = row.string(0) else { continue }
            result[id] = GroupedStat(count: row.int64(1) ?? 0, size: row.int64(2) ?? 0)
        }
        return result
    }
}

private struct SQLiteRow {
    var values: [SQLiteValue]

    init(statement: OpaquePointer?) {
        let count = Int(sqlite3_column_count(statement))
        var values: [SQLiteValue] = []
        for index in 0..<count {
            let i = Int32(index)
            switch sqlite3_column_type(statement, i) {
            case SQLITE_NULL:
                values.append(.null)
            case SQLITE_INTEGER:
                values.append(.int(sqlite3_column_int64(statement, i)))
            case SQLITE_TEXT:
                if let cString = sqlite3_column_text(statement, i) {
                    values.append(.text(String(cString: cString)))
                } else {
                    values.append(.null)
                }
            default:
                if let cString = sqlite3_column_text(statement, i) {
                    values.append(.text(String(cString: cString)))
                } else {
                    values.append(.null)
                }
            }
        }
        self.values = values
    }

    func string(_ index: Int) -> String? {
        guard values.indices.contains(index) else { return nil }
        switch values[index] {
        case .text(let text):
            return text.isEmpty ? nil : text
        case .int(let number):
            return String(number)
        case .null:
            return nil
        }
    }

    func int64(_ index: Int) -> Int64? {
        guard values.indices.contains(index) else { return nil }
        switch values[index] {
        case .int(let number):
            return number
        case .text(let text):
            return Int64(text)
        case .null:
            return nil
        }
    }
}

private enum SQLiteValue {
    case null
    case int(Int64)
    case text(String)
}

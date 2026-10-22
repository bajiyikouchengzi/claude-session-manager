import Foundation

struct TranscriptTurn: Equatable, Sendable {
    var role: String
    var text: String
    var timestamp: String?
}

enum BinaryLocator {
    static let zstd: URL? = {
        ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }()
}

/// Read conversation text from Claude, Codex, Grok, and OpenCode stores.
enum TranscriptText {
    static func turns(for session: SessionRecord, maxBytes: Int) -> [TranscriptTurn] {
        switch session.provider {
        case .claude:
            return claudeTurns(url: session.transcriptURL, maxBytes: maxBytes)
        case .codex:
            return codexTurns(url: session.transcriptURL, maxBytes: maxBytes)
        case .grok:
            return grokTurns(url: session.transcriptURL, maxBytes: maxBytes)
        case .opencode:
            guard let database = session.containerURL else { return [] }
            return OpenCodeReader.turns(
                database: database,
                sessionID: session.nativeSessionID,
                maxCharacters: maxBytes
            )
        }
    }

    static func searchableBody(for session: SessionRecord, maxBytes: Int) -> String {
        turns(for: session, maxBytes: maxBytes)
            .map { turn in
                turn.text
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func previewTurns(for session: SessionRecord, limit: Int) -> [TranscriptTurn] {
        var out: [TranscriptTurn] = []
        for turn in turns(for: session, maxBytes: 1024 * 1024) {
            guard turn.role == "user" || turn.role == "assistant" else { continue }
            var text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.hasPrefix("Base directory for this skill") { continue }
            if text.count > 600 {
                text = String(text.prefix(600)) + "…"
            }
            out.append(TranscriptTurn(role: turn.role, text: text, timestamp: turn.timestamp))
            if out.count >= limit { break }
        }
        return out
    }

    static func summarize(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 80 { return oneLine }
        return String(oneLine.prefix(80)) + "…"
    }

    // MARK: - Codex header

    struct CodexInspection {
        var nativeID: String?
        var cwd: String?
        var model: String?
        var effort: String?
        var createdAt: Date?
        var title: String?
        var messageCount: Int = 0
    }

    static func inspectCodex(url: URL, maxBytes: Int) -> CodexInspection {
        guard let text = readTextPrefix(url: url, maxBytes: maxBytes) else { return CodexInspection() }
        var info = CodexInspection()
        for object in jsonObjects(in: text) {
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any] ?? object
            if type == "session_meta" {
                info.nativeID = (payload["session_id"] as? String) ?? (payload["id"] as? String) ?? info.nativeID
                if info.cwd == nil { info.cwd = payload["cwd"] as? String }
                if info.createdAt == nil { info.createdAt = SessionScanner.parseTimestamp(payload["timestamp"]) }
            } else if type == "turn_context" {
                if let model = payload["model"] as? String, !model.isEmpty { info.model = model }
                if let effort = payload["effort"] as? String, !effort.isEmpty { info.effort = effort }
                if info.cwd == nil { info.cwd = payload["cwd"] as? String }
            }
            if let turn = codexTurn(object) {
                info.messageCount += 1
                if info.title == nil, turn.role == "user" {
                    info.title = summarize(turn.text)
                }
            }
        }
        return info
    }

    static func lastUUID(in name: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        ) else { return nil }
        let ns = name as NSString
        let matches = regex.matches(in: name, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        return ns.substring(with: last.range)
    }

    static func codexFilenameDate(_ name: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}"#) else { return nil }
        let ns = name as NSString
        guard let match = regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let stamp = ns.substring(with: match.range)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.date(from: stamp)
    }

    // MARK: - Readers

    static func readTextPrefix(url: URL, maxBytes: Int) -> String? {
        let data: Data?
        if url.path.hasSuffix(".zst") {
            data = decompressPrefix(url: url, maxBytes: maxBytes)
        } else {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            data = handle.readData(ofLength: max(0, maxBytes))
        }
        guard let data, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func claudeTurns(url: URL?, maxBytes: Int) -> [TranscriptTurn] {
        guard let url, let text = readTextPrefix(url: url, maxBytes: maxBytes) else { return [] }
        var turns: [TranscriptTurn] = []
        for object in jsonObjects(in: text) {
            guard let type = object["type"] as? String else { continue }
            if type == "custom-title", let title = object["customTitle"] as? String, !title.isEmpty {
                turns.append(TranscriptTurn(role: "title", text: title, timestamp: timestampString(object["timestamp"])))
                continue
            }
            guard type == "user" || type == "assistant" else { continue }
            let content = messageText(object)
            guard let content, !content.isEmpty else { continue }
            turns.append(TranscriptTurn(role: type, text: content, timestamp: timestampString(object["timestamp"])))
        }
        return turns
    }

    private static func codexTurns(url: URL?, maxBytes: Int) -> [TranscriptTurn] {
        guard let url, let text = readTextPrefix(url: url, maxBytes: maxBytes) else { return [] }
        return jsonObjects(in: text).compactMap(codexTurn)
    }

    private static func grokTurns(url: URL?, maxBytes: Int) -> [TranscriptTurn] {
        guard let url, let text = readTextPrefix(url: url, maxBytes: maxBytes) else { return [] }
        return jsonObjects(in: text).compactMap(grokTurn)
    }

    private static func codexTurn(_ object: [String: Any]) -> TranscriptTurn? {
        guard (object["type"] as? String) == "response_item" else { return nil }
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        guard (payload["type"] as? String) == "message" else { return nil }
        guard let role = payload["role"] as? String, role == "user" || role == "assistant" else { return nil }
        guard let text = blockText(payload["content"], allowed: ["input_text", "output_text", "text"]) else { return nil }
        return TranscriptTurn(role: role, text: text, timestamp: timestampString(object["timestamp"]))
    }

    private static func grokTurn(_ object: [String: Any]) -> TranscriptTurn? {
        guard let role = object["type"] as? String, role == "user" || role == "assistant" else { return nil }
        guard let text = plainOrBlockText(object["content"]) else { return nil }
        return TranscriptTurn(role: role, text: text, timestamp: nil)
    }

    static func jsonObjects(in text: String) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd]
            if !line.isEmpty,
               let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result.append(object)
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return result
    }

    private static func messageText(_ object: [String: Any]) -> String? {
        if let message = object["message"] as? [String: Any] {
            return plainOrBlockText(message["content"])
        }
        return plainOrBlockText(object["content"]) ?? (object["text"] as? String)
    }

    private static func plainOrBlockText(_ content: Any?) -> String? {
        blockText(content, allowed: ["text"])
    }

    private static func blockText(_ content: Any?, allowed: Set<String>) -> String? {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = content as? [Any] else { return nil }
        var parts: [String] = []
        for block in blocks {
            guard let dict = block as? [String: Any] else { continue }
            guard let type = dict["type"] as? String, allowed.contains(type) else { continue }
            guard let text = dict["text"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private static func timestampString(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func decompressPrefix(url: URL, maxBytes: Int) -> Data? {
        guard let zstd = BinaryLocator.zstd else { return nil }
        let process = Process()
        process.executableURL = zstd
        process.arguments = ["-dc", "-q", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readData(ofLength: max(0, maxBytes))
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        return data.isEmpty ? nil : data
    }
}

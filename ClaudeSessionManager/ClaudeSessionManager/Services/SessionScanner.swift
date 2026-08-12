import Foundation

struct ScanProgress: Sendable {
    var phase: String
    var current: Int
    var total: Int
}

struct ScanResult: Sendable {
    var sessions: [SessionRecord]
    var bodyByID: [String: String]
    var errors: [String]
}

enum SessionScanner {
    static func scan(
        settings: AppSettings,
        includeBodies: Bool,
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) -> ScanResult {
        var errors: [String] = []
        let fm = FileManager.default

        progress?(ScanProgress(phase: "扫描 Desktop 元数据", current: 0, total: 0))
        var metas: [DesktopMeta] = []
        for dir in settings.codeSessionsDirs {
            metas.append(contentsOf: loadDesktopMetas(root: dir, errors: &errors))
        }

        progress?(ScanProgress(phase: "扫描 Code transcripts", current: 0, total: 0))
        let transcripts = loadTranscripts(root: settings.projectsDir, errors: &errors)

        progress?(ScanProgress(phase: "合并会话", current: 0, total: metas.count + transcripts.count))
        var byCLI: [String: SessionRecord] = [:]
        var orphans: [SessionRecord] = []

        // Seed from Desktop meta (preferred for title/archive/model).
        for meta in metas {
            let cli = meta.cliSessionId ?? meta.desktopSessionId.replacingOccurrences(of: "local_", with: "")
            let record = SessionRecord(
                id: cli,
                source: .desktopCodeMeta,
                title: meta.title,
                cwd: meta.cwd,
                projectName: projectName(from: meta.cwd),
                model: meta.model,
                effort: meta.effort,
                createdAt: meta.createdAt,
                lastActivityAt: meta.lastActivityAt,
                byteSize: 0,
                messageCount: nil,
                completedTurns: meta.completedTurns,
                isArchived: meta.isArchived,
                isFavorite: false,
                tags: [],
                gitBranch: nil,
                desktopSessionId: meta.desktopSessionId,
                cliSessionId: cli,
                metaURL: meta.fileURL,
                transcriptURL: nil,
                parseError: meta.parseError,
                titleSource: meta.titleSource
            )
            byCLI[cli] = record
            _ = record
        }

        // Merge transcripts.
        for t in transcripts {
            let id = t.sessionId
            if var existing = byCLI[id] {
                existing.source = .merged
                existing.transcriptURL = t.fileURL
                existing.byteSize += t.byteSize
                existing.messageCount = t.messageCount
                if existing.title.isEmpty { existing.title = t.inferredTitle ?? "" }
                if existing.cwd == nil { existing.cwd = t.cwd; existing.projectName = projectName(from: t.cwd) }
                if existing.gitBranch == nil { existing.gitBranch = t.gitBranch }
                if let ta = t.lastActivityAt {
                    if existing.lastActivityAt == nil || ta > existing.lastActivityAt! {
                        existing.lastActivityAt = ta
                    }
                }
                if existing.createdAt == nil { existing.createdAt = t.createdAt }
                if existing.model == nil { existing.model = t.model }
                byCLI[id] = existing
            } else {
                let record = SessionRecord(
                    id: id,
                    source: .codeJsonl,
                    title: t.inferredTitle ?? "",
                    cwd: t.cwd,
                    projectName: projectName(from: t.cwd),
                    model: t.model,
                    effort: nil,
                    createdAt: t.createdAt,
                    lastActivityAt: t.lastActivityAt,
                    byteSize: t.byteSize,
                    messageCount: t.messageCount,
                    completedTurns: nil,
                    isArchived: false,
                    isFavorite: false,
                    tags: [],
                    gitBranch: t.gitBranch,
                    desktopSessionId: nil,
                    cliSessionId: id,
                    metaURL: nil,
                    transcriptURL: t.fileURL,
                    parseError: t.parseError,
                    titleSource: t.inferredTitle == nil ? nil : "jsonl"
                )
                orphans.append(record)
            }
        }

        // Attach missing transcript paths by conventional location when cwd known.
        for (id, var rec) in byCLI {
            if rec.transcriptURL == nil, let cwd = rec.cwd {
                let slug = projectSlug(for: cwd)
                let candidate = settings.projectsDir
                    .appendingPathComponent(slug, isDirectory: true)
                    .appendingPathComponent("\(id).jsonl")
                if fm.fileExists(atPath: candidate.path) {
                    if let attrs = try? fm.attributesOfItem(atPath: candidate.path),
                       let size = attrs[.size] as? NSNumber {
                        rec.transcriptURL = candidate
                        rec.byteSize += size.int64Value
                        rec.source = .merged
                        byCLI[id] = rec
                    }
                }
            }
        }

        var sessions = Array(byCLI.values) + orphans
        sessions.sort { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }

        var bodyByID: [String: String] = [:]
        if includeBodies {
            let total = sessions.count
            for (idx, s) in sessions.enumerated() {
                progress?(ScanProgress(phase: "建立全文索引", current: idx + 1, total: total))
                guard let url = s.transcriptURL else { continue }
                bodyByID[s.id] = extractSearchableBody(
                    from: url,
                    maxBytes: settings.fullTextMaxBytesPerSession
                )
            }
        }

        return ScanResult(sessions: sessions, bodyByID: bodyByID, errors: errors)
    }

    // MARK: - Desktop meta

    private struct DesktopMeta {
        var desktopSessionId: String
        var cliSessionId: String?
        var title: String
        var titleSource: String?
        var cwd: String?
        var model: String?
        var effort: String?
        var createdAt: Date?
        var lastActivityAt: Date?
        var isArchived: Bool
        var completedTurns: Int?
        var fileURL: URL
        var parseError: String?
    }

    private static func loadDesktopMetas(root: URL, errors: inout [String]) -> [DesktopMeta] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            errors.append("未找到 Desktop 会话目录: \(root.path)")
            return []
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [DesktopMeta] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            do {
                let data = try Data(contentsOf: url)
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let desktopId = (obj["sessionId"] as? String) ?? name.replacingOccurrences(of: ".json", with: "")
                let cli = obj["cliSessionId"] as? String
                let title = (obj["title"] as? String) ?? ""
                let meta = DesktopMeta(
                    desktopSessionId: desktopId,
                    cliSessionId: cli,
                    title: title,
                    titleSource: obj["titleSource"] as? String,
                    cwd: obj["cwd"] as? String ?? obj["originCwd"] as? String,
                    model: obj["model"] as? String,
                    effort: obj["effort"] as? String,
                    createdAt: millisDate(obj["createdAt"]),
                    lastActivityAt: millisDate(obj["lastActivityAt"]) ?? millisDate(obj["lastFocusedAt"]),
                    isArchived: (obj["isArchived"] as? Bool) ?? false,
                    completedTurns: obj["completedTurns"] as? Int,
                    fileURL: url,
                    parseError: nil
                )
                result.append(meta)
            } catch {
                errors.append("解析失败 \(url.lastPathComponent): \(error.localizedDescription)")
                result.append(DesktopMeta(
                    desktopSessionId: name,
                    cliSessionId: nil,
                    title: name,
                    titleSource: nil,
                    cwd: nil,
                    model: nil,
                    effort: nil,
                    createdAt: nil,
                    lastActivityAt: nil,
                    isArchived: false,
                    completedTurns: nil,
                    fileURL: url,
                    parseError: error.localizedDescription
                ))
            }
        }
        return result
    }

    // MARK: - Transcripts

    private struct TranscriptInfo {
        var sessionId: String
        var fileURL: URL
        var byteSize: Int64
        var cwd: String?
        var gitBranch: String?
        var model: String?
        var createdAt: Date?
        var lastActivityAt: Date?
        var messageCount: Int
        var inferredTitle: String?
        var parseError: String?
    }

    private static func loadTranscripts(root: URL, errors: inout [String]) -> [TranscriptInfo] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            errors.append("未找到 Claude Code projects 目录: \(root.path)")
            return []
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [TranscriptInfo] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let sessionId = url.deletingPathExtension().lastPathComponent
            // Skip non-uuid-ish names lightly; still include.
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = attrs?[.modificationDate] as? Date

            var info = TranscriptInfo(
                sessionId: sessionId,
                fileURL: url,
                byteSize: size,
                cwd: nil,
                gitBranch: nil,
                model: nil,
                createdAt: nil,
                lastActivityAt: mtime,
                messageCount: 0,
                inferredTitle: nil,
                parseError: nil
            )
            parseTranscriptHeader(url: url, into: &info)
            result.append(info)
        }
        return result
    }

    /// Read a limited prefix of the jsonl for metadata + first user text + customTitle.
    private static func parseTranscriptHeader(url: URL, into info: inout TranscriptInfo) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            info.parseError = "无法打开文件"
            return
        }
        defer { try? handle.close() }

        let maxBytes = 512 * 1024
        let data = handle.readData(ofLength: maxBytes)
        guard let text = String(data: data, encoding: .utf8) else { return }

        var userCount = 0
        var assistantCount = 0
        var firstUser: String?
        var customTitle: String?
        var firstTs: Date?
        var lastTs: Date?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            if let ts = parseTimestamp(obj["timestamp"]) {
                if firstTs == nil { firstTs = ts }
                lastTs = ts
            }
            if info.cwd == nil, let cwd = obj["cwd"] as? String { info.cwd = cwd }
            if info.gitBranch == nil, let b = obj["gitBranch"] as? String { info.gitBranch = b }
            if let t = obj["customTitle"] as? String, !t.isEmpty { customTitle = t }
            if let type = obj["type"] as? String {
                if type == "user" {
                    userCount += 1
                    if firstUser == nil {
                        firstUser = extractUserText(obj)
                    }
                } else if type == "assistant" {
                    assistantCount += 1
                    if info.model == nil {
                        if let msg = obj["message"] as? [String: Any], let model = msg["model"] as? String {
                            info.model = model
                        }
                    }
                } else if type == "custom-title", let t = obj["customTitle"] as? String {
                    customTitle = t
                }
            }
        }
        info.messageCount = userCount + assistantCount
        info.createdAt = firstTs
        if let lastTs {
            info.lastActivityAt = max(info.lastActivityAt ?? .distantPast, lastTs)
        }
        if let customTitle, !customTitle.isEmpty {
            info.inferredTitle = customTitle
        } else if let firstUser {
            info.inferredTitle = summarize(firstUser)
        }
    }

    static func extractSearchableBody(from url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: max(0, maxBytes))
        guard let text = String(data: data, encoding: .utf8) else { return "" }

        var parts: [String] = []
        var budget = maxBytes
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let type = obj["type"] as? String
            if type == "user" || type == "assistant" {
                if let snippet = extractUserText(obj) ?? extractAssistantText(obj) {
                    let clean = snippet
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if clean.isEmpty { continue }
                    parts.append(clean)
                    budget -= clean.utf8.count
                    if budget <= 0 { break }
                }
            } else if type == "custom-title", let t = obj["customTitle"] as? String {
                parts.append(t)
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func extractUserText(_ obj: [String: Any]) -> String? {
        if let message = obj["message"] as? [String: Any] {
            return contentToString(message["content"])
        }
        return contentToString(obj["content"]) ?? obj["text"] as? String
    }

    private static func extractAssistantText(_ obj: [String: Any]) -> String? {
        if let message = obj["message"] as? [String: Any] {
            return contentToString(message["content"])
        }
        return contentToString(obj["content"])
    }

    private static func contentToString(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let arr = content as? [Any] {
            var parts: [String] = []
            for item in arr {
                guard let dict = item as? [String: Any] else { continue }
                let type = dict["type"] as? String
                if type == "text", let t = dict["text"] as? String {
                    parts.append(t)
                }
            }
            let joined = parts.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func summarize(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 80 { return oneLine }
        let idx = oneLine.index(oneLine.startIndex, offsetBy: 80)
        return String(oneLine[..<idx]) + "…"
    }

    private static func millisDate(_ any: Any?) -> Date? {
        if let n = any as? Double {
            // Heuristic: ms vs s
            if n > 10_000_000_000 { return Date(timeIntervalSince1970: n / 1000) }
            return Date(timeIntervalSince1970: n)
        }
        if let n = any as? Int {
            let d = Double(n)
            if d > 10_000_000_000 { return Date(timeIntervalSince1970: d / 1000) }
            return Date(timeIntervalSince1970: d)
        }
        if let n = any as? NSNumber {
            return millisDate(n.doubleValue)
        }
        return nil
    }

    private static func parseTimestamp(_ any: Any?) -> Date? {
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        return millisDate(any)
    }

    static func projectName(from cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func projectSlug(for cwd: String) -> String {
        // Claude Code replaces non-alphanumeric with '-'
        let mapped = cwd.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            return "-"
        }
        return String(mapped)
    }
}

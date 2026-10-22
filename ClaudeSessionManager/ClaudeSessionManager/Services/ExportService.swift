import Foundation
import UniformTypeIdentifiers
import AppKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case json
    case zipBundle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .json: return "JSON (.json)"
        case .zipBundle: return "打包 Zip (meta+transcript)"
        }
    }

    var allowedContentType: UTType {
        switch self {
        case .markdown: return .plainText
        case .json: return .json
        case .zipBundle: return .zip
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .json: return "json"
        case .zipBundle: return "zip"
        }
    }
}

enum ExportService {
    static func export(_ session: SessionRecord, format: ExportFormat, to directory: URL) throws -> URL {
        let safeTitle = sanitizeFilename(session.displayTitle)
        let base = "\(safeTitle)-\(sanitizeFilename(String(session.nativeSessionID.prefix(8))))"
        switch format {
        case .markdown:
            let url = directory.appendingPathComponent("\(base).md")
            let md = renderMarkdown(session)
            try md.write(to: url, atomically: true, encoding: .utf8)
            AuditLog.write("export.md id=\(session.id) path=\(url.path)")
            return url
        case .json:
            let url = directory.appendingPathComponent("\(base).json")
            let payload = exportJSONObject(session)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            AuditLog.write("export.json id=\(session.id) path=\(url.path)")
            return url
        case .zipBundle:
            let url = directory.appendingPathComponent("\(base).zip")
            try writeZipBundle(session, to: url)
            AuditLog.write("export.zip id=\(session.id) path=\(url.path)")
            return url
        }
    }

    static func exportMany(_ sessions: [SessionRecord], format: ExportFormat, to directory: URL) throws -> [URL] {
        var urls: [URL] = []
        if format == .zipBundle && sessions.count > 1 {
            // One zip containing all.
            let url = directory.appendingPathComponent("sessions-\(dateStamp()).zip")
            try writeMultiZip(sessions, to: url)
            return [url]
        }
        for s in sessions {
            urls.append(try export(s, format: format, to: directory))
        }
        return urls
    }

    // MARK: - Renderers

    static func renderMarkdown(_ session: SessionRecord) -> String {
        var lines: [String] = []
        lines.append("# \(session.displayTitle)")
        lines.append("")
        lines.append("- ID: `\(session.id)`")
        if let cwd = session.cwd { lines.append("- Project: `\(cwd)`") }
        if let model = session.model { lines.append("- Model: `\(model)`") }
        if let branch = session.gitBranch { lines.append("- Branch: `\(branch)`") }
        if let created = session.createdAt { lines.append("- Created: \(formatDate(created))") }
        if let activity = session.lastActivityAt { lines.append("- Last activity: \(formatDate(activity))") }
        lines.append("- Size: \(session.formattedSize)")
        lines.append("- Source: \(session.provider.label) / \(session.originLabel)")
        lines.append("")
        lines.append("---")
        lines.append("")
        let turns = TranscriptText.turns(for: session, maxBytes: 50 * 1024 * 1024)
            .filter { $0.role == "user" || $0.role == "assistant" }
        if turns.isEmpty {
            lines.append("_无 transcript 或无法读取。_")
            return lines.joined(separator: "\n")
        }
        for turn in turns {
            lines.append("## \(turn.role == "user" ? "User" : "Assistant")")
            lines.append("")
            lines.append(turn.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func exportJSONObject(_ session: SessionRecord) -> [String: Any] {
        var meta: [String: Any] = [
            "id": session.id,
            "title": session.displayTitle,
            "source": session.source.rawValue,
            "provider": session.provider.rawValue,
            "byteSize": session.byteSize,
            "isArchived": session.isArchived
        ]
        if let cwd = session.cwd { meta["cwd"] = cwd }
        if let model = session.model { meta["model"] = model }
        if let created = session.createdAt { meta["createdAt"] = ISO8601DateFormatter().string(from: created) }
        if let activity = session.lastActivityAt { meta["lastActivityAt"] = ISO8601DateFormatter().string(from: activity) }

        var messages: [[String: Any]] = []
        for turn in TranscriptText.turns(for: session, maxBytes: 50 * 1024 * 1024) where turn.role == "user" || turn.role == "assistant" {
            var row: [String: Any] = ["role": turn.role, "content": turn.text]
            if let timestamp = turn.timestamp { row["timestamp"] = timestamp }
            messages.append(row)
        }
        return ["meta": meta, "messages": messages]
    }

    private static func writeZipBundle(_ session: SessionRecord, to zipURL: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("csm-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let md = renderMarkdown(session)
        try md.write(to: tmp.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        if let meta = session.metaURL, fm.fileExists(atPath: meta.path) {
            try fm.copyItem(at: meta, to: tmp.appendingPathComponent(meta.lastPathComponent))
        }
        if let transcript = session.transcriptURL, fm.fileExists(atPath: transcript.path) {
            try fm.copyItem(at: transcript, to: tmp.appendingPathComponent(transcript.lastPathComponent))
        }
        try zipDirectory(tmp, to: zipURL)
    }

    private static func writeMultiZip(_ sessions: [SessionRecord], to zipURL: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("csm-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        for session in sessions {
            let folder = tmp.appendingPathComponent(
                sanitizeFilename(session.displayTitle) + "-" + sanitizeFilename(String(session.nativeSessionID.prefix(8))),
                isDirectory: true
            )
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let md = renderMarkdown(session)
            try md.write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            if let meta = session.metaURL, fm.fileExists(atPath: meta.path) {
                try? fm.copyItem(at: meta, to: folder.appendingPathComponent(meta.lastPathComponent))
            }
            if let transcript = session.transcriptURL, fm.fileExists(atPath: transcript.path) {
                try? fm.copyItem(at: transcript, to: folder.appendingPathComponent(transcript.lastPathComponent))
            }
        }
        try zipDirectory(tmp, to: zipURL)
    }

    /// Use /usr/bin/ditto to create zip without third-party deps.
    private static func zipDirectory(_ dir: URL, to zipURL: URL) throws {
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", dir.path, zipURL.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "zip failed"
            throw ExportError.failed(msg)
        }
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "session" }
        if trimmed.count > 60 { return String(trimmed.prefix(60)) }
        return trimmed
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

enum ExportError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .failed(let s): return s
        }
    }
}

import Foundation
import AppKit

enum MetaWriter {
    /// Update title / isArchived on Desktop local_*.json atomically when possible.
    @discardableResult
    static func updateMeta(at url: URL?, title: String? = nil, isArchived: Bool? = nil) -> Bool {
        guard let url else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let data = try Data(contentsOf: url)
            guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            if let title {
                obj["title"] = title
                obj["titleSource"] = "user"
            }
            if let isArchived {
                obj["isArchived"] = isArchived
            }
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            let tmp = url.appendingPathExtension("tmp")
            try out.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            audit("meta.update path=\(url.path) title=\(title ?? "-") archived=\(String(describing: isArchived))")
            return true
        } catch {
            audit("meta.update.fail path=\(url.path) err=\(error.localizedDescription)")
            return false
        }
    }
}

enum AuditLog {
    static func write(_ line: String) {
        audit(line)
    }
}

private func audit(_ line: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let entry = "[\(stamp)] \(line)\n"
    let url = AppPaths.auditLog
    if let data = entry.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum ResumeAction {
    static func command(for session: SessionRecord) -> String {
        let id = shellWord(session.nativeSessionID)
        let tool: String
        switch session.provider {
        case .claude:
            tool = "claude --resume \(id)"
        case .codex:
            tool = "codex resume \(id)"
        case .grok:
            tool = "grok --resume \(id)"
        case .opencode:
            tool = "opencode -s \(id)"
        }
        if let cwd = session.cwd, !cwd.isEmpty {
            let escaped = cwd.replacingOccurrences(of: "'", with: "'\\''")
            return "cd '\(escaped)' && \(tool)"
        }
        return tool
    }

    static func shellWord(_ value: String) -> String {
        if value.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func copyCommand(for session: SessionRecord) {
        let cmd = command(for: session)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        audit("resume.copy id=\(session.id)")
    }

    static func reveal(_ session: SessionRecord) {
        var urls: [URL] = []
        if let t = session.transcriptURL { urls.append(t) }
        if let m = session.metaURL { urls.append(m) }
        if let container = session.containerURL { urls.append(container) }
        if urls.isEmpty {
            if let cwd = session.cwd {
                NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        audit("reveal id=\(session.id)")
    }

    static func openInTerminal(session: SessionRecord) {
        let cmd = command(for: session)
        // Prefer open -a Terminal with a simple do script via osascript.
        let script = """
        tell application "Terminal"
          activate
          do script "\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        audit("resume.terminal id=\(session.id)")
    }
}

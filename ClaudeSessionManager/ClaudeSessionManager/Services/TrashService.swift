import Foundation

final class TrashService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "csm.trash")
    private let manifestURL: URL
    private var items: [TrashedSession] = []

    init() {
        manifestURL = AppPaths.trashDir.appendingPathComponent("manifest.json")
        load()
    }

    func list() -> [TrashedSession] {
        queue.sync { items.sorted { $0.trashedAt > $1.trashedAt } }
    }

    @discardableResult
    func moveToTrash(_ session: SessionRecord) throws -> TrashedSession {
        try queue.sync {
            let id = session.id
            let dir = AppPaths.trashDir.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            if let meta = session.metaURL, FileManager.default.fileExists(atPath: meta.path) {
                let dest = dir.appendingPathComponent("meta_\(meta.lastPathComponent)")
                try moveOrCopy(from: meta, to: dest)
            }
            if let transcript = session.transcriptURL, FileManager.default.fileExists(atPath: transcript.path) {
                let dest = dir.appendingPathComponent(transcript.lastPathComponent)
                try moveOrCopy(from: transcript, to: dest)
            }

            // Align with Desktop: drop a deleted_ marker next to sibling local_ files when possible.
            if let meta = session.metaURL {
                let markerName = "deleted_\(session.cliSessionId ?? session.id)"
                let marker = meta.deletingLastPathComponent().appendingPathComponent(markerName)
                FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: nil)
            }

            let item = TrashedSession(id: id, original: session, trashedAt: Date(), trashDirectory: dir)
            items.removeAll { $0.id == id }
            items.append(item)
            saveLocked()
            AuditLog.write("trash.add id=\(id) size=\(session.byteSize)")
            return item
        }
    }

    func restore(_ id: String) throws {
        try queue.sync {
            guard let idx = items.firstIndex(where: { $0.id == id }) else {
                throw TrashError.notFound
            }
            let item = items[idx]
            let dir = item.trashDirectory
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in contents {
                    let name = file.lastPathComponent
                    if name.hasPrefix("meta_"), let metaURL = item.original.metaURL {
                        let dest = metaURL
                        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                        try fm.copyItem(at: file, to: dest)
                        // remove deleted marker
                        let marker = dest.deletingLastPathComponent()
                            .appendingPathComponent("deleted_\(item.original.cliSessionId ?? item.original.id)")
                        try? fm.removeItem(at: marker)
                    } else if name.hasSuffix(".jsonl"), let transcript = item.original.transcriptURL {
                        if fm.fileExists(atPath: transcript.path) { try fm.removeItem(at: transcript) }
                        try fm.copyItem(at: file, to: transcript)
                    }
                }
            }
            try? fm.removeItem(at: dir)
            items.remove(at: idx)
            saveLocked()
            AuditLog.write("trash.restore id=\(id)")
        }
    }

    func purge(_ id: String) throws {
        try queue.sync {
            guard let idx = items.firstIndex(where: { $0.id == id }) else {
                throw TrashError.notFound
            }
            let item = items[idx]
            try? FileManager.default.removeItem(at: item.trashDirectory)
            items.remove(at: idx)
            saveLocked()
            AuditLog.write("trash.purge id=\(id)")
        }
    }

    func purgeExpired(retentionDays: Int) {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 3600)
            let expired = items.filter { $0.trashedAt < cutoff }
            for item in expired {
                try? FileManager.default.removeItem(at: item.trashDirectory)
            }
            items.removeAll { $0.trashedAt < cutoff }
            saveLocked()
            if !expired.isEmpty {
                AuditLog.write("trash.purgeExpired count=\(expired.count)")
            }
        }
    }

    private func moveOrCopy(from: URL, to: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) {
            try fm.removeItem(at: to)
        }
        do {
            try fm.moveItem(at: from, to: to)
        } catch {
            try fm.copyItem(at: from, to: to)
            try fm.removeItem(at: from)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([TrashedSession].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func saveLocked() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            // ignore
        }
    }
}

enum TrashError: LocalizedError {
    case notFound
    var errorDescription: String? {
        switch self {
        case .notFound: return "回收站中未找到该会话"
        }
    }
}

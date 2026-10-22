import Foundation

/// App-owned, recoverable trash with copy-verify-commit semantics.
final class TrashService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "csm.trash")
    private let root: URL
    private let manifestURL: URL
    private var items: [TrashedSession] = []

    init(root: URL = AppPaths.trashDir) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manifestURL = root.appendingPathComponent("manifest.json")
        load()
    }

    func list() -> [TrashedSession] {
        queue.sync { items.sorted { $0.trashedAt > $1.trashedAt } }
    }

    /// Copy all source files to staging, verify them, atomically commit the
    /// staging directory, then remove originals. Any failure restores originals
    /// and leaves the manifest unchanged.
    @discardableResult
    func moveToTrash(_ session: SessionRecord) throws -> TrashedSession {
        try queue.sync {
            let fm = FileManager.default
            guard session.provider.canEditSource else {
                throw TrashError.readOnlyProvider(session.provider.label)
            }
            guard !items.contains(where: { $0.id == session.id }) else {
                throw TrashError.alreadyTrashed
            }

            let sources = sourceArtifacts(for: session).filter { fm.fileExists(atPath: $0.source.path) }
            guard !sources.isEmpty else { throw TrashError.noSourceFiles }
            if let marker = deletedMarker(for: session), fm.fileExists(atPath: marker.path) {
                throw TrashError.markerAlreadyExists(marker.path)
            }

            let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            let final = root.appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
            var committedDirectory: URL?
            var removedSources: [Artifact] = []
            var createdMarker: URL?
            let oldItems = items

            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: false)
                for artifact in sources {
                    let staged = staging.appendingPathComponent(artifact.storedName)
                    try fm.copyItem(at: artifact.source, to: staged)
                    guard try filesMatch(artifact.source, staged) else {
                        throw TrashError.verificationFailed(artifact.source.path)
                    }
                }

                try fm.moveItem(at: staging, to: final)
                committedDirectory = final

                for artifact in sources {
                    let backup = final.appendingPathComponent(artifact.storedName)
                    guard try filesMatch(artifact.source, backup) else {
                        throw TrashError.sourceChanged(artifact.source.path)
                    }
                    try fm.removeItem(at: artifact.source)
                    removedSources.append(artifact)
                }

                if let marker = deletedMarker(for: session), !fm.fileExists(atPath: marker.path) {
                    guard fm.createFile(atPath: marker.path, contents: Data()) else {
                        throw TrashError.markerCreationFailed(marker.path)
                    }
                    createdMarker = marker
                }

                let item = TrashedSession(
                    id: session.id,
                    original: session,
                    trashedAt: Date(),
                    trashDirectory: final
                )
                items.append(item)
                try saveLocked()
                AuditLog.write("trash.add id=\(session.id) size=\(session.byteSize)")
                return item
            } catch {
                items = oldItems
                if let createdMarker { try? fm.removeItem(at: createdMarker) }
                if let committedDirectory {
                    var rollbackSucceeded = true
                    for artifact in removedSources where !fm.fileExists(atPath: artifact.source.path) {
                        let backup = committedDirectory.appendingPathComponent(artifact.storedName)
                        do {
                            try fm.createDirectory(
                                at: artifact.source.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try fm.copyItem(at: backup, to: artifact.source)
                        } catch {
                            rollbackSucceeded = false
                            AuditLog.write("trash.rollback.fail id=\(session.id) path=\(artifact.source.path)")
                        }
                    }
                    if rollbackSucceeded {
                        try? fm.removeItem(at: committedDirectory)
                    } else {
                        AuditLog.write("trash.rollback.backup-preserved id=\(session.id) path=\(committedDirectory.path)")
                    }
                }
                try? fm.removeItem(at: staging)
                AuditLog.write("trash.add.fail id=\(session.id) err=\(error.localizedDescription)")
                throw error
            }
        }
    }

    /// Restore only when every original destination is free. Existing files are
    /// never overwritten, because they may belong to a newly-created session.
    func restore(_ id: String) throws {
        try queue.sync {
            guard let idx = items.firstIndex(where: { $0.id == id }) else {
                throw TrashError.notFound
            }
            let fm = FileManager.default
            let item = items[idx]
            let artifacts = try restorableArtifacts(for: item)

            for artifact in artifacts where fm.fileExists(atPath: artifact.source.path) {
                throw TrashError.restoreConflict(artifact.source.path)
            }

            let marker = deletedMarker(for: item.original)
            let markerExisted = marker.map { fm.fileExists(atPath: $0.path) } ?? false
            var restored: [URL] = []
            let oldItems = items

            do {
                for artifact in artifacts {
                    try fm.createDirectory(
                        at: artifact.source.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let temporary = artifact.source.deletingLastPathComponent()
                        .appendingPathComponent(".csm-restore-\(UUID().uuidString)")
                    let backup = item.trashDirectory.appendingPathComponent(artifact.storedName)
                    try fm.copyItem(at: backup, to: temporary)
                    try fm.moveItem(at: temporary, to: artifact.source)
                    restored.append(artifact.source)
                }

                if let marker, markerExisted { try fm.removeItem(at: marker) }
                items.remove(at: idx)
                try saveLocked()
            } catch {
                items = oldItems
                for url in restored { try? fm.removeItem(at: url) }
                if let marker, markerExisted, !fm.fileExists(atPath: marker.path) {
                    _ = fm.createFile(atPath: marker.path, contents: Data())
                }
                AuditLog.write("trash.restore.fail id=\(id) err=\(error.localizedDescription)")
                throw error
            }

            try? fm.removeItem(at: item.trashDirectory)
            AuditLog.write("trash.restore id=\(id)")
        }
    }

    func purge(_ id: String) throws {
        try queue.sync {
            guard let idx = items.firstIndex(where: { $0.id == id }) else {
                throw TrashError.notFound
            }
            let oldItems = items
            let item = items.remove(at: idx)
            do {
                try FileManager.default.removeItem(at: item.trashDirectory)
                try saveLocked()
                AuditLog.write("trash.purge id=\(id)")
            } catch {
                items = oldItems
                throw error
            }
        }
    }

    func purgeExpired(retentionDays: Int) {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-Double(max(0, retentionDays)) * 24 * 3600)
            let expired = items.filter { $0.trashedAt < cutoff }
            var purgedIDs: Set<String> = []
            for item in expired {
                do {
                    try FileManager.default.removeItem(at: item.trashDirectory)
                    purgedIDs.insert(item.id)
                } catch {
                    AuditLog.write("trash.purgeExpired.fail id=\(item.id) err=\(error.localizedDescription)")
                }
            }
            items.removeAll { purgedIDs.contains($0.id) }
            try? saveLocked()
            if !purgedIDs.isEmpty { AuditLog.write("trash.purgeExpired count=\(purgedIDs.count)") }
        }
    }

    private struct Artifact {
        let source: URL
        let storedName: String
    }

    private func sourceArtifacts(for session: SessionRecord) -> [Artifact] {
        var result: [Artifact] = []
        if let meta = session.metaURL {
            result.append(Artifact(source: meta, storedName: "meta_\(meta.lastPathComponent)"))
        }
        if let transcript = session.transcriptURL {
            result.append(Artifact(source: transcript, storedName: "transcript_\(transcript.lastPathComponent)"))
        }
        return result
    }

    private func restorableArtifacts(for item: TrashedSession) throws -> [Artifact] {
        let fm = FileManager.default
        var result: [Artifact] = []
        for expected in sourceArtifacts(for: item.original) {
            let modern = item.trashDirectory.appendingPathComponent(expected.storedName)
            if fm.fileExists(atPath: modern.path) {
                result.append(expected)
                continue
            }

            // Backward compatibility with v0.1.2 trash directories.
            let legacyName = expected.storedName.hasPrefix("transcript_")
                ? String(expected.storedName.dropFirst("transcript_".count))
                : expected.storedName
            let legacy = item.trashDirectory.appendingPathComponent(legacyName)
            guard fm.fileExists(atPath: legacy.path) else {
                throw TrashError.missingBackup(expected.source.path)
            }
            result.append(Artifact(source: expected.source, storedName: legacyName))
        }
        guard !result.isEmpty else { throw TrashError.noSourceFiles }
        return result
    }

    private func deletedMarker(for session: SessionRecord) -> URL? {
        guard let meta = session.metaURL else { return nil }
        return meta.deletingLastPathComponent()
            .appendingPathComponent("deleted_\(session.cliSessionId ?? session.id)")
    }

    private func filesMatch(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let fm = FileManager.default
        let left = try fm.attributesOfItem(atPath: lhs.path)[.size] as? NSNumber
        let right = try fm.attributesOfItem(atPath: rhs.path)[.size] as? NSNumber
        return left?.int64Value == right?.int64Value
            && fm.contentsEqual(atPath: lhs.path, andPath: rhs.path)
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([TrashedSession].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func saveLocked() throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: manifestURL, options: .atomic)
    }
}

enum TrashError: LocalizedError {
    case notFound
    case alreadyTrashed
    case noSourceFiles
    case verificationFailed(String)
    case sourceChanged(String)
    case markerAlreadyExists(String)
    case markerCreationFailed(String)
    case restoreConflict(String)
    case missingBackup(String)
    case readOnlyProvider(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "回收站中未找到该会话"
        case .alreadyTrashed:
            return "该会话已经在回收站中"
        case .noSourceFiles:
            return "没有找到可移动或恢复的会话文件"
        case let .verificationFailed(path):
            return "回收站副本校验失败：\(path)"
        case let .sourceChanged(path):
            return "会话文件在删除过程中发生变化，已取消并尝试回滚：\(path)"
        case let .markerAlreadyExists(path):
            return "删除标记已存在，为避免覆盖状态已停止操作：\(path)"
        case let .markerCreationFailed(path):
            return "无法创建删除标记：\(path)"
        case let .restoreConflict(path):
            return "恢复目标已存在，为避免覆盖已停止恢复：\(path)"
        case let .missingBackup(path):
            return "回收站备份不完整，缺少：\(path)"
        case let .readOnlyProvider(name):
            return "\(name) 会话是只读的，不能移入回收站"
        }
    }
}

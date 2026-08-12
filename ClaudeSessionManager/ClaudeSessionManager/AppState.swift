import Foundation
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [SessionRecord] = []
    @Published var trashed: [TrashedSession] = []
    @Published var selectedID: String?
    @Published var selectedIDs: Set<String> = []
    @Published var searchText: String = ""
    @Published var useFullTextSearch: Bool = false
    @Published var sort: SessionSort = .lastActivity
    @Published var filter: SessionFilter = .all
    @Published var projectFilter: String? = nil
    @Published var isScanning: Bool = false
    @Published var scanPhase: String = ""
    @Published var scanCurrent: Int = 0
    @Published var scanTotal: Int = 0
    @Published var statusMessage: String?
    @Published var lastErrors: [String] = []
    @Published var isMainWindowVisible: Bool = false

    let settingsStore: SettingsStore
    private let indexStore = IndexStore()
    private let overlayStore = OverlayStore()
    private let trashService = TrashService()
    private var searchIDs: Set<String>? = nil
    private var scanTask: Task<Void, Never>?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        // Load cached index for instant UI, then refresh.
        let cached = indexStore.allSessions().map { applyOverlay($0) }
        sessions = cached
        trashed = trashService.list()
        trashService.purgeExpired(retentionDays: settingsStore.settings.trashRetentionDays)
        trashed = trashService.list()
        // Always kick a background rescan on launch (menu bar may not appear until clicked).
        Task { @MainActor in
            self.refresh()
        }
    }

    var selectedSession: SessionRecord? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    var selectedSessions: [SessionRecord] {
        let ids = effectiveSelectionIDs
        return sessions.filter { ids.contains($0.id) }
    }

    /// Prefer multi-selection; fall back to the focused single row.
    var effectiveSelectionIDs: Set<String> {
        if !selectedIDs.isEmpty { return selectedIDs }
        if let selectedID { return [selectedID] }
        return []
    }

    var projectNames: [String] {
        let names = sessions.compactMap(\.projectName).filter { !$0.isEmpty }
        return Array(Set(names)).sorted()
    }

    func selectOnly(_ id: String) {
        selectedID = id
        selectedIDs = [id]
    }

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if selectedID == id { selectedID = selectedIDs.first }
        } else {
            selectedIDs.insert(id)
            selectedID = id
        }
    }

    func selectAllVisible() {
        let ids = Set(visibleSessions.map(\.id))
        selectedIDs = ids
        selectedID = ids.first
    }

    func clearSelection() {
        selectedIDs = []
        selectedID = nil
    }

    func setArchived(ids: [String], archived: Bool) {
        for id in ids {
            setArchived(sessionID: id, archived: archived)
        }
        if ids.count > 1 {
            statusMessage = archived ? "已归档 \(ids.count) 项" : "已取消归档 \(ids.count) 项"
        }
    }

    var visibleSessions: [SessionRecord] {
        var list = sessions

        switch filter {
        case .all:
            break
        case .active:
            list = list.filter { !$0.isArchived }
        case .archived:
            list = list.filter(\.isArchived)
        case .large:
            list = list.filter { $0.byteSize > 1_000_000 }
        case .trash:
            return []
        }

        if let projectFilter, !projectFilter.isEmpty {
            list = list.filter { $0.projectName == projectFilter }
        }

        if let searchIDs {
            list = list.filter { searchIDs.contains($0.id) }
        }

        switch sort {
        case .lastActivity:
            list.sort { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
        case .created:
            list.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .size:
            list.sort { $0.byteSize > $1.byteSize }
        case .title:
            list.sort { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        }
        return list
    }

    var totalByteSize: Int64 {
        sessions.reduce(0) { $0 + $1.byteSize }
    }

    // MARK: - Scan / Search

    func refresh(fullText: Bool? = nil) {
        scanTask?.cancel()
        let includeBodies = fullText ?? settingsStore.settings.enableFullTextSearch
        isScanning = true
        scanPhase = "准备扫描…"
        scanCurrent = 0
        scanTotal = 0
        let settings = settingsStore.settings

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = SessionScanner.scan(settings: settings, includeBodies: includeBodies) { progress in
                Task { @MainActor in
                    self?.scanPhase = progress.phase
                    self?.scanCurrent = progress.current
                    self?.scanTotal = progress.total
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.indexStore.replaceAll(result.sessions, bodyByID: result.bodyByID)
                self.sessions = result.sessions.map { self.applyOverlay($0) }
                self.lastErrors = result.errors
                self.isScanning = false
                self.scanPhase = ""
                self.statusMessage = "已索引 \(self.sessions.count) 个会话 · \(ByteCountFormatter.string(fromByteCount: self.totalByteSize, countStyle: .file))"
                self.applySearch()
            }
        }
    }

    func applySearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchIDs = nil
            objectWillChange.send()
            return
        }
        if useFullTextSearch && settingsStore.settings.enableFullTextSearch {
            let ids = indexStore.searchFullText(query: q)
            // Also include meta hits.
            let meta = indexStore.searchMeta(query: q)
            searchIDs = Set(ids + meta)
        } else {
            searchIDs = Set(indexStore.searchMeta(query: q))
        }
        objectWillChange.send()
    }

    // MARK: - Mutations

    func rename(sessionID: String, to newTitle: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        sessions[idx].title = title
        sessions[idx].titleSource = "user"
        _ = MetaWriter.updateMeta(at: sessions[idx].metaURL, title: title)
        overlayStore.update(sessionID) { $0.titleOverride = title }
        indexStore.upsert(sessions[idx], body: nil)
        statusMessage = "已重命名"
    }

    func setArchived(sessionID: String, archived: Bool) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].isArchived = archived
        _ = MetaWriter.updateMeta(at: sessions[idx].metaURL, isArchived: archived)
        overlayStore.update(sessionID) { $0.isArchivedOverride = archived }
        indexStore.upsert(sessions[idx], body: nil)
        statusMessage = archived ? "已归档" : "已取消归档"
    }

    func toggleFavorite(sessionID: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].isFavorite.toggle()
        let value = sessions[idx].isFavorite
        overlayStore.update(sessionID) { $0.isFavorite = value }
    }

    func moveToTrash(ids: [String]) {
        var freed: Int64 = 0
        for id in ids {
            guard let idx = sessions.firstIndex(where: { $0.id == id }) else { continue }
            let session = sessions[idx]
            if session.isRecentlyActive {
                // Still allow, but note.
                statusMessage = "注意：\(session.displayTitle) 可能仍在活动"
            }
            do {
                _ = try trashService.moveToTrash(session)
                freed += session.byteSize
                sessions.remove(at: idx)
                indexStore.delete(id: id)
                selectedIDs.remove(id)
                if selectedID == id { selectedID = selectedIDs.first }
            } catch {
                statusMessage = "移入回收站失败: \(error.localizedDescription)"
            }
        }
        trashed = trashService.list()
        statusMessage = "已移入回收站 \(ids.count) 项 · 约 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))"
    }

    func exportSelection(format: ExportFormat) {
        let targets = selectedSessions
        guard !targets.isEmpty else {
            statusMessage = "请先选择会话"
            return
        }
        export(sessions: targets, format: format)
    }

    func archiveSelection(archived: Bool = true) {
        let ids = Array(effectiveSelectionIDs)
        guard !ids.isEmpty else { return }
        setArchived(ids: ids, archived: archived)
    }

    func favoriteRecent(limit: Int = 8) -> [SessionRecord] {
        Array(sessions.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }.prefix(limit))
    }

    func largeSessions(limit: Int = 8) -> [SessionRecord] {
        Array(sessions.sorted { $0.byteSize > $1.byteSize }.prefix(limit))
    }

    func sessions(inProject projectName: String) -> [SessionRecord] {
        sessions.filter { $0.projectName == projectName }
    }

    func sessionCount(inProject projectName: String) -> Int {
        sessions(inProject: projectName).count
    }

    func byteSize(inProject projectName: String) -> Int64 {
        sessions(inProject: projectName).reduce(0) { $0 + $1.byteSize }
    }

    /// Archive / unarchive every session that belongs to a project folder name.
    func setArchived(projectName: String, archived: Bool) {
        let ids = sessions(inProject: projectName).map(\.id)
        guard !ids.isEmpty else {
            statusMessage = "项目「\(projectName)」下没有会话"
            return
        }
        setArchived(ids: ids, archived: archived)
        statusMessage = archived
            ? "已归档项目「\(projectName)」的 \(ids.count) 个会话"
            : "已取消归档项目「\(projectName)」的 \(ids.count) 个会话"
    }

    /// Move every session in a project into the app trash.
    func moveProjectToTrash(projectName: String) {
        let ids = sessions(inProject: projectName).map(\.id)
        guard !ids.isEmpty else {
            statusMessage = "项目「\(projectName)」下没有会话"
            return
        }
        moveToTrash(ids: ids)
        if projectFilter == projectName {
            projectFilter = nil
        }
        statusMessage = "已将项目「\(projectName)」的 \(ids.count) 个会话移入回收站"
    }

    func exportProject(projectName: String, format: ExportFormat) {
        let items = sessions(inProject: projectName)
        guard !items.isEmpty else {
            statusMessage = "项目「\(projectName)」下没有会话"
            return
        }
        export(sessions: items, format: format)
    }

    func revealProjectFolder(projectName: String) {
        // Prefer a live cwd from any session in that project.
        if let cwd = sessions(inProject: projectName).compactMap(\.cwd).first {
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
            return
        }
        statusMessage = "找不到项目「\(projectName)」的本地路径"
    }

    func restoreFromTrash(id: String) {
        do {
            try trashService.restore(id)
            trashed = trashService.list()
            refresh(fullText: false)
            statusMessage = "已恢复，正在刷新列表…"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func purgeTrash(id: String) {
        do {
            try trashService.purge(id)
            trashed = trashService.list()
            statusMessage = "已永久删除"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func emptyTrash() {
        for item in trashService.list() {
            try? trashService.purge(item.id)
        }
        trashed = []
        statusMessage = "回收站已清空"
    }

    // MARK: - Export / Actions

    func export(sessions sessionsToExport: [SessionRecord], format: ExportFormat) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "导出到此文件夹"
        panel.message = "选择导出目录"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let urls = try ExportService.exportMany(sessionsToExport, format: format, to: dir)
            statusMessage = "已导出 \(urls.count) 个文件"
            if let first = urls.first {
                NSWorkspace.shared.activateFileViewerSelecting(urls.count == 1 ? [first] : [dir])
            }
        } catch {
            statusMessage = "导出失败: \(error.localizedDescription)"
        }
    }

    func copyResume(session: SessionRecord) {
        ResumeAction.copyCommand(for: session)
        statusMessage = "Resume 命令已复制"
    }

    func reveal(session: SessionRecord) {
        ResumeAction.reveal(session)
    }

    func openTerminal(session: SessionRecord) {
        ResumeAction.openInTerminal(session: session)
        statusMessage = "已在终端打开"
    }

    // MARK: - Overlay

    private func applyOverlay(_ session: SessionRecord) -> SessionRecord {
        var s = session
        let o = overlayStore.overlay(for: session.id)
        if let t = o.titleOverride, !t.isEmpty { s.title = t }
        if let a = o.isArchivedOverride { s.isArchived = a }
        s.isFavorite = o.isFavorite
        s.tags = o.tags
        return s
    }
}

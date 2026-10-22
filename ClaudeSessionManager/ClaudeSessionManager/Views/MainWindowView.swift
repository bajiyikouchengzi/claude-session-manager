import SwiftUI
import AppKit

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var renameText: String = ""
    @State private var showRename = false
    @State private var confirmTrash = false
    @State private var confirmActiveTrash = false
    @State private var pendingTrashIDs: [String] = []
    @State private var confirmProjectTrash = false
    @State private var confirmActiveProjectTrash = false
    @State private var pendingProject: ProjectGroup?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            sessionList
                .navigationSplitViewColumnWidth(min: 340, ideal: 440, max: 600)
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .searchable(text: $appState.searchText, prompt: "搜索标题、路径或正文")
        .onChange(of: appState.searchText) { _ in appState.applySearch() }
        .onSubmit(of: .search) { appState.applySearch() }
        .alert("重命名会话", isPresented: $showRename) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if let id = appState.selectedID {
                    appState.rename(sessionID: id, to: renameText)
                }
            }
        } message: {
            Text("将同时写回 Desktop 元数据（若存在）与本地覆盖层。")
        }
        .confirmationDialog(
            "移入回收站？",
            isPresented: $confirmTrash,
            titleVisibility: .visible
        ) {
            Button(activeCount(in: pendingTrashIDs) > 0 ? "仅删除非活跃会话" : "移入回收站", role: .destructive) {
                appState.moveToTrash(ids: pendingTrashIDs)
                pendingTrashIDs = []
            }
            if activeCount(in: pendingTrashIDs) > 0 {
                Button("继续确认删除活跃会话…", role: .destructive) {
                    DispatchQueue.main.async { confirmActiveTrash = true }
                }
            }
            Button("取消", role: .cancel) {
                pendingTrashIDs = []
            }
        } message: {
            let size = pendingTrashIDs
                .compactMap { id in appState.sessions.first { $0.id == id }?.byteSize }
                .reduce(Int64(0), +)
            let active = activeCount(in: pendingTrashIDs)
            Text("将处理 \(pendingTrashIDs.count) 个会话（约 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))）。\(active > 0 ? "其中 \(active) 个在最近 2 分钟内仍有活动，默认会跳过。" : "")可在 \(settingsStore.settings.trashRetentionDays) 天内恢复。")
        }
        .confirmationDialog(
            "确认删除活跃会话？",
            isPresented: $confirmActiveTrash,
            titleVisibility: .visible
        ) {
            Button("仍然移入回收站", role: .destructive) {
                appState.moveToTrash(ids: pendingTrashIDs, allowRecentlyActive: true)
                pendingTrashIDs = []
            }
            Button("取消", role: .cancel) { pendingTrashIDs = [] }
        } message: {
            Text("有 \(activeCount(in: pendingTrashIDs)) 个会话可能仍被 Claude 写入。强制移动可能中断当前会话，请确认 Claude 已停止使用这些会话。")
        }
        .confirmationDialog(
            projectTrashTitle,
            isPresented: $confirmProjectTrash,
            titleVisibility: .visible
        ) {
            Button(projectActiveCount > 0 ? "仅删除非活跃会话" : "删除该项目全部会话", role: .destructive) {
                if let project = pendingProject {
                    appState.moveProjectToTrash(projectID: project.id)
                }
                pendingProject = nil
            }
            if projectActiveCount > 0 {
                Button("继续确认删除活跃会话…", role: .destructive) {
                    DispatchQueue.main.async { confirmActiveProjectTrash = true }
                }
            }
            Button("取消", role: .cancel) {
                pendingProject = nil
            }
        } message: {
            if let project = pendingProject {
                let editable = appState.editableSessions(inProject: project.id)
                let count = editable.count
                let size = editable.reduce(Int64(0)) { $0 + $1.byteSize }
                Text("项目「\(project.name)」有 \(count) 个 Claude 会话可删除（约 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))）。\(projectActiveCount > 0 ? "其中 \(projectActiveCount) 个最近仍有活动，默认会跳过。" : "")Codex、Grok、OpenCode 会话保持只读。只处理 \(PathDetector.abbreviate(project.path)) 下的会话，不会删除项目源码。")
            }
        }
        .confirmationDialog(
            "确认删除项目中的活跃会话？",
            isPresented: $confirmActiveProjectTrash,
            titleVisibility: .visible
        ) {
            Button("仍然删除全部会话", role: .destructive) {
                if let project = pendingProject {
                    appState.moveProjectToTrash(projectID: project.id, allowRecentlyActive: true)
                }
                pendingProject = nil
            }
            Button("取消", role: .cancel) { pendingProject = nil }
        } message: {
            Text("该项目有 \(projectActiveCount) 个会话可能仍被 Claude 写入。强制移动可能中断当前会话。")
        }
        .onAppear {
            if appState.sessions.isEmpty && !appState.isScanning {
                appState.refresh()
            }
        }
    }

    private var projectTrashTitle: String {
        if let project = pendingProject {
            return "删除项目「\(project.name)」的全部会话？"
        }
        return "删除项目全部会话？"
    }

    private var projectActiveCount: Int {
        guard let project = pendingProject else { return 0 }
        return appState.editableSessions(inProject: project.id).filter(\.isRecentlyActive).count
    }

    private var selectionCanEdit: Bool {
        appState.selectedSessions.contains(where: \.canEditSource)
    }

    private func activeCount(in ids: [String]) -> Int {
        let idSet = Set(ids)
        return appState.sessions.filter { idSet.contains($0.id) && $0.isRecentlyActive }.count
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section("筛选") {
                ForEach(SessionFilter.allCases) { f in
                    sidebarRow(
                        title: f.label,
                        systemImage: icon(for: f),
                        selected: appState.filter == f
                    ) {
                        appState.filter = f
                        if f == .trash {
                            appState.projectFilter = nil
                        }
                    }
                }
            }

            Section("来源") {
                ForEach(ProviderFilter.allCases) { item in
                    let count = item.provider.map { appState.sessionCount(provider: $0) } ?? appState.sessions.count
                    sidebarRow(
                        title: item.label,
                        systemImage: icon(for: item),
                        selected: appState.providerFilter == item && appState.filter != .trash,
                        trailing: "\(count)"
                    ) {
                        appState.providerFilter = item
                        if appState.filter == .trash { appState.filter = .all }
                    }
                }
            }

            Section("项目") {
                sidebarRow(
                    title: "全部项目",
                    systemImage: "folder",
                    selected: appState.projectFilter == nil && appState.filter != .trash,
                    trailing: "\(appState.sessions.count)"
                ) {
                    appState.projectFilter = nil
                    if appState.filter == .trash { appState.filter = .all }
                }

                ForEach(appState.projectGroups) { project in
                    let count = appState.sessionCount(inProject: project.id)
                    sidebarRow(
                        title: project.name,
                        subtitle: PathDetector.abbreviate(project.path),
                        systemImage: "folder.fill",
                        selected: appState.projectFilter == project.id,
                        trailing: "\(count)",
                        contextMenu: { projectContextMenu(for: project) }
                    ) {
                        appState.projectFilter = project.id
                        if appState.filter == .trash { appState.filter = .all }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func projectContextMenu(for project: ProjectGroup) -> some View {
        let count = appState.sessionCount(inProject: project.id)
        let editable = appState.editableSessions(inProject: project.id)
        let editableCount = editable.count
        let editableSize = editable.reduce(Int64(0)) { $0 + $1.byteSize }
        let archivedCount = editable.filter(\.isArchived).count
        let activeCount = editableCount - archivedCount

        Button("查看该项目会话") {
            appState.projectFilter = project.id
            if appState.filter == .trash { appState.filter = .all }
        }
        Button("在 Finder 中打开项目目录") {
            appState.revealProjectFolder(projectID: project.id)
        }
        Divider()
        Menu("导出该项目全部会话") {
            Button("Markdown") { appState.exportProject(projectID: project.id, format: .markdown) }
            Button("JSON") { appState.exportProject(projectID: project.id, format: .json) }
            Button("Zip 打包") { appState.exportProject(projectID: project.id, format: .zipBundle) }
        }
        .disabled(count == 0)
        Divider()
        if activeCount > 0 {
            Button("归档该项目的 Claude 会话（\(activeCount)）") {
                appState.setArchived(projectID: project.id, archived: true)
            }
        }
        if archivedCount > 0 {
            Button("取消归档该项目会话（\(archivedCount)）") {
                appState.setArchived(projectID: project.id, archived: false)
            }
        }
        Divider()
        Button("删除该项目的 Claude 会话（\(editableCount) · \(ByteCountFormatter.string(fromByteCount: editableSize, countStyle: .file))）", role: .destructive) {
            pendingProject = project
            confirmProjectTrash = true
        }
        .disabled(editableCount == 0)
    }

    private func sidebarRow<MenuContent: View>(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        selected: Bool,
        trailing: String? = nil,
        @ViewBuilder contextMenu: () -> MenuContent = { EmptyView() },
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.9))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu(menuItems: contextMenu)
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
        .listRowSeparator(.hidden)
    }

    // MARK: - List

    private var sessionList: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            if appState.filter == .trash {
                trashList
            } else if appState.visibleSessions.isEmpty {
                ContentUnavailableView {
                    Label(appState.isScanning ? "正在扫描" : "无会话", systemImage: "tray")
                } description: {
                    Text(appState.isScanning ? appState.scanPhase : "试试刷新索引，或调整筛选 / 搜索条件。")
                } actions: {
                    Button("刷新索引") { appState.refresh() }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(appState.visibleSessions.enumerated()), id: \.element.id) { index, session in
                            let isSelected = appState.selectedIDs.contains(session.id) || appState.selectedID == session.id
                            SessionRowView(session: session, isSelected: isSelected, zebra: index.isMultiple(of: 2))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if NSEvent.modifierFlags.contains(.command) {
                                        appState.toggleSelection(session.id)
                                    } else if NSEvent.modifierFlags.contains(.shift),
                                              let anchor = appState.selectedID,
                                              let from = appState.visibleSessions.firstIndex(where: { $0.id == anchor }),
                                              let to = appState.visibleSessions.firstIndex(where: { $0.id == session.id }) {
                                        let range = from <= to ? from...to : to...from
                                        appState.selectedIDs = Set(appState.visibleSessions[range].map(\.id))
                                        appState.selectedID = session.id
                                    } else {
                                        appState.selectOnly(session.id)
                                    }
                                }
                                .contextMenu { contextMenu(for: session) }
                        }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }

            if !appState.effectiveSelectionIDs.isEmpty && appState.filter != .trash {
                batchBar
            }

            if let status = appState.statusMessage {
                Divider()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            Picker("排序", selection: $appState.sort) {
                ForEach(SessionSort.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 150)

            Toggle("全文", isOn: $appState.useFullTextSearch)
                .toggleStyle(.checkbox)
                .onChange(of: appState.useFullTextSearch) { _ in appState.applySearch() }
                .help("开启后在 transcript 正文中搜索（需已建立全文索引）")

            Spacer()

            if appState.isScanning {
                ProgressView(value: appState.scanTotal > 0 ? Double(appState.scanCurrent) / Double(appState.scanTotal) : nil)
                    .frame(width: 80)
                Text(appState.scanPhase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("\(appState.visibleSessions.count) / \(appState.sessions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var batchBar: some View {
        HStack(spacing: 10) {
            Text("已选 \(appState.effectiveSelectionIDs.count) 项")
                .font(.callout.weight(.medium))
            Button("全选可见") { appState.selectAllVisible() }
            Button("清除选择") { appState.clearSelection() }
            Spacer()
            Menu("批量导出") {
                Button("Markdown") { appState.exportSelection(format: .markdown) }
                Button("JSON") { appState.exportSelection(format: .json) }
                Button("Zip 打包") { appState.exportSelection(format: .zipBundle) }
            }
            Button("批量归档") { appState.archiveSelection(archived: true) }
                .disabled(!selectionCanEdit)
            Button("批量删除", role: .destructive) {
                pendingTrashIDs = editableSelectionIDs
                confirmTrash = true
            }
            .disabled(!selectionCanEdit)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var trashList: some View {
        Group {
            if appState.trashed.isEmpty {
                ContentUnavailableView("回收站为空", systemImage: "trash")
            } else {
                List {
                    ForEach(appState.trashed) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.original.displayTitle).font(.headline)
                            Text(item.original.cwd ?? item.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("删除于 \(item.trashedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contextMenu {
                            Button("恢复") { appState.restoreFromTrash(id: item.id) }
                            Button("永久删除", role: .destructive) { appState.purgeTrash(id: item.id) }
                        }
                    }
                }
                HStack {
                    Button("清空回收站", role: .destructive) { appState.emptyTrash() }
                    Spacer()
                }
                .padding(8)
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if appState.filter == .trash {
                ContentUnavailableView("在回收站列表中右键恢复或永久删除", systemImage: "trash")
            } else if appState.effectiveSelectionIDs.count > 1 {
                multiSelectDetail
            } else if let session = appState.selectedSession {
                SessionDetailView(session: session)
            } else {
                ContentUnavailableView("选择一个会话", systemImage: "sidebar.left")
            }
        }
    }

    private var multiSelectDetail: some View {
        let items = appState.selectedSessions
        let total = items.reduce(Int64(0)) { $0 + $1.byteSize }
        return VStack(alignment: .leading, spacing: 16) {
            Text("已选择 \(items.count) 个会话")
                .font(.title2.weight(.semibold))
            Text("合计体积 \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                .foregroundStyle(.secondary)
            HStack {
                Menu("批量导出") {
                    Button("Markdown") { appState.exportSelection(format: .markdown) }
                    Button("JSON") { appState.exportSelection(format: .json) }
                    Button("Zip 打包") { appState.exportSelection(format: .zipBundle) }
                }
                Button("批量归档") { appState.archiveSelection(archived: true) }
                    .disabled(!selectionCanEdit)
                Button("批量删除", role: .destructive) {
                    pendingTrashIDs = editableSelectionIDs
                    confirmTrash = true
                }
                .disabled(!selectionCanEdit)
            }
            .buttonStyle(.bordered)
            List(items) { s in
                HStack {
                    Text(s.displayTitle).lineLimit(1)
                    Spacer()
                    Text(s.formattedSize).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                appState.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .help("重新扫描本地会话")

            Menu {
                Button("导出选中 Markdown") { appState.exportSelection(format: .markdown) }
                Button("导出选中 JSON") { appState.exportSelection(format: .json) }
                Button("导出选中 Zip") { appState.exportSelection(format: .zipBundle) }
                Divider()
                Button("导出当前可见为 Zip") {
                    appState.export(sessions: appState.visibleSessions, format: .zipBundle)
                }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(appState.effectiveSelectionIDs.isEmpty && appState.visibleSessions.isEmpty)

            Button {
                guard let s = appState.selectedSession else { return }
                renameText = s.displayTitle
                showRename = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .disabled(appState.selectedSession?.canEditSource != true || appState.effectiveSelectionIDs.count > 1)

            Button {
                appState.archiveSelection(archived: !(appState.selectedSession?.isArchived ?? false))
            } label: {
                Label("归档", systemImage: "archivebox")
            }
            .disabled(!selectionCanEdit)

            Button(role: .destructive) {
                pendingTrashIDs = editableSelectionIDs
                confirmTrash = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(!selectionCanEdit)
        }
    }

    @ViewBuilder
    private func contextMenu(for session: SessionRecord) -> some View {
        Button("复制 Resume 命令") { appState.copyResume(session: session) }
        Button("在终端 Resume") { appState.openTerminal(session: session) }
        Button("在 Finder 中显示") { appState.reveal(session: session) }
        Divider()
        Button("导出 Markdown…") { appState.export(sessions: [session], format: .markdown) }
        Button("导出 JSON…") { appState.export(sessions: [session], format: .json) }
        Button("导出 Zip…") { appState.export(sessions: [session], format: .zipBundle) }
        Divider()
        Button(session.isFavorite ? "取消收藏" : "收藏") {
            appState.toggleFavorite(sessionID: session.id)
        }
        if session.canEditSource {
            Button(session.isArchived ? "取消归档" : "归档") {
                appState.setArchived(sessionID: session.id, archived: !session.isArchived)
            }
            Button("重命名…") {
                appState.selectOnly(session.id)
                renameText = session.displayTitle
                showRename = true
            }
            Divider()
            if appState.effectiveSelectionIDs.count > 1 {
                Button("删除选中的 Claude 会话", role: .destructive) {
                    pendingTrashIDs = editableSelectionIDs
                    confirmTrash = true
                }
                Button("导出选中 Zip…") { appState.exportSelection(format: .zipBundle) }
            } else {
                Button("移入回收站", role: .destructive) {
                    pendingTrashIDs = [session.id]
                    confirmTrash = true
                }
            }
        }
    }

    private var editableSelectionIDs: [String] {
        appState.selectedSessions.filter(\.canEditSource).map(\.id)
    }

    private func icon(for filter: SessionFilter) -> String {
        switch filter {
        case .all: return "tray.full"
        case .active: return "bubble.left"
        case .archived: return "archivebox"
        case .large: return "externaldrive"
        case .trash: return "trash"
        }
    }

    private func icon(for filter: ProviderFilter) -> String {
        switch filter {
        case .all: return "square.stack"
        case .claude: return "bubble.left.and.bubble.right"
        case .codex: return "terminal"
        case .grok: return "sparkles"
        case .opencode: return "shippingbox"
        }
    }
}

struct SessionRowView: View {
    let session: SessionRecord
    var isSelected: Bool = false
    var zebra: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(sourceColor)
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if session.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }
                    Text(session.displayTitle)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(session.formattedSize)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }

                HStack(spacing: 8) {
                    badge(session.originLabel, color: sourceColor.opacity(0.18))
                    if session.isArchived {
                        badge("已归档", color: Color.orange.opacity(0.18))
                    }
                    if let project = session.projectName {
                        Text(project)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let model = session.model {
                        Text(model.replacingOccurrences(of: "claude-", with: ""))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let activity = session.lastActivityAt {
                        Text(activity, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowBackground)
                .shadow(color: Color.black.opacity(isSelected ? 0.12 : 0.05), radius: isSelected ? 6 : 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.05), lineWidth: isSelected ? 1.5 : 1)
        )
    }

    private var sourceColor: Color {
        switch session.provider {
        case .codex: return .orange
        case .grok: return .blue
        case .opencode: return .indigo
        case .claude:
            switch session.source {
            case .merged: return .accentColor
            case .desktopCodeMeta: return .purple
            case .codeJsonl: return .teal
            case .external: return .accentColor
            }
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.10)
        }
        return zebra
            ? Color(nsColor: .controlBackgroundColor)
            : Color(nsColor: .textBackgroundColor)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var appState: AppState
    let session: SessionRecord
    @State private var previewLines: [PreviewLine] = []
    @State private var isLoadingPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                metaGrid
                actions
                Divider()
                previewSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { loadPreview() }
        .onChange(of: session.id) { _ in loadPreview() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.displayTitle)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            if let cwd = session.cwd {
                Text(cwd)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !session.canEditSource {
                Text("\(session.provider.label) 会话只读。可以搜索、预览、导出，以及复制恢复命令。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metaGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("会话 ID", session.nativeSessionID)
            row("来源", session.originLabel)
            if let model = session.model { row("模型", model) }
            if let effort = session.effort { row("Effort", effort) }
            if let branch = session.gitBranch { row("分支", branch) }
            if let created = session.createdAt {
                row("创建", created.formatted(date: .abbreviated, time: .shortened))
            }
            if let activity = session.lastActivityAt {
                row("最近活动", activity.formatted(date: .abbreviated, time: .shortened))
            }
            row("体积", session.formattedSize)
            if let mc = session.messageCount { row("消息数(采样)", "\(mc)") }
            if let turns = session.completedTurns { row("完成轮次", "\(turns)") }
            row("归档", session.isArchived ? "是" : "否")
            if let meta = session.metaURL { row("元数据", meta.path) }
            if let t = session.transcriptURL { row("Transcript", t.path) }
            if let container = session.containerURL {
                row(session.provider == .opencode ? "数据库" : "容器", container.path)
            }
            if let err = session.parseError { row("解析警告", err) }
        }
        .font(.callout)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(v)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("复制 Resume") { appState.copyResume(session: session) }
            Button("终端打开") { appState.openTerminal(session: session) }
            Button("Finder") { appState.reveal(session: session) }
            Menu("导出") {
                Button("Markdown") { appState.export(sessions: [session], format: .markdown) }
                Button("JSON") { appState.export(sessions: [session], format: .json) }
                Button("Zip") { appState.export(sessions: [session], format: .zipBundle) }
            }
        }
        .buttonStyle(.bordered)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("消息预览")
                    .font(.headline)
                Spacer()
                if isLoadingPreview {
                    ProgressView().controlSize(.small)
                }
            }
            if previewLines.isEmpty {
                Text("无预览内容（可能尚无 transcript）。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(previewLines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.role.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(line.role == "user" ? Color.accentColor : Color.secondary)
                        Text(line.text)
                            .font(.system(.body, design: .default))
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
            }
        }
    }

    private func loadPreview() {
        isLoadingPreview = true
        previewLines = []
        let session = session
        Task.detached(priority: .utility) {
            let turns = TranscriptText.previewTurns(for: session, limit: 12)
            let lines = turns.enumerated().map { index, turn in
                PreviewLine(id: index, role: turn.role, text: turn.text)
            }
            await MainActor.run {
                self.previewLines = lines
                self.isLoadingPreview = false
            }
        }
    }
}

struct PreviewLine: Identifiable {
    var id: Int
    var role: String
    var text: String
}

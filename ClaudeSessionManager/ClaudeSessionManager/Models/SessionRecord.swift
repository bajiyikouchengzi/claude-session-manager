import Foundation

enum SessionSource: String, Codable, CaseIterable, Identifiable {
    case desktopCodeMeta
    case codeJsonl
    case merged

    var id: String { rawValue }

    var label: String {
        switch self {
        case .desktopCodeMeta: return "Desktop"
        case .codeJsonl: return "Code"
        case .merged: return "Desktop+Code"
        }
    }
}

struct SessionRecord: Identifiable, Hashable, Codable {
    /// Stable id: prefer cliSessionId, else desktop sessionId, else path hash.
    var id: String
    var source: SessionSource
    var title: String
    var cwd: String?
    var projectName: String?
    var model: String?
    var effort: String?
    var createdAt: Date?
    var lastActivityAt: Date?
    var byteSize: Int64
    var messageCount: Int?
    var completedTurns: Int?
    var isArchived: Bool
    var isFavorite: Bool
    var tags: [String]
    var gitBranch: String?
    var desktopSessionId: String?
    var cliSessionId: String?
    var metaURL: URL?
    var transcriptURL: URL?
    var parseError: String?
    var titleSource: String?

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let projectName, !projectName.isEmpty { return projectName }
        if let cwd { return URL(fileURLWithPath: cwd).lastPathComponent }
        return String(id.prefix(8))
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var isRecentlyActive: Bool {
        guard let lastActivityAt else { return false }
        return Date().timeIntervalSince(lastActivityAt) < 120
    }
}

enum SessionSort: String, CaseIterable, Identifiable {
    case lastActivity
    case created
    case size
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastActivity: return "最近活动"
        case .created: return "创建时间"
        case .size: return "体积"
        case .title: return "标题"
        }
    }
}

enum SessionFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case archived
    case large
    case trash

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部"
        case .active: return "未归档"
        case .archived: return "已归档"
        case .large: return "较大 (>1MB)"
        case .trash: return "回收站"
        }
    }
}

struct TrashedSession: Identifiable, Codable, Hashable {
    var id: String
    var original: SessionRecord
    var trashedAt: Date
    var trashDirectory: URL
}

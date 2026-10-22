import Foundation

enum SessionSource: String, Codable, CaseIterable, Identifiable {
    case desktopCodeMeta
    case codeJsonl
    case merged
    case external

    var id: String { rawValue }

    var label: String {
        switch self {
        case .desktopCodeMeta: return "Desktop"
        case .codeJsonl: return "Code"
        case .merged: return "Desktop+Code"
        case .external: return "外部"
        }
    }
}

enum SessionProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case grok
    case opencode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .opencode: return "OpenCode"
        }
    }

    /// Title, archive, and trash write back into Claude's own files only.
    var canEditSource: Bool { self == .claude }

    func storageID(_ nativeID: String) -> String {
        self == .claude ? nativeID : "\(rawValue):\(nativeID)"
    }
}

enum ProviderFilter: String, CaseIterable, Identifiable {
    case all
    case claude
    case codex
    case grok
    case opencode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部来源"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .opencode: return "OpenCode"
        }
    }

    var provider: SessionProvider? {
        switch self {
        case .all: return nil
        case .claude: return .claude
        case .codex: return .codex
        case .grok: return .grok
        case .opencode: return .opencode
        }
    }
}

struct SessionRecord: Identifiable, Hashable, Codable, Sendable {
    /// Stable id: Claude keeps the native id. Other tools use `provider:nativeId`.
    var id: String
    var provider: SessionProvider = .claude
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
    /// SQLite database or other container that is not a single transcript file.
    var containerURL: URL?

    var canEditSource: Bool { provider.canEditSource }

    /// Native id passed to the tool's resume command.
    var nativeSessionID: String { cliSessionId ?? id }

    var originLabel: String {
        provider == .claude ? source.label : provider.label
    }

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

    /// Stable project identity. Display names are not unique, so project-wide
    /// operations must always use the normalized full working directory.
    var projectID: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
    }
}

struct ProjectGroup: Identifiable, Hashable {
    let id: String
    let name: String

    var path: String { id }
}

extension SessionRecord {
    private enum CodingKeys: String, CodingKey {
        case id, provider, source, title, cwd, projectName, model, effort
        case createdAt, lastActivityAt, byteSize, messageCount, completedTurns
        case isArchived, isFavorite, tags, gitBranch
        case desktopSessionId, cliSessionId, metaURL, transcriptURL
        case parseError, titleSource, containerURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decodeIfPresent(SessionProvider.self, forKey: .provider) ?? .claude
        source = try c.decodeIfPresent(SessionSource.self, forKey: .source) ?? .codeJsonl
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        byteSize = try c.decodeIfPresent(Int64.self, forKey: .byteSize) ?? 0
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount)
        completedTurns = try c.decodeIfPresent(Int.self, forKey: .completedTurns)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        desktopSessionId = try c.decodeIfPresent(String.self, forKey: .desktopSessionId)
        cliSessionId = try c.decodeIfPresent(String.self, forKey: .cliSessionId)
        metaURL = try c.decodeIfPresent(URL.self, forKey: .metaURL)
        transcriptURL = try c.decodeIfPresent(URL.self, forKey: .transcriptURL)
        parseError = try c.decodeIfPresent(String.self, forKey: .parseError)
        titleSource = try c.decodeIfPresent(String.self, forKey: .titleSource)
        containerURL = try c.decodeIfPresent(URL.self, forKey: .containerURL)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(provider, forKey: .provider)
        try c.encode(source, forKey: .source)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(projectName, forKey: .projectName)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastActivityAt, forKey: .lastActivityAt)
        try c.encode(byteSize, forKey: .byteSize)
        try c.encodeIfPresent(messageCount, forKey: .messageCount)
        try c.encodeIfPresent(completedTurns, forKey: .completedTurns)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(gitBranch, forKey: .gitBranch)
        try c.encodeIfPresent(desktopSessionId, forKey: .desktopSessionId)
        try c.encodeIfPresent(cliSessionId, forKey: .cliSessionId)
        try c.encodeIfPresent(metaURL, forKey: .metaURL)
        try c.encodeIfPresent(transcriptURL, forKey: .transcriptURL)
        try c.encodeIfPresent(parseError, forKey: .parseError)
        try c.encodeIfPresent(titleSource, forKey: .titleSource)
        try c.encodeIfPresent(containerURL, forKey: .containerURL)
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

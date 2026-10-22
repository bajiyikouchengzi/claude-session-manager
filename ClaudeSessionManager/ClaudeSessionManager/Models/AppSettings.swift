import Foundation

struct AppSettings: Codable, Equatable {
    /// Claude Code config root, typically ~/.claude (tilde allowed).
    var claudeConfigDir: String
    /// Claude Desktop Application Support dir (Claude or Claude-3p). Tilde allowed.
    var claudeDesktopSupportDir: String
    /// Also scan the other common Desktop support folder if it exists and differs.
    var scanBothDesktopVariants: Bool
    var trashRetentionDays: Int
    var enableFullTextSearch: Bool
    var fullTextMaxBytesPerSession: Int
    var launchAtLogin: Bool
    var showDockIconWhenMainWindowOpen: Bool
    var scanCodex: Bool
    var scanGrok: Bool
    var scanOpenCode: Bool
    /// Codex home, typically ~/.codex.
    var codexHome: String
    /// Grok home, typically ~/.grok.
    var grokHome: String
    /// OpenCode sqlite database.
    var openCodeDatabase: String

    /// Backward-compatible key used in early builds.
    private var claude3pSupportDir: String? = nil

    static let `default` = detectDefaults()

    static func detectDefaults() -> AppSettings {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let code = (home as NSString).appendingPathComponent(".claude")
        let desktop = PathDetector.preferredDesktopSupportDir()
        let codex = (home as NSString).appendingPathComponent(".codex")
        let grok = (home as NSString).appendingPathComponent(".grok")
        let openCode = (home as NSString).appendingPathComponent(".local/share/opencode/opencode.db")
        return AppSettings(
            claudeConfigDir: PathDetector.abbreviate(code),
            claudeDesktopSupportDir: PathDetector.abbreviate(desktop),
            scanBothDesktopVariants: true,
            trashRetentionDays: 14,
            enableFullTextSearch: true,
            fullTextMaxBytesPerSession: 2_000_000,
            launchAtLogin: false,
            showDockIconWhenMainWindowOpen: true,
            scanCodex: true,
            scanGrok: true,
            scanOpenCode: true,
            codexHome: PathDetector.abbreviate(codex),
            grokHome: PathDetector.abbreviate(grok),
            openCodeDatabase: PathDetector.abbreviate(openCode)
        )
    }

    var codexHomeURL: URL {
        URL(fileURLWithPath: PathDetector.expand(codexHome), isDirectory: true)
    }

    var grokHomeURL: URL {
        URL(fileURLWithPath: PathDetector.expand(grokHome), isDirectory: true)
    }

    var openCodeDatabaseURL: URL {
        URL(fileURLWithPath: PathDetector.expand(openCodeDatabase))
    }

    var projectsDir: URL {
        URL(fileURLWithPath: PathDetector.expand(claudeConfigDir), isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// All Desktop Application Support roots that should be scanned.
    var desktopSupportDirs: [URL] {
        var dirs: [URL] = []
        let primary = URL(fileURLWithPath: PathDetector.expand(claudeDesktopSupportDir), isDirectory: true)
        dirs.append(primary)
        if scanBothDesktopVariants {
            for candidate in PathDetector.knownDesktopSupportDirs() where candidate.standardizedFileURL != primary.standardizedFileURL {
                if FileManager.default.fileExists(atPath: candidate.path) {
                    dirs.append(candidate)
                }
            }
        }
        return dirs
    }

    var codeSessionsDirs: [URL] {
        desktopSupportDirs.map { $0.appendingPathComponent("claude-code-sessions", isDirectory: true) }
    }

    /// Legacy single-dir accessor for older call sites.
    var codeSessionsDir: URL {
        codeSessionsDirs.first!
    }

    enum CodingKeys: String, CodingKey {
        case claudeConfigDir
        case claudeDesktopSupportDir
        case claude3pSupportDir
        case scanBothDesktopVariants
        case trashRetentionDays
        case enableFullTextSearch
        case fullTextMaxBytesPerSession
        case launchAtLogin
        case showDockIconWhenMainWindowOpen
        case scanCodex
        case scanGrok
        case scanOpenCode
        case codexHome
        case grokHome
        case openCodeDatabase
    }

    init(
        claudeConfigDir: String,
        claudeDesktopSupportDir: String,
        scanBothDesktopVariants: Bool,
        trashRetentionDays: Int,
        enableFullTextSearch: Bool,
        fullTextMaxBytesPerSession: Int,
        launchAtLogin: Bool,
        showDockIconWhenMainWindowOpen: Bool,
        scanCodex: Bool,
        scanGrok: Bool,
        scanOpenCode: Bool,
        codexHome: String,
        grokHome: String,
        openCodeDatabase: String
    ) {
        self.claudeConfigDir = claudeConfigDir
        self.claudeDesktopSupportDir = claudeDesktopSupportDir
        self.scanBothDesktopVariants = scanBothDesktopVariants
        self.trashRetentionDays = trashRetentionDays
        self.enableFullTextSearch = enableFullTextSearch
        self.fullTextMaxBytesPerSession = fullTextMaxBytesPerSession
        self.launchAtLogin = launchAtLogin
        self.showDockIconWhenMainWindowOpen = showDockIconWhenMainWindowOpen
        self.scanCodex = scanCodex
        self.scanGrok = scanGrok
        self.scanOpenCode = scanOpenCode
        self.codexHome = codexHome
        self.grokHome = grokHome
        self.openCodeDatabase = openCodeDatabase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claudeConfigDir = try c.decodeIfPresent(String.self, forKey: .claudeConfigDir)
            ?? AppSettings.default.claudeConfigDir
        if let modern = try c.decodeIfPresent(String.self, forKey: .claudeDesktopSupportDir) {
            claudeDesktopSupportDir = modern
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .claude3pSupportDir) {
            claudeDesktopSupportDir = legacy
        } else {
            claudeDesktopSupportDir = AppSettings.default.claudeDesktopSupportDir
        }
        scanBothDesktopVariants = try c.decodeIfPresent(Bool.self, forKey: .scanBothDesktopVariants) ?? true
        trashRetentionDays = try c.decodeIfPresent(Int.self, forKey: .trashRetentionDays) ?? 14
        enableFullTextSearch = try c.decodeIfPresent(Bool.self, forKey: .enableFullTextSearch) ?? true
        fullTextMaxBytesPerSession = try c.decodeIfPresent(Int.self, forKey: .fullTextMaxBytesPerSession) ?? 2_000_000
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showDockIconWhenMainWindowOpen = try c.decodeIfPresent(Bool.self, forKey: .showDockIconWhenMainWindowOpen) ?? true
        let detected = AppSettings.detectDefaults()
        scanCodex = try c.decodeIfPresent(Bool.self, forKey: .scanCodex) ?? detected.scanCodex
        scanGrok = try c.decodeIfPresent(Bool.self, forKey: .scanGrok) ?? detected.scanGrok
        scanOpenCode = try c.decodeIfPresent(Bool.self, forKey: .scanOpenCode) ?? detected.scanOpenCode
        codexHome = try c.decodeIfPresent(String.self, forKey: .codexHome) ?? detected.codexHome
        grokHome = try c.decodeIfPresent(String.self, forKey: .grokHome) ?? detected.grokHome
        openCodeDatabase = try c.decodeIfPresent(String.self, forKey: .openCodeDatabase) ?? detected.openCodeDatabase
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(claudeConfigDir, forKey: .claudeConfigDir)
        try c.encode(claudeDesktopSupportDir, forKey: .claudeDesktopSupportDir)
        try c.encode(scanBothDesktopVariants, forKey: .scanBothDesktopVariants)
        try c.encode(trashRetentionDays, forKey: .trashRetentionDays)
        try c.encode(enableFullTextSearch, forKey: .enableFullTextSearch)
        try c.encode(fullTextMaxBytesPerSession, forKey: .fullTextMaxBytesPerSession)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(showDockIconWhenMainWindowOpen, forKey: .showDockIconWhenMainWindowOpen)
        try c.encode(scanCodex, forKey: .scanCodex)
        try c.encode(scanGrok, forKey: .scanGrok)
        try c.encode(scanOpenCode, forKey: .scanOpenCode)
        try c.encode(codexHome, forKey: .codexHome)
        try c.encode(grokHome, forKey: .grokHome)
        try c.encode(openCodeDatabase, forKey: .openCodeDatabase)
    }
}

enum PathDetector {
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func knownDesktopSupportDirs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/Claude-3p", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        ]
    }

    /// Prefer the Desktop support dir that actually has session metadata.
    static func preferredDesktopSupportDir() -> String {
        let candidates = knownDesktopSupportDirs()
        for dir in candidates {
            let sessions = dir.appendingPathComponent("claude-code-sessions", isDirectory: true)
            if directoryHasChildren(sessions) {
                return dir.path
            }
        }
        for dir in candidates where FileManager.default.fileExists(atPath: dir.path) {
            return dir.path
        }
        return candidates[0].path
    }

    static func directoryHasChildren(_ url: URL) -> Bool {
        guard let kids = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return kids.contains { !$0.hasPrefix(".") }
    }

    static func existenceSummary(settings: AppSettings) -> [String] {
        var lines: [String] = []
        let code = expand(settings.claudeConfigDir)
        let projects = (code as NSString).appendingPathComponent("projects")
        lines.append(FileManager.default.fileExists(atPath: projects)
                     ? "✓ Code projects: \(abbreviate(projects))"
                     : "✗ 未找到 Code projects: \(abbreviate(projects))")
        for dir in settings.desktopSupportDirs {
            let sessions = dir.appendingPathComponent("claude-code-sessions")
            let ok = FileManager.default.fileExists(atPath: sessions.path)
            lines.append(ok
                         ? "✓ Desktop sessions: \(abbreviate(sessions.path))"
                         : "· 无 sessions: \(abbreviate(sessions.path))")
        }
        if settings.scanCodex {
            let sessions = settings.codexHomeURL.appendingPathComponent("sessions").path
            lines.append(FileManager.default.fileExists(atPath: sessions)
                         ? "✓ Codex sessions: \(abbreviate(sessions))"
                         : "· 未找到 Codex sessions: \(abbreviate(sessions))")
        }
        if settings.scanGrok {
            let sessions = settings.grokHomeURL.appendingPathComponent("sessions").path
            lines.append(FileManager.default.fileExists(atPath: sessions)
                         ? "✓ Grok sessions: \(abbreviate(sessions))"
                         : "· 未找到 Grok sessions: \(abbreviate(sessions))")
        }
        if settings.scanOpenCode {
            let database = settings.openCodeDatabaseURL.path
            lines.append(FileManager.default.fileExists(atPath: database)
                         ? "✓ OpenCode 数据库: \(abbreviate(database))"
                         : "· 未找到 OpenCode 数据库: \(abbreviate(database))")
        }
        return lines
    }
}

enum AppPaths {
    static var supportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Keep the original folder so existing indexes, overlays, and trash survive the rename.
        let dir = base.appendingPathComponent("ClaudeSessionManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var indexDB: URL { supportRoot.appendingPathComponent("index.sqlite") }
    static var overlaysURL: URL { supportRoot.appendingPathComponent("overlays.json") }
    static var settingsURL: URL { supportRoot.appendingPathComponent("settings.json") }
    static var trashDir: URL {
        let dir = supportRoot.appendingPathComponent("Trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var auditLog: URL { supportRoot.appendingPathComponent("audit.log") }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { save() }
    }

    init() {
        if let data = try? Data(contentsOf: AppPaths.settingsURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: AppPaths.settingsURL, options: .atomic)
        } catch {
            // Non-fatal.
        }
    }

    func resetToDefaults() {
        settings = .detectDefaults()
    }

    func redetectPaths() {
        let detected = AppSettings.detectDefaults()
        settings.claudeConfigDir = detected.claudeConfigDir
        settings.claudeDesktopSupportDir = detected.claudeDesktopSupportDir
        settings.scanBothDesktopVariants = true
        settings.scanCodex = true
        settings.scanGrok = true
        settings.scanOpenCode = true
        settings.codexHome = detected.codexHome
        settings.grokHome = detected.grokHome
        settings.openCodeDatabase = detected.openCodeDatabase
    }
}

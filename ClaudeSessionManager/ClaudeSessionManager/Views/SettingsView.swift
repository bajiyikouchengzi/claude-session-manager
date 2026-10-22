import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("数据源（可移植）") {
                Text("路径按「当前用户」自动展开 `~`，也可手动选择。换机或发给别人时会重新检测本机 Claude 安装位置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Claude Code 目录") {
                    pathField(text: $settingsStore.settings.claudeConfigDir, pick: pickClaudeConfig)
                }
                LabeledContent("Claude Desktop 目录") {
                    pathField(text: $settingsStore.settings.claudeDesktopSupportDir, pick: pickClaudeDesktop)
                }
                Toggle("同时扫描 Claude 与 Claude-3p（若都存在）", isOn: $settingsStore.settings.scanBothDesktopVariants)
            }

            Section("Codex / Grok / OpenCode") {
                Text("这三处只读。可以搜索、预览、导出和复制恢复命令，不会改标题、归档或删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("扫描 Codex", isOn: $settingsStore.settings.scanCodex)
                LabeledContent("Codex 目录") {
                    pathField(text: $settingsStore.settings.codexHome, pick: pickCodexHome)
                }
                Toggle("扫描 Grok", isOn: $settingsStore.settings.scanGrok)
                LabeledContent("Grok 目录") {
                    pathField(text: $settingsStore.settings.grokHome, pick: pickGrokHome)
                }
                Toggle("扫描 OpenCode", isOn: $settingsStore.settings.scanOpenCode)
                LabeledContent("OpenCode 数据库") {
                    pathField(text: $settingsStore.settings.openCodeDatabase, pick: pickOpenCodeDatabase)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(PathDetector.existenceSummary(settings: settingsStore.settings), id: \.self) { line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(line.hasPrefix("✓") ? Color.secondary : Color.orange)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Button("自动检测本机路径") {
                        settingsStore.redetectPaths()
                        appState.refresh()
                    }
                    Button("恢复默认并检测") {
                        settingsStore.resetToDefaults()
                        appState.refresh()
                    }
                }
            }

            Section("搜索与索引") {
                Toggle("启用正文全文索引 (FTS)", isOn: $settingsStore.settings.enableFullTextSearch)
                Stepper(
                    value: $settingsStore.settings.fullTextMaxBytesPerSession,
                    in: 200_000...10_000_000,
                    step: 200_000
                ) {
                    Text("单会话索引上限: \(ByteCountFormatter.string(fromByteCount: Int64(settingsStore.settings.fullTextMaxBytesPerSession), countStyle: .file))")
                }
            }

            Section("回收站") {
                Stepper(value: $settingsStore.settings.trashRetentionDays, in: 1...90) {
                    Text("保留 \(settingsStore.settings.trashRetentionDays) 天")
                }
            }

            Section("关于") {
                LabeledContent("产品", value: "会话管家")
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")
                LabeledContent("应用数据") {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.open(AppPaths.supportRoot)
                    }
                }
                Text("会话管家不是这些工具的官方产品。它整理本机 Claude、Codex、Grok 和 OpenCode 会话。默认不发起网络请求。删除和归档只作用于 Claude，并先进入本应用回收站。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("重新扫描") {
                        appState.refresh()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 560, minHeight: 640)
    }

    private func pathField(text: Binding<String>, pick: @escaping () -> Void) -> some View {
        HStack {
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 240)
            Button("选择…", action: pick)
        }
    }

    private func pickClaudeConfig() {
        if let url = pickDirectory() {
            settingsStore.settings.claudeConfigDir = PathDetector.abbreviate(url.path)
        }
    }

    private func pickClaudeDesktop() {
        if let url = pickDirectory() {
            settingsStore.settings.claudeDesktopSupportDir = PathDetector.abbreviate(url.path)
        }
    }

    private func pickCodexHome() {
        if let url = pickDirectory() {
            settingsStore.settings.codexHome = PathDetector.abbreviate(url.path)
        }
    }

    private func pickGrokHome() {
        if let url = pickDirectory() {
            settingsStore.settings.grokHome = PathDetector.abbreviate(url.path)
        }
    }

    private func pickOpenCodeDatabase() {
        if let url = pickFile() {
            settingsStore.settings.openCodeDatabase = PathDetector.abbreviate(url.path)
        }
    }

    private func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func pickFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

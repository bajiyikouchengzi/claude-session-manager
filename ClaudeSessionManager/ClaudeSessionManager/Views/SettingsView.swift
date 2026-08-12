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
                LabeledContent("产品", value: "Claude会话管理")
                LabeledContent("版本", value: "0.1.2")
                LabeledContent("应用数据") {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.open(AppPaths.supportRoot)
                    }
                }
                Text("Claude会话管理 是非 Anthropic 官方产品，用于整理本机 Claude Desktop / Code 会话。默认不发起网络请求；删除会先进入本应用回收站。")
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
        .frame(minWidth: 560, minHeight: 480)
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

    private func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

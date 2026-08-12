import SwiftUI
import AppKit

@main
struct ClaudeSessionManagerApp: App {
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var appState: AppState
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let settings = SettingsStore()
        _settingsStore = StateObject(wrappedValue: settings)
        _appState = StateObject(wrappedValue: AppState(settingsStore: settings))
    }

    var body: some Scene {
        WindowGroup("Claude会话管理") {
            MainWindowView()
                .environmentObject(appState)
                .environmentObject(settingsStore)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    appState.isMainWindowVisible = true
                    if appState.sessions.isEmpty && !appState.isScanning {
                        appState.refresh()
                    }
                }
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("会话") {
                Button("刷新索引") { appState.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button("导出选中为 Markdown…") {
                    if let s = appState.selectedSession {
                        appState.export(sessions: [s], format: .markdown)
                    }
                }
                .disabled(appState.selectedSession == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(settingsStore)
                .frame(width: 560, height: 480)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Create a new main window if user clicks Dock icon with no windows.
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }
}

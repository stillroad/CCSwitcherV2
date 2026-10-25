import AppKit
import SwiftUI

/// Renders real settings with an empty AppState in an isolated preferences
/// domain. Never calls refresh(), starts a timer, or reads account credentials.
@main
@MainActor
enum PreviewSettings {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        UserDefaults.standard.set(true, forKey: "autoSwitchEnabled")
        UserDefaults.standard.set(90.0, forKey: "autoSwitchSessionThreshold")
        UserDefaults.standard.set(99.0, forKey: "autoSwitchWeeklyThreshold")
        let state = AppState(restoringSavedState: false)
        let updater = UpdateChecker()
        let config = MenuBarConfig.shared
        let statisticsPreview = CommandLine.arguments.contains("--local-stats")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: statisticsPreview ? 380 : 560, height: statisticsPreview ? 440 : 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CCSwitcher Personal — Settings Preview"
        if statisticsPreview {
            state.isRefreshingLocalStats = true
            state.localStatsProgress = "Reading changed log 12 of 37…"
            let stopped = AppState(restoringSavedState: false)
            stopped.localStatsMessage = LocalStatsError.timeLimit.localizedDescription
            let manual = AppState(restoringSavedState: false)
            window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
                Text("Calculating").font(.headline)
                LocalStatsStatusView().environmentObject(state)
                Divider()
                Text("Stopped").font(.headline)
                LocalStatsStatusView().environmentObject(stopped)
                Divider()
                Text("Only when requested").font(.headline)
                LocalStatsStatusView().environmentObject(manual)
            }.padding(20).frame(width: 380))
        } else {
            window.contentView = NSHostingView(rootView: SettingsView()
                .environmentObject(state).environmentObject(updater).environmentObject(config))
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

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
        UserDefaults.standard.set(90.0, forKey: "autoSwitchThreshold")
        let state = AppState(restoringSavedState: false)
        let updater = UpdateChecker()
        let config = MenuBarConfig.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CCSwitcher Personal — Settings Preview"
        window.contentView = NSHostingView(rootView: SettingsView()
            .environmentObject(state).environmentObject(updater).environmentObject(config))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

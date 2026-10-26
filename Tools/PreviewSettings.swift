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
        let rateLimitPreview = CommandLine.arguments.contains("--rate-limit")
        let rotationPreview = CommandLine.arguments.contains("--rotation")
        let compactPreview = statisticsPreview || rateLimitPreview
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: rotationPreview ? 360 : (compactPreview ? 380 : 560), height: compactPreview ? 440 : 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CCSwitcher Personal — Settings Preview"
        if rotationPreview {
            let accounts = [
                Account(email: "work@example.test", displayName: "Work", subscriptionType: "max", isActive: true),
                Account(email: "reserved@example.test", displayName: "Reserved", subscriptionType: "max", isRotationPaused: true),
                Account(email: "long.account.name@example.test", displayName: "Long account name", subscriptionType: "max")
            ]
            state.accounts = accounts
            state.activeAccount = accounts[0]
            let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            for account in accounts {
                state.accountUsage[account.id] = UsageAPIResponse(
                    fiveHour: UsageWindow(utilization: 28, resetsAt: reset),
                    sevenDay: UsageWindow(utilization: 93, resetsAt: reset),
                    sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                    sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil)
            }
            window.contentView = NSHostingView(rootView: MainMenuView()
                .environmentObject(state).environmentObject(updater).environmentObject(config))
        } else if rateLimitPreview {
            let account = Account(email: "preview@example.test", displayName: "Preview account", isActive: true)
            state.accounts = [account]
            state.activeAccount = account
            let reset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            state.accountUsage[account.id] = UsageAPIResponse(
                fiveHour: UsageWindow(utilization: 28, resetsAt: reset),
                sevenDay: UsageWindow(utilization: 98, resetsAt: reset),
                sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil)
            state.accountUsageSampledAt[account.id] = Date().addingTimeInterval(-300)
            state.accountUsageErrors[account.id] = AppState.UsageErrorState(isExpired: false, isRateLimited: true,
                message: "Usage checks paused (rate limit). Showing the last reading.")
            window.contentView = NSHostingView(rootView: UsageDashboardView()
                .environmentObject(state).environmentObject(config))
        } else if statisticsPreview {
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

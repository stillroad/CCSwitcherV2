import SwiftUI

/// Shared by the usage cards and account management list.
struct AccountRotationButton: View {
    @EnvironmentObject private var appState: AppState
    let account: Account

    var body: some View {
        Button {
            appState.setAccountRotationPaused(account, paused: !account.isRotationPaused)
        } label: {
            Label(account.isRotationPaused ? "Resume" : "Pause",
                  systemImage: account.isRotationPaused ? "play.circle" : "pause.circle")
                .font(.subheadline)
                .foregroundStyle(account.isRotationPaused ? .orange : .secondary)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Verification can still be cancelled by pausing, but once the actual
        // credential swap has started it must finish before accepting changes.
        .disabled(appState.isSwitching)
        .help(account.isRotationPaused
              ? "Resume automatic rotation. Manual switching is also available."
              : "Pause automatic rotation. Keep this account for manual switching; its current session continues.")
        .accessibilityLabel("\(account.isRotationPaused ? "Resume" : "Pause") automatic rotation for \(account.effectiveDisplayName)")
        .accessibilityValue(account.isRotationPaused ? "Paused" : "In rotation")
    }
}

import SwiftUI

/// Login health is independent of quota readings, which can remain cached long
/// after a login stopped working. Show the same status on both account screens.
struct AccountAuthStatusView: View {
    @EnvironmentObject private var appState: AppState
    let account: Account

    var body: some View {
        if let health = appState.accountAuthHealth[account.id], health.kind != .ready {
            VStack(alignment: .leading, spacing: 6) {
                Label(title(for: health), systemImage: health.needsReauthentication ? "exclamationmark.lock.fill" : "clock.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(health.needsReauthentication ? .red : .orange)
                Text(health.message)
                    .font(.caption)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if health.needsReauthentication {
                    Button("Sign in again") {
                        Task { await appState.reauthenticateAccount(account) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(appState.isLoggingIn || appState.isSwitching || appState.isLoading)
                    .help("Opens browser login and makes this account active in Claude.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background((health.needsReauthentication ? Color.red : Color.orange).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func title(for health: AccountAuthHealth) -> String {
        switch health.kind {
        case .needsReauthentication: return "Login needs attention"
        case .renewalDue: return "Access token renewal due"
        case .temporarilyUnavailable: return "Login check delayed"
        case .ready: return "Login ready"
        }
    }
}

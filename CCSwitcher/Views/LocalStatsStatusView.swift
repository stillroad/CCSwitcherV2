import SwiftUI

/// Quota usage and local analytics have separate freshness indicators.
struct LocalStatsStatusView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.isRefreshingLocalStats {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Calculating local statistics…").font(.caption)
                }
                Text("Account usage checks and switching continue.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local cost and activity").font(.caption)
                        if let date = appState.lastLocalStatsRefresh {
                            Text("Calculated \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Not calculated yet").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Calculate now") { appState.refreshLocalStats() }
                        .controlSize(.small)
                }
            }
        }
    }
}

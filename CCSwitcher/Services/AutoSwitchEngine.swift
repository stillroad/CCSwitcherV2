import Foundation

/// Pure, UI-agnostic auto-switch decision logic.
///
/// When either monitored window reaches its threshold, rank eligible accounts
/// by remaining quota or weekly reset time. AppState verifies proposals before
/// changing credentials. The optional 48-hour rule raises only the weekly limit.
enum AutoSwitchEngine {

    enum Strategy: String, CaseIterable {
        case mostRemaining
        case soonestReset
    }

    struct Policy: Equatable {
        var strategy: Strategy = .mostRemaining
        var sessionThreshold: Double = 90
        var weeklyThreshold: Double = 99
        var useNearResetThreshold = false
        /// Session headroom prevents bouncing between nearly-full sessions.
        /// Weekly eligibility uses its own limit without this extra margin.
        var hysteresis: Double = 10

        var sessionLimit: Double { Self.clamp(sessionThreshold, fallback: 90) }

        private static func clamp(_ value: Double, fallback: Double) -> Double {
            value.isFinite ? min(99, max(50, value)) : fallback
        }

        /// The 48-hour rule refers to the weekly all-model quota, not the
        /// five-hour session window. Past/unknown resets never enable it.
        func isNearWeeklyReset(_ usage: UsageAPIResponse?, asOf now: Date) -> Bool {
            guard useNearResetThreshold, let reset = usage?.sevenDay?.resetsAtDate else { return false }
            let remaining = reset.timeIntervalSince(now)
            return remaining > 0 && remaining <= 48 * 60 * 60
        }

        func weeklyLimit(for usage: UsageAPIResponse?, asOf now: Date) -> Double {
            isNearWeeklyReset(usage, asOf: now) ? 99 : Self.clamp(weeklyThreshold, fallback: 99)
        }

        /// Percentage points remaining until either independently configured
        /// trigger. Expired windows cannot trigger a switch or faster polling.
        func headroom(_ usage: UsageAPIResponse?, asOf now: Date,
                      requireKnownWindow: Bool = false) -> Double? {
            guard let usage else { return nil }
            let session = AutoSwitchEngine.utilization(usage.fiveHour, asOf: now, requireKnownWindow: requireKnownWindow)
            let weekly = AutoSwitchEngine.utilization(usage.sevenDay, asOf: now, requireKnownWindow: requireKnownWindow)
            return [session.map { sessionLimit - $0 },
                    weekly.map { weeklyLimit(for: usage, asOf: now) - $0 }]
                .compactMap { $0 }.min()
        }

        func shouldSwitch(_ usage: UsageAPIResponse?, asOf now: Date,
                          requireKnownWindow: Bool = false) -> Bool {
            headroom(usage, asOf: now, requireKnownWindow: requireKnownWindow).map { $0 <= 0 } ?? false
        }

        func canSelect(_ usage: UsageAPIResponse?, asOf now: Date) -> Bool {
            guard let usage else { return false }
            let session = AutoSwitchEngine.utilization(usage.fiveHour, asOf: now)
            let weekly = AutoSwitchEngine.utilization(usage.sevenDay, asOf: now)
            guard session != nil || weekly != nil else { return false }
            let sessionMargin = hysteresis.isFinite ? max(1, hysteresis) : 10
            // A 93%-weekly account with an empty session is usable at 90/99.
            // Applying the session's ten-point margin to weekly usage would
            // wrongly exclude it. Weekly usage must simply remain below its limit.
            return (session.map { $0 <= sessionLimit - sessionMargin } ?? true)
                && (weekly.map { $0 < weeklyLimit(for: usage, asOf: now) } ?? true)
        }
    }

    /// A fresh reading at either configured limit overrides the grace period.
    /// Otherwise a fast session could hit 90% just after switching and be held
    /// until 99% by the old cooldown rule. Stale data cannot bypass cooldown.
    static func isCoolingDown(lastSwitch: Date?, cooldown: TimeInterval,
                              activeUsage: UsageAPIResponse?, activeSampleIsFresh: Bool,
                              policy: Policy,
                              asOf now: Date) -> Bool {
        guard let lastSwitch, now.timeIntervalSince(lastSwitch) < cooldown else { return false }
        if activeSampleIsFresh, policy.shouldSwitch(activeUsage, asOf: now) {
            return false
        }
        return true
    }

    /// The binding utilization for an account = max of the windows we watch.
    /// We watch the 5-hour (session) and 7-day (weekly-all) windows — the two
    /// that the `/api/oauth/usage` endpoint still populates as top-level fields.
    ///
    /// A window reading whose `resets_at` lies in the past is discarded: accounts
    /// are polled round-robin, so a retained sample can outlive the window it
    /// described — the quota it reports as consumed no longer exists. Within an
    /// unexpired window, consumption only grows, so an unexpired reading is a
    /// valid lower bound even when it is several cycles old.
    ///
    /// `requireKnownWindow` controls what happens when `resets_at` is absent or
    /// unparseable (API omission, format change). Lenient (default) keeps the
    /// reading — right for candidates, where a stale-high reading merely
    /// excludes them and anything chosen is re-verified with a fresh fetch.
    /// Strict discards it — required for the ACTIVE side, where a retained
    /// high reading with no known expiry could otherwise TRIGGER a switch
    /// long after the real window reset.
    ///
    /// Returns nil when no usable reading exists for the account.
    static func bindingUtilization(
        _ usage: UsageAPIResponse?,
        asOf now: Date = Date(),
        requireKnownWindow: Bool = false
    ) -> Double? {
        guard let usage else { return nil }
        return [usage.fiveHour, usage.sevenDay]
            .compactMap { utilization($0, asOf: now, requireKnownWindow: requireKnownWindow) }
            .max()
    }

    private static func utilization(_ window: UsageWindow?, asOf now: Date,
                                    requireKnownWindow: Bool = false) -> Double? {
        guard let window, let value = window.utilization, value.isFinite, value >= 0 else { return nil }
        guard let reset = window.resetsAtDate else { return requireKnownWindow ? nil : value }
        return reset <= now ? nil : value
    }

    /// Rank the accounts worth switching to, best first (most headroom).
    ///
    /// The result is a list of *proposals*, not decisions: it is computed from
    /// whatever samples the caller happens to hold, which round-robin polling can
    /// leave several cycles old. `AppState` verifies a candidate's usage before
    /// committing to a switch, and falls through the list when one fails.
    ///
    /// - Parameters:
    ///   - active: the currently active account.
    ///   - candidates: every other account (already filtered to the same provider).
    ///   - usageByAccount: latest usage sample per account id.
    ///   - isSwitchable: whether an account can actually be switched to right now
    ///     (has a stored backup token and isn't flagged expired).
    ///   - activeSampledThisCycle: whether the active account's sample was taken
    ///     by the refresh cycle that is asking. Fresh readings are trusted even
    ///     without a parseable `resets_at` (the number is current by
    ///     construction); only RETAINED readings need the strict expiry check,
    ///     because they are the ones that can describe a window that has since
    ///     reset.
    ///   - policy: independent session/weekly thresholds and selection strategy.
    ///   - now: injected clock, for window-expiry checks and testability.
    /// - Returns: eligible accounts ordered best-first; empty means stay put.
    static func rankedTargets(
        active: Account,
        candidates: [Account],
        usageByAccount: [UUID: UsageAPIResponse],
        isSwitchable: (Account) -> Bool,
        activeSampledThisCycle: Bool,
        policy: Policy,
        asOf now: Date = Date()
    ) -> [Account] {
        // 1) Only act once the active account has reached the threshold on a
        //    window we watch. Unknown active usage -> do nothing (can't decide).
        //    The trigger to move the user off an account must never rest on a
        //    RETAINED reading whose expiry we cannot establish — but a reading
        //    this very cycle fetched is current whether or not the endpoint
        //    sent a parseable resets_at.
        guard policy.shouldSwitch(usageByAccount[active.id], asOf: now, requireKnownWindow: !activeSampledThisCycle) else {
            return []
        }

        // 2) Keep only switchable candidates KNOWN to sit safely below the
        //    threshold. A candidate with no usable reading is NOT eligible:
        //    accounts are polled round-robin, so "no sample" usually means "not
        //    reached yet" rather than "idle" — treating it as a failover fallback
        //    let an automatic switch land on an account that was itself maxed
        //    out, which is the exact failure this feature exists to prevent.
        return candidates
            .compactMap { candidate -> (account: Account, utilization: Double, reset: Date)? in
                let usage = usageByAccount[candidate.id]
                guard candidate.id != active.id, candidate.provider == active.provider,
                      let util = bindingUtilization(usageByAccount[candidate.id], asOf: now),
                      policy.canSelect(usage, asOf: now),
                      isSwitchable(candidate) else { return nil }
                let reset = usage?.sevenDay?.resetsAtDate
                return (candidate, util, reset.flatMap { $0 > now ? $0 : nil } ?? .distantFuture)
            }
            .sorted {
                if policy.strategy == .soonestReset, $0.reset != $1.reset { return $0.reset < $1.reset }
                if $0.utilization != $1.utilization { return $0.utilization < $1.utilization }
                return $0.account.id.uuidString < $1.account.id.uuidString
            }
            .map(\.account)
    }
}

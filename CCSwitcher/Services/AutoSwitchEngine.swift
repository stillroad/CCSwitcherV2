import Foundation

/// Pure, UI-agnostic auto-switch decision logic.
///
/// When either monitored window reaches its threshold, rank eligible accounts
/// by remaining quota or weekly reset time. AppState verifies proposals before
/// changing credentials. The optional 48-hour rule raises both windows to 99%.
enum AutoSwitchEngine {

    enum Strategy: String, CaseIterable {
        case mostRemaining
        case soonestReset
    }

    struct Policy: Equatable {
        var strategy: Strategy = .mostRemaining
        var normalThreshold: Double = 90
        var useNearResetThreshold = false
        var hysteresis: Double = 10

        /// The 48-hour rule refers to the weekly all-model quota, not the
        /// five-hour session window. Past/unknown resets never enable it.
        func isNearWeeklyReset(_ usage: UsageAPIResponse?, asOf now: Date) -> Bool {
            guard useNearResetThreshold, let reset = usage?.sevenDay?.resetsAtDate else { return false }
            let remaining = reset.timeIntervalSince(now)
            return remaining > 0 && remaining <= 48 * 60 * 60
        }

        func threshold(for usage: UsageAPIResponse?, asOf now: Date) -> Double {
            isNearWeeklyReset(usage, asOf: now) ? 99 : min(99, max(50, normalThreshold))
        }

        func candidateCeiling(for usage: UsageAPIResponse?, asOf now: Date) -> Double {
            // Let near-reset accounts with 90–98% usage be used up too. Keeping
            // the normal 10-point margin here would strand their last quota.
            let margin = isNearWeeklyReset(usage, asOf: now) ? 1 : max(1, hysteresis)
            return threshold(for: usage, asOf: now) - margin
        }
    }

    /// A deliberate switch gets a grace period, unless a FRESH sample says
    /// the new account is already at 99%. Stale data must not bypass cooldown.
    static func isCoolingDown(lastSwitch: Date?, cooldown: TimeInterval,
                              activeUsage: UsageAPIResponse?, activeSampleIsFresh: Bool,
                              asOf now: Date) -> Bool {
        guard let lastSwitch, now.timeIntervalSince(lastSwitch) < cooldown else { return false }
        if activeSampleIsFresh, let utilization = bindingUtilization(activeUsage, asOf: now), utilization >= 99 {
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
            .compactMap { window -> Double? in
                guard let window, let util = window.utilization,
                      util.isFinite, util >= 0 else { return nil }
                guard let resets = window.resetsAtDate else {
                    return requireKnownWindow ? nil : util
                }
                return resets <= now ? nil : util
            }
            .max()
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
    ///   - threshold: switch when the active binding utilization is >= this (e.g. 90).
    ///   - hysteresisPct: a candidate must sit at least this far below the threshold
    ///     to be eligible (e.g. 10 -> candidate must be <= threshold - 10).
    ///   - now: injected clock, for window-expiry checks and testability.
    /// - Returns: eligible accounts ordered best-first; empty means stay put.
    static func rankedTargets(
        active: Account,
        candidates: [Account],
        usageByAccount: [UUID: UsageAPIResponse],
        isSwitchable: (Account) -> Bool,
        activeSampledThisCycle: Bool,
        threshold: Double,
        hysteresisPct: Double,
        strategy: Strategy = .mostRemaining,
        useNearResetThreshold: Bool = false,
        asOf now: Date = Date()
    ) -> [Account] {
        let policy = Policy(strategy: strategy, normalThreshold: threshold,
                            useNearResetThreshold: useNearResetThreshold, hysteresis: hysteresisPct)
        // 1) Only act once the active account has reached the threshold on a
        //    window we watch. Unknown active usage -> do nothing (can't decide).
        //    The trigger to move the user off an account must never rest on a
        //    RETAINED reading whose expiry we cannot establish — but a reading
        //    this very cycle fetched is current whether or not the endpoint
        //    sent a parseable resets_at.
        guard let activeUtil = bindingUtilization(usageByAccount[active.id], asOf: now, requireKnownWindow: !activeSampledThisCycle),
              activeUtil >= policy.threshold(for: usageByAccount[active.id], asOf: now) else {
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
                guard candidate.id != active.id, candidate.provider == active.provider, isSwitchable(candidate),
                      let util = bindingUtilization(usageByAccount[candidate.id], asOf: now),
                      util <= policy.candidateCeiling(for: usage, asOf: now) else { return nil }
                let reset = usage?.sevenDay?.resetsAtDate
                return (candidate, util, reset.flatMap { $0 > now ? $0 : nil } ?? .distantFuture)
            }
            .sorted {
                if strategy == .soonestReset, $0.reset != $1.reset { return $0.reset < $1.reset }
                if $0.utilization != $1.utilization { return $0.utilization < $1.utilization }
                return $0.account.id.uuidString < $1.account.id.uuidString
            }
            .map(\.account)
    }
}

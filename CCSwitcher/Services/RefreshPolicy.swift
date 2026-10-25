import Foundation

/// Scheduling decisions kept independent of timers, networking and credentials.
enum RefreshPolicy {
    static let defaultInactiveInterval: TimeInterval = 60 * 60

    /// Retry-After can be a delay in seconds or an HTTP date.
    static func retryAfter(_ value: String?, asOf now: Date) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: trimmed).map { max(0, $0.timeIntervalSince(now)) }
    }

    static func isDue(lastAttempt: Date?, interval: TimeInterval, asOf now: Date) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= interval
    }

    static func isFreshSample(_ sample: Date?, cycleStart: Date, asOf now: Date) -> Bool {
        guard let sample else { return false }
        return sample >= cycleStart && now.timeIntervalSince(sample) <= 30 && sample <= now
    }

    /// Usage never silently accelerates polling. Sustained fast polling can
    /// exhaust the usage endpoint's own quota precisely when readings matter.
    static func activeInterval(configured: TimeInterval) -> TimeInterval {
        configured.isFinite ? max(15, configured) : 300
    }

    /// Schedule directly from the latest cycle/request, not on a separate
    /// 15-second grid that rounds every request up to the following tick.
    static func nextAutomaticRefresh(lastIdentityAttempt: Date?, lastUsageAttempt: Date?,
                                     configured: TimeInterval, asOf now: Date) -> Date {
        let anchor = [lastIdentityAttempt, lastUsageAttempt].compactMap { $0 }.max() ?? now
        return max(now, anchor.addingTimeInterval(activeInterval(configured: configured)))
    }

    /// A zero/missing Retry-After is not permission to keep trying every minute.
    /// Back off 5, 10, 20, then 30 minutes; longer settings/server delays win.
    static func rateLimitDelay(consecutiveFailures: Int, configured: TimeInterval,
                               retryAfter: TimeInterval?) -> TimeInterval {
        let exponent = min(3, max(0, consecutiveFailures - 1))
        let backoff = min(1800, 300 * pow(2, Double(exponent)))
        let serverDelay = retryAfter.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        return max(activeInterval(configured: configured), backoff, serverDelay)
    }

    /// At most one inactive account per automatic cycle, oldest attempt first.
    /// Failed requests also advance the schedule so a broken account cannot
    /// monopolize polling. Server Retry-After always takes precedence.
    static func usageTargets(
        accounts: [Account],
        activeID: UUID?,
        lastAttempt: [UUID: Date],
        retryNotBefore: [UUID: Date],
        inactiveInterval: TimeInterval,
        refreshAll: Bool,
        usageByAccount: [UUID: UsageAPIResponse] = [:],
        asOf now: Date
    ) -> [Account] {
        let eligible = accounts.filter { (retryNotBefore[$0.id] ?? .distantPast) <= now }
        let active = eligible.filter { $0.id == activeID }
        let inactive = eligible.filter { $0.id != activeID }.sorted {
            let lhs = lastAttempt[$0.id] ?? .distantPast
            let rhs = lastAttempt[$1.id] ?? .distantPast
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
        }
        if refreshAll { return active + inactive }
        return active + inactive.filter {
            isDue(lastAttempt: lastAttempt[$0.id], interval: max(300, inactiveInterval), asOf: now)
                || resetHasPassed(usageByAccount[$0.id], since: lastAttempt[$0.id], asOf: now)
        }.prefix(1)
    }

    /// Recheck once after a known quota reset, even if the hourly deadline is
    /// later. Otherwise a cached 100% reading can hide a now-usable account.
    private static func resetHasPassed(_ usage: UsageAPIResponse?, since attempt: Date?, asOf now: Date) -> Bool {
        guard let usage, let attempt else { return false }
        return [usage.fiveHour, usage.sevenDay].contains {
            guard let reset = $0?.resetsAtDate else { return false }
            return reset > attempt && reset <= now
        }
    }

    /// Zero means on demand. Manual usage refreshes never force a log scan.
    static func localStatsDue(lastRefresh: Date?, interval: TimeInterval, asOf now: Date) -> Bool {
        interval > 0 && isDue(lastAttempt: lastRefresh, interval: max(900, interval), asOf: now)
    }
}

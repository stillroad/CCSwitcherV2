import XCTest
@testable import CCSwitcherPolicy

final class RefreshPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let active = Account(email: "active@example.test", displayName: "Active", isActive: true)
    let idle = Account(email: "idle@example.test", displayName: "Idle")

    func targets(attempts: [UUID: Date] = [:], retry: [UUID: Date] = [:], all: Bool = false) -> [UUID] {
        RefreshPolicy.usageTargets(accounts: [idle, active], activeID: active.id, lastAttempt: attempts,
                                   retryNotBefore: retry, inactiveInterval: 3600, refreshAll: all, asOf: now).map(\.id)
    }

    func testActiveRefreshesWhileRecentInactiveAccountIsSkipped() {
        XCTAssertEqual(targets(attempts: [idle.id: now.addingTimeInterval(-300)]), [active.id])
    }

    func testInactiveBecomesDueAtOneHour() {
        XCTAssertEqual(targets(attempts: [idle.id: now.addingTimeInterval(-3600)]), [active.id, idle.id])
    }

    func testManualRefreshIncludesRecentInactiveAccounts() {
        XCTAssertEqual(targets(attempts: [idle.id: now], all: true), [active.id, idle.id])
    }

    func testServerBackoffAppliesEvenToManualRefresh() {
        XCTAssertEqual(targets(retry: [idle.id: now.addingTimeInterval(7200)], all: true), [active.id])
        XCTAssertEqual(targets(retry: [active.id: now.addingTimeInterval(60)], all: true), [idle.id])
        XCTAssertEqual(targets(retry: [idle.id: now], all: true), [active.id, idle.id])
    }

    func testRetryAfterParsesSecondsAndHTTPDates() {
        XCTAssertEqual(RefreshPolicy.retryAfter("7200", asOf: now), 7200)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: now.addingTimeInterval(7200))
        XCTAssertEqual(RefreshPolicy.retryAfter(header, asOf: now), 7200)
        XCTAssertNil(RefreshPolicy.retryAfter("nan", asOf: now))
        XCTAssertNil(RefreshPolicy.retryAfter("infinity", asOf: now))
        XCTAssertNil(RefreshPolicy.retryAfter("invalid", asOf: now))
        XCTAssertEqual(RefreshPolicy.retryAfter("-1", asOf: now), 0)
    }

    func testLongSweepDoesNotTreatOldSamplesAsFresh() {
        XCTAssertTrue(RefreshPolicy.isFreshSample(now.addingTimeInterval(-20), cycleStart: now.addingTimeInterval(-120), asOf: now))
        XCTAssertFalse(RefreshPolicy.isFreshSample(now.addingTimeInterval(-40), cycleStart: now.addingTimeInterval(-120), asOf: now))
        XCTAssertFalse(RefreshPolicy.isFreshSample(now.addingTimeInterval(-20), cycleStart: now.addingTimeInterval(-10), asOf: now))
    }

    func testNineAccountsAreStaggeredFairly() {
        let others = (0..<8).map { Account(email: "idle\($0)@example.test", displayName: "Idle \($0)") }
        var attempts: [UUID: Date] = [:]
        var visited = Set<UUID>()
        for tick in 0..<8 {
            let time = now.addingTimeInterval(Double(tick) * 300)
            let targets = RefreshPolicy.usageTargets(accounts: others + [active], activeID: active.id,
                                                     lastAttempt: attempts, retryNotBefore: [:],
                                                     inactiveInterval: 3600, refreshAll: false, asOf: time)
            XCTAssertEqual(targets.count, 2)
            XCTAssertEqual(targets.first?.id, active.id)
            let inactive = targets[1]
            XCTAssertTrue(visited.insert(inactive.id).inserted)
            // Also models a FAILED attempt: it must not starve the other seven.
            attempts[inactive.id] = time
        }
        XCTAssertEqual(visited.count, 8)
        let next = RefreshPolicy.usageTargets(accounts: others + [active], activeID: active.id,
                                             lastAttempt: attempts, retryNotBefore: [:],
                                             inactiveInterval: 3600, refreshAll: false, asOf: now.addingTimeInterval(2400))
        XCTAssertEqual(next.map(\.id), [active.id])
    }

    func testSwitchedActiveAccountIsNeverHeldToInactiveCadence() {
        let result = RefreshPolicy.usageTargets(accounts: [active, idle], activeID: idle.id,
                                               lastAttempt: [idle.id: now, active.id: now], retryNotBefore: [:],
                                               inactiveInterval: 3600, refreshAll: false, asOf: now)
        XCTAssertEqual(result.map(\.id), [idle.id])
    }

    func testKnownResetWakesAnInactiveAccountOnce() {
        let fixtures = AutoSwitchTests()
        let stale = fixtures.usage(100, 20, sessionReset: -10)
        func due(lastAttempt: Date) -> [UUID] {
            RefreshPolicy.usageTargets(accounts: [active, idle], activeID: active.id,
                                       lastAttempt: [idle.id: lastAttempt], retryNotBefore: [:],
                                       inactiveInterval: 3600, refreshAll: false,
                                       usageByAccount: [idle.id: stale], asOf: now).map(\.id)
        }
        XCTAssertEqual(due(lastAttempt: now.addingTimeInterval(-300)), [active.id, idle.id])
        XCTAssertEqual(due(lastAttempt: now.addingTimeInterval(-5)), [active.id])
    }

    func testActivePollingAcceleratesOnlyNearItsEffectiveThreshold() {
        let fixtures = AutoSwitchTests()
        let policy = AutoSwitchEngine.Policy(useNearResetThreshold: true)
        for (percent, expected) in [(88.0, 300.0), (89, 60), (96.9, 60), (97, 15), (99, 15)] {
            XCTAssertEqual(RefreshPolicy.activeInterval(configured: 300, usage: fixtures.usage(percent, 10),
                                                       autoSwitchEnabled: true, policy: policy, asOf: now), expected)
        }
        XCTAssertEqual(RefreshPolicy.activeInterval(configured: 300, usage: fixtures.usage(99, 10),
                                                   autoSwitchEnabled: false, policy: policy, asOf: now), 300)
        XCTAssertEqual(RefreshPolicy.activeInterval(configured: 15, usage: fixtures.usage(20, 10),
                                                   autoSwitchEnabled: true, policy: policy, asOf: now), 15)
    }

    func testLocalStatisticsDailyCadenceAndManualOnlyOption() {
        XCTAssertTrue(RefreshPolicy.localStatsDue(lastRefresh: nil, interval: 86_400, asOf: now))
        XCTAssertFalse(RefreshPolicy.localStatsDue(lastRefresh: now.addingTimeInterval(-300), interval: 86_400, asOf: now))
        XCTAssertTrue(RefreshPolicy.localStatsDue(lastRefresh: now.addingTimeInterval(-86_400), interval: 86_400, asOf: now))
        XCTAssertFalse(RefreshPolicy.localStatsDue(lastRefresh: nil, interval: 0, asOf: now))
    }

    func testSmallStatisticsSnapshotSurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stats.json")
        XCTAssertNil(LocalStatsSnapshot.load(from: url))
        let original = LocalStatsSnapshot(updatedAt: now, cost: CostSummary(todayCost: 12.5, dailyCosts: []),
                                          activity: ActivityStats(conversationTurns: 23))
        original.save(to: url)
        let restored = try XCTUnwrap(LocalStatsSnapshot.load(from: url))
        XCTAssertEqual(restored.updatedAt, now)
        XCTAssertEqual(restored.cost.todayCost, 12.5)
        XCTAssertEqual(restored.activity.conversationTurns, 23)
        XCTAssertFalse(RefreshPolicy.localStatsDue(lastRefresh: restored.updatedAt, interval: 86_400,
                                                  asOf: now.addingTimeInterval(300)))
        try Data("broken".utf8).write(to: url)
        XCTAssertNil(LocalStatsSnapshot.load(from: url))
    }
}

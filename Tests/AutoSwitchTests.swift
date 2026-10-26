import XCTest
@testable import CCSwitcherPolicy

final class AutoSwitchTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let active = Account(email: "active@example.test", displayName: "Active", isActive: true)
    let soon = Account(email: "soon@example.test", displayName: "Soon")
    let later = Account(email: "later@example.test", displayName: "Later")

    func window(_ percent: Double, after seconds: Double?) -> UsageWindow {
        UsageWindow(utilization: percent, resetsAt: seconds.map {
            ISO8601DateFormatter().string(from: now.addingTimeInterval($0))
        })
    }

    func usage(_ session: Double, _ weekly: Double, reset: Double? = 86_400,
               sessionReset: Double? = 3600) -> UsageAPIResponse {
        UsageAPIResponse(fiveHour: window(session, after: sessionReset), sevenDay: window(weekly, after: reset),
                         sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                         sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil)
    }

    func ranked(activeUsage: UsageAPIResponse, first: UsageAPIResponse, second: UsageAPIResponse,
                strategy: AutoSwitchEngine.Strategy = .soonestReset, nearReset: Bool = true,
                fresh: Bool = true, sessionThreshold: Double = 90, weeklyThreshold: Double = 99) -> [UUID] {
        AutoSwitchEngine.rankedTargets(
            active: active, candidates: [later, soon],
            usageByAccount: [active.id: activeUsage, soon.id: first, later.id: second],
            isSwitchable: { _ in true }, activeSampledThisCycle: fresh,
            policy: .init(strategy: strategy, sessionThreshold: sessionThreshold, weeklyThreshold: weeklyThreshold,
                          useNearResetThreshold: nearReset),
            asOf: now
        ).map(\.id)
    }

    func testSoonestResetWinsOverMostRemainingQuota() {
        XCTAssertEqual(ranked(activeUsage: usage(99, 20), first: usage(70, 96),
                              second: usage(10, 10, reset: 4 * 86_400)), [soon.id, later.id])
    }

    func testOriginalMostRemainingModeIsStillAvailable() {
        XCTAssertEqual(ranked(activeUsage: usage(99, 20), first: usage(70, 96),
                              second: usage(10, 10, reset: 4 * 86_400), strategy: .mostRemaining), [later.id, soon.id])
    }

    func testNearResetRaisesOnlyWeeklyThreshold() {
        for nearUsage in [usage(89.9, 20), usage(10, 98.9)] {
            XCTAssertTrue(ranked(activeUsage: nearUsage, first: usage(10, 20), second: usage(20, 30), weeklyThreshold: 90).isEmpty)
        }
        for atLimit in [usage(90, 20), usage(10, 99), usage(100, 20)] {
            XCTAssertFalse(ranked(activeUsage: atLimit, first: usage(10, 20), second: usage(20, 30), weeklyThreshold: 90).isEmpty)
        }
    }

    func testNormalThresholdOutsideLast48Hours() {
        XCTAssertFalse(ranked(activeUsage: usage(90, 10, reset: 172_801),
                              first: usage(10, 20), second: usage(20, 30)).isEmpty)
        XCTAssertTrue(ranked(activeUsage: usage(89.9, 10, reset: 172_801),
                             first: usage(10, 20), second: usage(20, 30)).isEmpty)
    }

    func test48HourBoundaryAndInvalidResetDates() {
        let policy = AutoSwitchEngine.Policy(weeklyThreshold: 90, useNearResetThreshold: true)
        XCTAssertEqual(policy.weeklyLimit(for: usage(90, 10, reset: 172_800), asOf: now), 99)
        XCTAssertEqual(policy.weeklyLimit(for: usage(90, 10, reset: 172_801), asOf: now), 90)
        XCTAssertEqual(policy.sessionLimit, 90)
        for reset in [nil, 0.0, -1.0] as [Double?] {
            XCTAssertEqual(policy.weeklyLimit(for: usage(90, 10, reset: reset), asOf: now), 90)
        }
        let malformed = UsageAPIResponse(fiveHour: nil, sevenDay: UsageWindow(utilization: 95, resetsAt: "bad-date"),
                                        sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                                        sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil)
        XCTAssertEqual(policy.weeklyLimit(for: malformed, asOf: now), 90)
    }

    func testNearResetOverrideCanBeDisabled() {
        XCTAssertFalse(ranked(activeUsage: usage(10, 90), first: usage(10, 20),
                              second: usage(20, 30), nearReset: false, weeklyThreshold: 90).isEmpty)
        XCTAssertTrue(ranked(activeUsage: usage(10, 90), first: usage(10, 20),
                             second: usage(20, 30), weeklyThreshold: 90).isEmpty)
    }

    func testWeeklyCandidateCanBeBelow99WithoutDiscardingTheLastTenPercent() {
        XCTAssertEqual(ranked(activeUsage: usage(90, 20), first: usage(0, 98.9), second: usage(0, 99)), [soon.id])
        // The screenshot's 90–93% weekly readings are eligible even far from reset.
        XCTAssertEqual(ranked(activeUsage: usage(90, 95, reset: 5 * 86_400),
                              first: usage(0, 93, reset: 3 * 86_400),
                              second: usage(0, 90, reset: 4 * 86_400)), [soon.id, later.id])
    }

    func testBothCandidateWindowsMustHaveHeadroom() {
        XCTAssertTrue(ranked(activeUsage: usage(99, 20), first: usage(100, 0), second: usage(0, 100)).isEmpty)
    }

    func testTenPointCandidateMarginAppliesOnlyToSessions() {
        XCTAssertEqual(ranked(activeUsage: usage(90, 20), first: usage(80, 95),
                              second: usage(80.1, 20), nearReset: false), [soon.id])
        XCTAssertEqual(ranked(activeUsage: usage(90, 20), first: usage(80, 98),
                              second: usage(80.1, 20)), [soon.id])
    }

    func testUnknownWeeklyResetSortsLast() {
        XCTAssertEqual(ranked(activeUsage: usage(99, 20), first: usage(50, 60),
                              second: usage(0, 0, reset: nil)), [soon.id, later.id])
    }

    func testPastResetIsNotTreatedAsSoonestUpcoming() {
        XCTAssertEqual(ranked(activeUsage: usage(99, 20), first: usage(50, 60),
                              second: usage(0, 100, reset: -1)), [soon.id, later.id])
    }

    func testExpiredActiveWindowDoesNotTriggerSwitch() {
        for reset in [-1.0, 0.0] {
            XCTAssertTrue(ranked(activeUsage: usage(100, 100, reset: reset, sessionReset: reset),
                                 first: usage(10, 20), second: usage(20, 30)).isEmpty)
        }
    }

    func testStaleActiveWithoutResetCannotTriggerSwitch() {
        let reading = usage(99, 99, reset: nil, sessionReset: nil)
        XCTAssertTrue(ranked(activeUsage: reading, first: usage(10, 20), second: usage(20, 30), fresh: false).isEmpty)
        XCTAssertFalse(ranked(activeUsage: reading, first: usage(10, 20), second: usage(20, 30), fresh: true).isEmpty)
    }

    func testOtherProvidersUnavailableAndUnsampledAccountsAreExcluded() {
        var otherProvider = later
        otherProvider.provider = .gemini
        let noSample = Account(email: "unknown@example.test", displayName: "Unknown")
        let ranked = AutoSwitchEngine.rankedTargets(
            active: active, candidates: [active, soon, otherProvider, noSample],
            usageByAccount: [active.id: usage(99, 20), soon.id: usage(10, 10), otherProvider.id: usage(0, 0)],
            isSwitchable: { $0.id != self.soon.id }, activeSampledThisCycle: true,
            policy: .init(), asOf: now
        )
        XCTAssertTrue(ranked.isEmpty)
    }

    func testPausedAccountsAreExcludedByBothStrategiesAndRateLimitFallback() {
        var paused = soon
        paused.isRotationPaused = true
        for strategy in [AutoSwitchEngine.Strategy.mostRemaining, .soonestReset] {
            for rateLimited in [false, true] {
                let targets = AutoSwitchEngine.rankedTargets(
                    active: active, candidates: [paused, later],
                    usageByAccount: [active.id: usage(rateLimited ? 88 : 90, 10),
                                     paused.id: usage(0, 0), later.id: usage(30, 50, reset: 3 * 86_400)],
                    isSwitchable: { _ in true }, activeSampledThisCycle: !rateLimited,
                    policy: .init(strategy: strategy), activeUsageIsRateLimited: rateLimited, asOf: now)
                XCTAssertEqual(targets.map(\.id), [later.id])
            }
        }
    }

    func testPausingActiveAccountStillAllowsAutomaticSwitchingAway() {
        var pausedActive = active
        pausedActive.isRotationPaused = true
        let targets = AutoSwitchEngine.rankedTargets(
            active: pausedActive, candidates: [soon],
            usageByAccount: [active.id: usage(90, 10), soon.id: usage(0, 20)],
            isSwitchable: { _ in true }, activeSampledThisCycle: true, policy: .init(), asOf: now)
        XCTAssertEqual(targets.map(\.id), [soon.id])
    }

    func testMalformedUtilizationDoesNotBecomeAnEmptyAccount() {
        XCTAssertNil(AutoSwitchEngine.bindingUtilization(usage(.nan, -1), asOf: now))
        XCTAssertNil(AutoSwitchEngine.bindingUtilization(usage(.infinity, -10), asOf: now))
    }

    func testRateLimitFallbackRequiresKnownUnexpiredWindowWithinTwoPoints() {
        let policy = AutoSwitchEngine.Policy()
        XCTAssertTrue(policy.shouldSwitchAfterRateLimit(usage(88, 10), asOf: now))
        XCTAssertTrue(policy.shouldSwitchAfterRateLimit(usage(10, 97), asOf: now))
        XCTAssertFalse(policy.shouldSwitchAfterRateLimit(usage(87.9, 96.9), asOf: now))
        XCTAssertFalse(policy.shouldSwitchAfterRateLimit(usage(99, 99, reset: -1, sessionReset: -1), asOf: now))
        XCTAssertFalse(policy.shouldSwitchAfterRateLimit(usage(99, 99, reset: nil, sessionReset: nil), asOf: now))
        XCTAssertFalse(policy.shouldSwitchAfterRateLimit(nil, asOf: now))
    }

    func testRateLimitFallbackUsesIndependentLimitsAndWeeklyOnlyOverride() {
        let policy = AutoSwitchEngine.Policy(sessionThreshold: 75, weeklyThreshold: 90, useNearResetThreshold: true)
        XCTAssertTrue(policy.shouldSwitchAfterRateLimit(usage(73, 10), asOf: now))
        XCTAssertFalse(policy.shouldSwitchAfterRateLimit(usage(72.9, 96.9), asOf: now))
        XCTAssertTrue(policy.shouldSwitchAfterRateLimit(usage(10, 88, reset: 3 * 86_400), asOf: now))
        XCTAssertFalse(policy.shouldSwitchAfterRateLimit(usage(10, 88, reset: 86_400), asOf: now))
    }

    func testDeterministicTieBreak() {
        let expected = [soon.id, later.id].sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(ranked(activeUsage: usage(99, 20), first: usage(20, 20), second: usage(20, 20)), expected)
    }

    func testFreshEmergencyUsageBypassesCooldown() {
        XCTAssertFalse(AutoSwitchEngine.isCoolingDown(lastSwitch: now.addingTimeInterval(-10), cooldown: 300,
                                                      activeUsage: usage(99, 20), activeSampleIsFresh: true, policy: .init(), asOf: now))
        XCTAssertTrue(AutoSwitchEngine.isCoolingDown(lastSwitch: now.addingTimeInterval(-10), cooldown: 300,
                                                     activeUsage: usage(99, 20), activeSampleIsFresh: false, policy: .init(), asOf: now))
        XCTAssertTrue(AutoSwitchEngine.isCoolingDown(lastSwitch: now.addingTimeInterval(-10), cooldown: 300,
                                                     activeUsage: usage(89, 20), activeSampleIsFresh: true, policy: .init(), asOf: now))
        XCTAssertFalse(AutoSwitchEngine.isCoolingDown(lastSwitch: now.addingTimeInterval(-300), cooldown: 300,
                                                      activeUsage: usage(90, 20), activeSampleIsFresh: true, policy: .init(), asOf: now))
    }

    func testSessionAndWeeklyTriggersAreIndependentAtTheirExactBoundaries() {
        let policy = AutoSwitchEngine.Policy()
        XCTAssertFalse(policy.shouldSwitch(usage(89.9, 98.9), asOf: now))
        XCTAssertTrue(policy.shouldSwitch(usage(90, 20), asOf: now))
        XCTAssertTrue(policy.shouldSwitch(usage(0, 99), asOf: now))
        let custom = AutoSwitchEngine.Policy(sessionThreshold: 75, weeklyThreshold: 95)
        XCTAssertFalse(custom.shouldSwitch(usage(74.9, 94.9), asOf: now))
        XCTAssertTrue(custom.shouldSwitch(usage(75, 20), asOf: now))
        XCTAssertTrue(custom.shouldSwitch(usage(0, 95), asOf: now))
        XCTAssertTrue(custom.canSelect(usage(0, 94.9), asOf: now))
        XCTAssertFalse(custom.canSelect(usage(0, 95), asOf: now))
    }

    func testWeeklyThresholdStillAppliesWhenTheSessionHasReset() {
        let policy = AutoSwitchEngine.Policy()
        XCTAssertFalse(policy.canSelect(usage(100, 99, sessionReset: -1), asOf: now))
        XCTAssertTrue(policy.canSelect(usage(100, 98, sessionReset: -1), asOf: now))
        XCTAssertTrue(policy.shouldSwitch(usage(100, 99, sessionReset: -1), asOf: now))
    }

    func testFreshConfiguredThresholdBypassesCooldownBefore99Percent() {
        for reading in [usage(90, 20), usage(0, 99)] {
            XCTAssertFalse(AutoSwitchEngine.isCoolingDown(lastSwitch: now.addingTimeInterval(-10), cooldown: 300,
                                                          activeUsage: reading, activeSampleIsFresh: true,
                                                          policy: .init(), asOf: now))
            XCTAssertTrue(AutoSwitchEngine.isCoolingDown(lastSwitch: now.addingTimeInterval(-10), cooldown: 300,
                                                         activeUsage: reading, activeSampleIsFresh: false,
                                                         policy: .init(), asOf: now))
        }
    }

    func testInvalidConfiguredThresholdsAreClampedIndependently() {
        XCTAssertEqual(AutoSwitchEngine.Policy(sessionThreshold: .nan).sessionLimit, 90)
        XCTAssertEqual(AutoSwitchEngine.Policy(sessionThreshold: 100).sessionLimit, 99)
        XCTAssertEqual(AutoSwitchEngine.Policy(weeklyThreshold: .infinity).weeklyLimit(for: nil, asOf: now), 99)
        XCTAssertEqual(AutoSwitchEngine.Policy(weeklyThreshold: 10).weeklyLimit(for: nil, asOf: now), 50)
    }
}

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
                fresh: Bool = true) -> [UUID] {
        AutoSwitchEngine.rankedTargets(
            active: active, candidates: [later, soon],
            usageByAccount: [active.id: activeUsage, soon.id: first, later.id: second],
            isSwitchable: { _ in true }, activeSampledThisCycle: fresh,
            threshold: 90, hysteresisPct: 10, strategy: strategy, useNearResetThreshold: nearReset,
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

    func testNearResetWaitsUntil99OnEitherWindow() {
        for nearUsage in [usage(98.9, 20), usage(10, 98.9)] {
            XCTAssertTrue(ranked(activeUsage: nearUsage, first: usage(10, 20), second: usage(20, 30)).isEmpty)
        }
        for atLimit in [usage(99, 20), usage(10, 99), usage(100, 20)] {
            XCTAssertFalse(ranked(activeUsage: atLimit, first: usage(10, 20), second: usage(20, 30)).isEmpty)
        }
    }

    func testNormalThresholdOutsideLast48Hours() {
        XCTAssertFalse(ranked(activeUsage: usage(90, 10, reset: 172_801),
                              first: usage(10, 20), second: usage(20, 30)).isEmpty)
        XCTAssertTrue(ranked(activeUsage: usage(89.9, 10, reset: 172_801),
                             first: usage(10, 20), second: usage(20, 30)).isEmpty)
    }

    func test48HourBoundaryAndInvalidResetDates() {
        let policy = AutoSwitchEngine.Policy(useNearResetThreshold: true)
        XCTAssertEqual(policy.threshold(for: usage(90, 10, reset: 172_800), asOf: now), 99)
        XCTAssertEqual(policy.threshold(for: usage(90, 10, reset: 172_801), asOf: now), 90)
        for reset in [nil, 0.0, -1.0] as [Double?] {
            XCTAssertEqual(policy.threshold(for: usage(90, 10, reset: reset), asOf: now), 90)
        }
        let malformed = UsageAPIResponse(fiveHour: nil, sevenDay: UsageWindow(utilization: 95, resetsAt: "bad-date"),
                                        sevenDayOauthApps: nil, sevenDayOpus: nil, sevenDaySonnet: nil,
                                        sevenDayCowork: nil, iguanaNecktie: nil, extraUsage: nil)
        XCTAssertEqual(policy.threshold(for: malformed, asOf: now), 90)
    }

    func testNearResetOverrideCanBeDisabled() {
        XCTAssertFalse(ranked(activeUsage: usage(90, 20), first: usage(10, 20),
                              second: usage(20, 30), nearReset: false).isEmpty)
    }

    func testCanUse98PercentCandidateButNever99PercentCandidate() {
        XCTAssertEqual(ranked(activeUsage: usage(99, 20), first: usage(98, 98), second: usage(10, 99)), [soon.id])
        XCTAssertTrue(ranked(activeUsage: usage(99, 20), first: usage(98.1, 20), second: usage(20, 98.1)).isEmpty)
    }

    func testBothCandidateWindowsMustHaveHeadroom() {
        XCTAssertTrue(ranked(activeUsage: usage(99, 20), first: usage(100, 0), second: usage(0, 100)).isEmpty)
    }

    func testNormalHysteresisStillRequiresTenPoints() {
        XCTAssertEqual(ranked(activeUsage: usage(90, 20), first: usage(80, 20),
                              second: usage(10, 81), nearReset: false), [soon.id])
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
            threshold: 90, hysteresisPct: 10, asOf: now
        )
        XCTAssertTrue(ranked.isEmpty)
    }

    func testMalformedUtilizationDoesNotBecomeAnEmptyAccount() {
        XCTAssertNil(AutoSwitchEngine.bindingUtilization(usage(.nan, -1), asOf: now))
        XCTAssertNil(AutoSwitchEngine.bindingUtilization(usage(.infinity, -10), asOf: now))
    }

    func testDeterministicTieBreak() {
        let expected = [soon.id, later.id].sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(ranked(activeUsage: usage(99, 20), first: usage(20, 20), second: usage(20, 20)), expected)
    }

    func testFreshEmergencyUsageBypassesCooldown() {
        XCTAssertFalse(AutoSwitchEngine.isCoolingDown(lastSwitch: now.addingTimeInterval(-10), cooldown: 300,
                                                      activeUsage: usage(99, 20), activeSampleIsFresh: true, asOf: now))
        XCTAssertTrue(AutoSwitchEngine.isCoolingDown(lastSwitch: now.addingTimeInterval(-10), cooldown: 300,
                                                     activeUsage: usage(99, 20), activeSampleIsFresh: false, asOf: now))
        XCTAssertTrue(AutoSwitchEngine.isCoolingDown(lastSwitch: now.addingTimeInterval(-10), cooldown: 300,
                                                     activeUsage: usage(98, 20), activeSampleIsFresh: true, asOf: now))
        XCTAssertFalse(AutoSwitchEngine.isCoolingDown(lastSwitch: now.addingTimeInterval(-300), cooldown: 300,
                                                      activeUsage: usage(90, 20), activeSampleIsFresh: true, asOf: now))
    }
}

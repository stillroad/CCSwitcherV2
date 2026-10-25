import XCTest
@testable import CCSwitcherPolicy

@MainActor
private final class MemoryCredentials: AccountCredentialStore {
    var liveToken: String?
    var backups: [String: AccountBackup] = [:]
    var deleted: [String] = []
    var allowsDelete = true
    var allowsSave = true

    func readClaudeToken() -> String? { liveToken }
    func readOAuthAccount() -> [String: AnyCodable]? { nil }
    func getAccountBackup(forAccountId id: String) -> AccountBackup? { backups[id] }
    func lookupAccountBackup(forAccountId id: String) -> KeychainService.BackupLookup {
        backups[id].map { .found($0) } ?? .missing
    }
    func saveAccountBackup(token: String, oauthAccount: [String: AnyCodable], forAccountId id: String) -> Bool {
        guard allowsSave else { return false }
        backups[id] = AccountBackup(token: token, oauthAccount: oauthAccount)
        return true
    }
    func removeAccountBackup(forAccountId id: String) -> Bool {
        guard allowsDelete else { return false }
        deleted.append(id)
        backups[id] = nil
        return true
    }
}

@MainActor
private final class FakeClaude: ClaudeAccountClient {
    let store: MemoryCredentials
    var email: String
    var usage: [String: UsageAPIResponse] = [:]
    var events: [String] = []
    var usageCalls: [String] = []
    var switches: [UUID] = []
    var loginCalls = 0
    var captureCalls = 0
    var allowsCapture = true
    var failsSwitch = false
    var onUsage: ((String) async throws -> UsageAPIResponse)?
    var onRotation: ((String) async -> ClaudeService.OAuthRefreshResult)?

    init(store: MemoryCredentials, email: String) { self.store = store; self.email = email }
    func isClaudeAvailable() async -> Bool { true }
    func getAuthStatus() async throws -> AuthStatus {
        AuthStatus(loggedIn: true, authMethod: "claude.ai", apiProvider: "firstParty", email: email,
                   orgId: nil, orgName: nil, subscriptionType: "max")
    }
    func getUsageLimits(accessToken: String) async throws -> UsageAPIResponse {
        events.append("usage:" + accessToken)
        usageCalls.append(accessToken)
        if let onUsage { return try await onUsage(accessToken) }
        return try XCTUnwrap(usage[accessToken])
    }
    func refreshOAuthCredentials(_ credentialsJSON: String) async -> ClaudeService.OAuthRefreshResult {
        if let onRotation { return await onRotation(credentialsJSON) }
        return .rejected
    }
    func switchAccount(from currentAccount: Account?, to targetAccount: Account,
                       targetBackup: AccountBackup) async throws -> ClaudeService.SwitchOutcome {
        if failsSwitch { throw ClaudeServiceError.switchVerificationFailed }
        events.append("switch:" + targetAccount.email)
        switches.append(targetAccount.id)
        store.liveToken = targetBackup.token
        email = targetAccount.email
        return ClaudeService.SwitchOutcome(shadowedBy: nil)
    }
    func captureCurrentCredentials(forAccountId accountId: String, expectedEmail: String) -> Bool { captureCalls += 1; return allowsCapture }
    func login() async throws { loginCalls += 1 }
}

@MainActor
private final class FakeLocalStats: LocalStatsCalculating {
    var calls = 0
    var work: (() async throws -> LocalStatsSnapshot)?

    func calculate(budget: LocalStatsBudget, progress: @escaping LocalStatsProgress) async throws -> LocalStatsSnapshot {
        calls += 1
        progress("Reading test history…")
        if let work { return try await work() }
        return LocalStatsSnapshot(updatedAt: Date(), cost: .empty, activity: .empty)
    }
}

@MainActor
private final class TestClock {
    var date = Date()
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
}

@MainActor
private final class Harness {
    let suite = "CCSwitcherTests." + UUID().uuidString
    let defaults: UserDefaults
    let store = MemoryCredentials()
    let client: FakeClaude
    let state: AppState
    let accounts: [Account]
    let localStats = FakeLocalStats()
    init(count: Int = 3, autoSwitch: Bool = false, clock: TestClock? = nil) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(0.0, forKey: "localStatsInterval")
        defaults.set(autoSwitch, forKey: "autoSwitchEnabled")
        defaults.set(false, forKey: "useNearResetThreshold")
        defaults.set(90.0, forKey: "autoSwitchSessionThreshold")
        defaults.set(99.0, forKey: "autoSwitchWeeklyThreshold")
        accounts = (0..<count).map {
            Account(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 1))!,
                    email: "account\($0)@example.test", displayName: "Account \($0)", isActive: $0 == 0)
        }
        client = FakeClaude(store: store, email: accounts[0].email)
        state = AppState(claudeService: client, keychain: store, defaults: defaults,
                         now: { clock?.date ?? Date() }, pause: { clock?.advance($0) },
                         localStatsCalculator: localStats)
        state.accounts = accounts
        state.activeAccount = accounts[0]
        state.claudeAvailable = true
        for (index, account) in accounts.enumerated() {
            store.backups[account.id.uuidString] = AccountBackup(token: Self.token("t\(index)"),
                oauthAccount: ["emailAddress": AnyCodable(account.email)])
        }
        store.liveToken = Self.token("t0")
        for index in accounts.indices { client.usage["t\(index)"] = Self.usage(20) }
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    func cleanup() {
        client.onUsage = nil
        client.onRotation = nil
        localStats.work = nil
        defaults.removePersistentDomain(forName: suite)
    }
    static func token(_ id: String) -> String { "{\"claudeAiOauth\":{\"accessToken\":\"\(id)\"}}" }
    static func usage(_ percent: Double, weekly: Double = 10, weeklyReset: TimeInterval = 3 * 86400) -> UsageAPIResponse {
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(weeklyReset))
        let sessionReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let json = "{\"five_hour\":{\"utilization\":\(percent),\"resets_at\":\"\(sessionReset)\"},\"seven_day\":{\"utilization\":\(weekly),\"resets_at\":\"\(date)\"}}"
        return try! JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
    }
}

@MainActor
final class AppStateTests: XCTestCase {
    func testLocalStatisticsDefaultToManualWithoutChangingUsagePolling() async {
        let h = Harness()
        defer { h.cleanup() }
        h.defaults.removeObject(forKey: "localStatsInterval")
        await h.state.refresh()
        XCTAssertFalse(h.state.isRefreshingLocalStats)
        XCTAssertEqual(h.localStats.calls, 0)
        XCTAssertTrue(h.client.usageCalls.contains("t0"))
    }

    func testLocalStatsFailureClearsSpinnerKeepsSnapshotAndDoesNotRetryOnUsagePoll() async {
        let h = Harness()
        defer { h.cleanup() }
        h.defaults.set(86_400.0, forKey: "localStatsInterval")
        let previous = Date().addingTimeInterval(-2 * 86_400)
        h.state.lastLocalStatsRefresh = previous
        h.state.costSummary = CostSummary(todayCost: 12, dailyCosts: [])
        h.localStats.work = { throw LocalStatsError.timeLimit }
        await h.state.refresh()
        await h.state.waitForLocalStats()
        XCTAssertFalse(h.state.isRefreshingLocalStats)
        XCTAssertEqual(h.state.lastLocalStatsRefresh, previous)
        XCTAssertEqual(h.state.costSummary.todayCost, 12)
        XCTAssertNotNil(h.state.localStatsMessage)
        await h.state.refresh()
        XCTAssertEqual(h.localStats.calls, 1)
        // A relaunch still uses the persisted failed-attempt time.
        let relaunched = AppState(claudeService: h.client, keychain: h.store, defaults: h.defaults,
                                 localStatsCalculator: h.localStats)
        relaunched.accounts = h.accounts
        relaunched.activeAccount = h.accounts[0]
        await relaunched.refresh()
        XCTAssertEqual(h.localStats.calls, 1)
    }

    func testLocalStatsCancellationStopsWorkAndUsageChecksContinueDuringCalculation() async {
        let h = Harness()
        defer { h.cleanup() }
        let started = expectation(description: "statistics started")
        h.localStats.work = {
            started.fulfill()
            try await Task.sleep(for: .seconds(5))
            return LocalStatsSnapshot(updatedAt: Date(), cost: .empty, activity: .empty)
        }
        h.state.refreshLocalStats()
        await fulfillment(of: [started], timeout: 2)
        h.state.refreshLocalStats()
        XCTAssertEqual(h.localStats.calls, 1)
        await h.state.refresh()
        XCTAssertTrue(h.client.usageCalls.contains("t0"))
        h.state.cancelLocalStats()
        await h.state.waitForLocalStats()
        XCTAssertFalse(h.state.isRefreshingLocalStats)
        XCTAssertFalse(h.state.isStoppingLocalStats)
        XCTAssertNil(h.state.lastLocalStatsRefresh)
        XCTAssertNotNil(h.state.localStatsMessage)
    }

    func testSuccessfulLocalStatsCalculationClearsOldFailureAndPublishesCompleteResult() async {
        let h = Harness()
        defer { h.cleanup() }
        h.state.localStatsMessage = "Previous failure"
        let date = Date()
        h.localStats.work = {
            LocalStatsSnapshot(updatedAt: date, cost: CostSummary(todayCost: 4.5, dailyCosts: []),
                               activity: ActivityStats(conversationTurns: 7))
        }
        h.state.refreshLocalStats()
        await h.state.waitForLocalStats()
        XCTAssertFalse(h.state.isRefreshingLocalStats)
        XCTAssertNil(h.state.localStatsMessage)
        XCTAssertEqual(h.state.lastLocalStatsRefresh, date)
        XCTAssertEqual(h.state.costSummary.todayCost, 4.5)
        XCTAssertEqual(h.state.activityStats.conversationTurns, 7)
    }

    func testLoginDoesNotOverwriteCredentialsWhenBackupFails() async {
        let h = Harness()
        defer { h.cleanup() }
        h.client.allowsCapture = false
        await h.state.loginNewAccount()
        await h.state.reauthenticateAccount(h.accounts[1])
        XCTAssertEqual(h.client.loginCalls, 0)
        XCTAssertEqual(h.store.liveToken, Harness.token("t0"))
        XCTAssertFalse(h.state.isLoggingIn)
        XCTAssertNotNil(h.state.errorMessage)
    }

    func testAddingCurrentAccountUpdatesActiveIdentity() async {
        let h = Harness()
        defer { h.cleanup() }
        h.client.email = "new@example.test"
        await h.state.addAccount()
        XCTAssertEqual(h.state.activeAccount?.email, "new@example.test")
        XCTAssertEqual(h.state.accounts.filter(\.isActive).count, 1)
        XCTAssertEqual(h.state.accounts.count, 4)
    }

    func testActiveRemovalReallySwitchesBeforeDeletingItsBackup() async {
        let h = Harness()
        defer { h.cleanup() }
        await h.state.removeAccount(h.accounts[0])
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[1].id)
        XCTAssertEqual(h.state.activeAccount?.isActive, true)
        XCTAssertEqual(h.store.liveToken, Harness.token("t1"))
        XCTAssertEqual(h.store.deleted, [h.accounts[0].id.uuidString])
        XCTAssertFalse(h.state.accounts.contains { $0.id == h.accounts[0].id })
    }

    func testFailedSwitchKeepsSourceAccountAndBackup() async {
        let h = Harness()
        defer { h.cleanup() }
        h.client.failsSwitch = true
        await h.state.removeAccount(h.accounts[0])
        XCTAssertEqual(h.state.accounts.count, 3)
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[0].id)
        XCTAssertTrue(h.store.deleted.isEmpty)
        XCTAssertEqual(h.store.liveToken, Harness.token("t0"))
        XCTAssertNotNil(h.state.errorMessage)
    }

    func testFailedBackupDeletionKeepsAccountVisible() async {
        let h = Harness()
        defer { h.cleanup() }
        h.store.allowsDelete = false
        await h.state.removeAccount(h.accounts[1])
        XCTAssertEqual(h.state.accounts.count, 3)
        XCTAssertNotNil(h.state.errorMessage)
    }

    func testRemovingLastAccountClearsActiveAndDoesNotRecreateItOnRefresh() async {
        let h = Harness(count: 1)
        defer { h.cleanup() }
        await h.state.removeAccount(h.accounts[0])
        await h.state.refresh()
        XCTAssertTrue(h.state.accounts.isEmpty)
        XCTAssertNil(h.state.activeAccount)
        XCTAssertEqual(h.client.captureCalls, 0)
    }

    func testVerificationRotationExcludesLoginRemovalManualSwitchAndSecondRefresh() async {
        let h = Harness(autoSwitch: true)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(99)
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(20)
        h.client.onUsage = { token in
            if token == "t1" { throw ClaudeService.UsageError.expired }
            return token == "rotated" ? Harness.usage(20) : h.client.usage[token]!
        }
        var checkedLock = false
        h.client.onRotation = { _ in
            checkedLock = true
            await h.state.loginNewAccount()
            await h.state.reauthenticateAccount(h.accounts[1])
            await h.state.addAccount()
            await h.state.removeAccount(h.accounts[0])
            await h.state.switchTo(h.accounts[2])
            await h.state.refresh(allAccounts: true)
            XCTAssertEqual(h.client.loginCalls, 0)
            XCTAssertEqual(h.client.captureCalls, 0)
            XCTAssertTrue(h.client.switches.isEmpty)
            XCTAssertTrue(h.store.deleted.isEmpty)
            return .success(Harness.token("rotated"))
        }
        await h.state.refresh()
        XCTAssertTrue(checkedLock)
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
        XCTAssertEqual(h.store.backups[h.accounts[1].id.uuidString]?.token, Harness.token("rotated"))
        XCTAssertEqual(h.store.liveToken, Harness.token("rotated"))
        XCTAssertFalse(h.state.isRefreshingLocalStats)
    }

    func testDisablingAutoSwitchWhileVerifyingCancelsTheSwap() async {
        let h = Harness(autoSwitch: true)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(99)
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(20)
        h.client.onUsage = { token in
            if token == "t1" { h.defaults.set(false, forKey: "autoSwitchEnabled") }
            return h.client.usage[token]!
        }
        await h.state.refresh()
        XCTAssertTrue(h.client.switches.isEmpty)
    }

    func testExhaustedCandidateIsNotSelectedFromItsStaleLowReading() async {
        let h = Harness(count: 2, autoSwitch: true)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(99)
        h.client.usage["t1"] = Harness.usage(100)
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(20)
        await h.state.refresh()
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[0].id)
    }

    func testStartupCanSwitchBeforeWaitingForEveryInactiveAccount() async {
        let h = Harness(count: 9, autoSwitch: true)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(99)
        await h.state.refresh(allAccounts: true)
        let switchIndex = h.client.events.firstIndex { $0.hasPrefix("switch:") }!
        let lastIdleIndex = h.client.events.firstIndex(of: "usage:t8")!
        XCTAssertLessThan(switchIndex, lastIdleIndex)
        XCTAssertEqual(h.client.switches.count, 1)
    }

    func testSlowSweepInterleavesActiveChecks() async {
        let clock = TestClock()
        let h = Harness(count: 9, autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        h.client.onUsage = { token in
            clock.advance(12)
            return Harness.usage(token == "t0" ? 97 : 100)
        }
        await h.state.refresh(allAccounts: true)
        // Eight slow inactive requests must not postpone active monitoring for
        // the whole sweep. No candidate is eligible in this fixture.
        XCTAssertGreaterThanOrEqual(h.client.usageCalls.filter { $0 == "t0" }.count, 4)
        XCTAssertEqual(Array(h.client.usageCalls.prefix(3)), ["t0", "t1", "t0"])
        XCTAssertTrue(h.client.switches.isEmpty)
    }

    func testInactiveSchedulingDoesNotForceAnotherActiveRequest() async {
        let h = Harness()
        defer { h.cleanup() }
        await h.state.refresh()
        await h.state.refresh(forceActive: false)
        XCTAssertEqual(h.client.usageCalls.filter { $0 == "t0" }.count, 1)
        XCTAssertEqual(Set(h.client.usageCalls), Set(["t0", "t1", "t2"]))
    }

    func testExternalLoginDoesNotAttributeLiveUsageToOldAccount() async {
        let h = Harness(autoSwitch: true)
        defer { h.cleanup() }
        h.client.email = "external@example.test"
        h.store.liveToken = Harness.token("external")
        await h.state.refresh()
        XCTAssertNil(h.state.activeAccount)
        XCTAssertFalse(h.state.accounts.contains(where: \.isActive))
        XCTAssertFalse(h.client.usageCalls.contains("external"))
        XCTAssertTrue(h.client.switches.isEmpty)
    }

    func testLongServerBackoffAppliesToManualRefreshAndVerification() async {
        let h = Harness(count: 2, autoSwitch: true)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(99)
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(20)
        h.client.onUsage = { token in
            if token == "t1" { throw ClaudeService.UsageError.rateLimited(retryAfter: 7200) }
            return h.client.usage[token]!
        }
        await h.state.refresh()
        await h.state.refresh(allAccounts: true)
        XCTAssertEqual(h.client.usageCalls.filter { $0 == "t1" }.count, 1)
        XCTAssertTrue(h.client.switches.isEmpty)
    }

    func testNoBackupWritesOrRotationWhenStoreIsReadOnly() async {
        let h = Harness(count: 2, autoSwitch: true)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(99)
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(20)
        h.store.allowsSave = false
        h.client.onUsage = { token in
            if token == "t1" { throw ClaudeService.UsageError.expired }
            return h.client.usage[token]!
        }
        h.client.onRotation = { _ in XCTFail("Must not spend a refresh token when it cannot be saved"); return .rejected }
        await h.state.refresh()
        XCTAssertEqual(h.store.backups[h.accounts[1].id.uuidString]?.token, Harness.token("t1"))
        XCTAssertTrue(h.client.switches.isEmpty)
    }

    func testNineHighWeeklyAccountsCanStillRotateAtSession90() async {
        let h = Harness(count: 9, autoSwitch: true)
        defer { h.cleanup() }
        // An upgraded installation may still store 99 in the legacy shared
        // setting. New independent defaults must be 90 session / 99 weekly.
        h.defaults.removeObject(forKey: "autoSwitchSessionThreshold")
        h.defaults.removeObject(forKey: "autoSwitchWeeklyThreshold")
        h.defaults.set(99.0, forKey: "autoSwitchThreshold")
        h.client.usage["t0"] = Harness.usage(90, weekly: 95)
        for index in 1..<9 {
            let reading = Harness.usage(0, weekly: 90 + Double(index), weeklyReset: Double(index + 2) * 86_400)
            h.client.usage["t\(index)"] = reading
            h.state.accountUsage[h.accounts[index].id] = reading
        }
        await h.state.refresh(allAccounts: true)
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[1].id)
        XCTAssertEqual(h.state.accountUsage[h.accounts[1].id]?.sevenDay?.utilization, 91)
    }

    func testWeekly99TriggersWithAnEmptySessionBut98Point9DoesNot() async {
        let h = Harness(count: 2, autoSwitch: true)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(0, weekly: 98.9)
        h.client.usage["t1"] = Harness.usage(0, weekly: 93)
        await h.state.refresh(allAccounts: true)
        XCTAssertTrue(h.client.switches.isEmpty)
        h.client.usage["t0"] = Harness.usage(0, weekly: 99)
        await h.state.refresh()
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
    }

    func testFreshWeekly99RejectsCandidateDespiteCachedEmptySessionAndWeekly93() async {
        let h = Harness(count: 2, autoSwitch: true)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(90, weekly: 95)
        h.client.usage["t1"] = Harness.usage(0, weekly: 99)
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(0, weekly: 93)
        await h.state.refresh()
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[0].id)
    }

    func testEitherSliderChangingDuringVerificationCancelsTheSwap() async {
        for (key, value) in [("autoSwitchSessionThreshold", 95.0), ("autoSwitchWeeklyThreshold", 97.0)] {
            let h = Harness(count: 2, autoSwitch: true)
            defer { h.cleanup() }
            h.client.usage["t0"] = Harness.usage(90, weekly: 95)
            h.client.usage["t1"] = Harness.usage(0, weekly: 93)
            h.state.accountUsage[h.accounts[1].id] = Harness.usage(0, weekly: 93)
            h.client.onUsage = { token in
                if token == "t1" { h.defaults.set(value, forKey: key) }
                return h.client.usage[token]!
            }
            await h.state.refresh()
            XCTAssertTrue(h.client.switches.isEmpty, key)
        }
    }

    func testFreshSession90CanSwitchAgainWithinFiveMinuteCooldown() async {
        let h = Harness(count: 3, autoSwitch: true)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(90, weekly: 95)
        h.client.usage["t1"] = Harness.usage(0, weekly: 93, weeklyReset: 3 * 86_400)
        h.client.usage["t2"] = Harness.usage(0, weekly: 95, weeklyReset: 4 * 86_400)
        h.state.accountUsage[h.accounts[1].id] = h.client.usage["t1"]
        h.state.accountUsage[h.accounts[2].id] = h.client.usage["t2"]
        await h.state.refresh()
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
        h.client.usage["t1"] = Harness.usage(90, weekly: 93)
        await h.state.refresh()
        XCTAssertEqual(h.client.switches, [h.accounts[1].id, h.accounts[2].id])
    }

    func testCustomSessionAndWeeklySliderValuesDriveTheCoordinator() async {
        let h = Harness(count: 2, autoSwitch: true)
        defer { h.cleanup() }
        h.defaults.set(75.0, forKey: "autoSwitchSessionThreshold")
        h.defaults.set(95.0, forKey: "autoSwitchWeeklyThreshold")
        h.client.usage["t0"] = Harness.usage(75, weekly: 93)
        h.client.usage["t1"] = Harness.usage(0, weekly: 94)
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(0, weekly: 94)
        await h.state.refresh()
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
    }
}

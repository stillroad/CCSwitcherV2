import XCTest
@testable import CCSwitcherPolicy

@MainActor
private final class MemoryCredentials: AccountCredentialStore {
    var liveToken: String?
    var backups: [String: AccountBackup] = [:]
    var deleted: [String] = []
    var allowsDelete = true
    var allowsSave = true
    var storeUnavailable = false
    var saveDecisions: [Bool] = []

    func readClaudeToken() -> String? { liveToken }
    func readOAuthAccount() -> [String: AnyCodable]? { nil }
    func getAccountBackup(forAccountId id: String) -> AccountBackup? { backups[id] }
    func lookupAccountBackup(forAccountId id: String) -> KeychainService.BackupLookup {
        if storeUnavailable { return .storeUnavailable }
        return backups[id].map { .found($0) } ?? .missing
    }
    func saveAccountBackup(token: String, oauthAccount: [String: AnyCodable], forAccountId id: String) -> Bool {
        guard allowsSave else { return false }
        if !saveDecisions.isEmpty, !saveDecisions.removeFirst() { return false }
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
    var onAuthStatus: (() async -> Void)?
    var onRotation: ((String) async -> ClaudeService.OAuthRefreshResult)?
    var authError: Error?
    var loggedIn = true
    var authMethod: String? = "claude.ai"
    var profileCalls = 0
    var onProfile: ((String) async throws -> String)?
    var beforeSwitch: (() -> Void)?

    init(store: MemoryCredentials, email: String) { self.store = store; self.email = email }
    func isClaudeAvailable() async -> Bool { true }
    func getAuthStatus() async throws -> AuthStatus {
        await onAuthStatus?()
        if let authError { throw authError }
        return AuthStatus(loggedIn: loggedIn, authMethod: authMethod, apiProvider: "firstParty", email: authMethod == "claude.ai" ? email : nil,
                   orgId: nil, orgName: nil, subscriptionType: "max")
    }
    func getAccountEmail(accessToken: String) async throws -> String {
        profileCalls += 1
        if let onProfile { return try await onProfile(accessToken) }
        throw ClaudeService.UsageError.network("Synthetic profile unavailable")
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
                       targetBackup: AccountBackup, expectedCurrentToken: String?) async throws -> ClaudeService.SwitchOutcome {
        beforeSwitch?()
        if let expectedCurrentToken, store.liveToken != expectedCurrentToken {
            throw CredentialSwitchTransaction.Failure.credentialsChanged
        }
        if failsSwitch { throw ClaudeServiceError.switchVerificationFailed }
        events.append("switch:" + targetAccount.email)
        switches.append(targetAccount.id)
        store.liveToken = targetBackup.token
        email = targetAccount.email
        loggedIn = true
        authError = nil
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
        state.stopAutoRefresh()
        client.onUsage = nil
        client.onAuthStatus = nil
        client.onRotation = nil
        client.onProfile = nil
        localStats.work = nil
        defaults.removePersistentDomain(forName: suite)
    }
    func expiringBackup(_ index: Int, at date: Date) {
        let account = accounts[index]
        store.backups[account.id.uuidString] = AccountBackup(token: Self.token("t\(index)", expiresAt: date),
            oauthAccount: ["emailAddress": AnyCodable(account.email)])
    }
    static func token(_ id: String, expiresAt: Date = Date(timeIntervalSince1970: 2_000_000_000)) -> String {
        "{\"claudeAiOauth\":{\"accessToken\":\"\(id)\",\"refreshToken\":\"r-\(id)\",\"expiresAt\":\(Int64(expiresAt.timeIntervalSince1970 * 1000))}}"
    }
    static func usage(_ percent: Double, weekly: Double = 10, weeklyReset: TimeInterval = 3 * 86400) -> UsageAPIResponse {
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(weeklyReset))
        let sessionReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let json = "{\"five_hour\":{\"utilization\":\(percent),\"resets_at\":\"\(sessionReset)\"},\"seven_day\":{\"utilization\":\(weekly),\"resets_at\":\"\(date)\"}}"
        return try! JSONDecoder().decode(UsageAPIResponse.self, from: Data(json.utf8))
    }
}

@MainActor
final class AppStateTests: XCTestCase {
    private static let rejectedLogin = "{\"claudeAiOauth\":{\"accessToken\":\"\",\"refreshToken\":\"\",\"expiresAt\":0}}"

    private func rejectActiveLogin(_ h: Harness) {
        CredentialAnchorStore(defaults: h.defaults).anchor(accountID: h.accounts[0].id, token: Harness.token("t0"))
        h.store.liveToken = Self.rejectedLogin
        h.client.loggedIn = false
    }

    func testRejectedActiveLoginRecoversWithFreshQuotaAndPreservesFailedBackup() async {
        let h = Harness(autoSwitch: true)
        defer { h.cleanup() }
        rejectActiveLogin(h)
        await h.state.refresh()
        XCTAssertEqual(h.client.usageCalls, ["t1"])
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[1].id)
        XCTAssertEqual(h.store.backups[h.accounts[0].id.uuidString]?.token, Harness.token("t0"))
        XCTAssertEqual(h.state.accountAuthHealth[h.accounts[0].id]?.kind, .needsReauthentication)
        XCTAssertTrue(h.client.events.first?.hasPrefix("usage:") == true)
    }

    func testRecoveryWorksWhenClaudeStatusThrowsOrAppRestartsLoggedOut() async {
        for throwsStatus in [false, true] {
            let h = Harness(autoSwitch: true)
            rejectActiveLogin(h)
            h.state.activeAccount = nil
            if throwsStatus { h.client.authError = ClaudeServiceError.cliError("not logged in") }
            await h.state.refresh()
            XCTAssertEqual(h.client.switches, [h.accounts[1].id])
            h.cleanup()
        }
    }

    func testRecoveryRespectsDisabledRotationAndPausedAccounts() async {
        for enabled in [false, true] {
            let h = Harness(autoSwitch: enabled)
            rejectActiveLogin(h)
            if enabled {
                for account in h.accounts.dropFirst() { h.state.setAccountRotationPaused(account, paused: true) }
            }
            await h.state.refresh()
            XCTAssertTrue(h.client.switches.isEmpty)
            XCTAssertTrue(h.client.usageCalls.isEmpty)
            h.cleanup()
        }
    }

    func testRecoveryDoesNotTreatMissingMalformedOrOrdinaryLoggedOutCredentialsAsRejection() async {
        for token in [nil, "broken", "{}", "{\"claudeAiOauth\":{}}"] as [String?] {
            let h = Harness(autoSwitch: true)
            rejectActiveLogin(h)
            h.store.liveToken = token
            h.client.loggedIn = false
            await h.state.refresh()
            XCTAssertTrue(h.client.switches.isEmpty)
            h.cleanup()
        }
    }

    func testRecoveryChecksOnlyOneCandidatePerFiveMinutesAndRejectsExhaustedQuota() async {
        let clock = TestClock()
        let h = Harness(autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        rejectActiveLogin(h)
        h.client.usage["t1"] = Harness.usage(0, weekly: 99)
        await h.state.refresh()
        XCTAssertEqual(h.client.usageCalls, ["t1"])
        XCTAssertTrue(h.client.switches.isEmpty)
        for _ in 0..<4 { clock.advance(60); await h.state.refresh() }
        XCTAssertEqual(h.client.usageCalls, ["t1"])
        clock.advance(60)
        await h.state.refresh()
        XCTAssertEqual(h.client.usageCalls, ["t1", "t2"])
        XCTAssertEqual(h.client.switches, [h.accounts[2].id])
    }

    func testRecoveryHonorsServerBackoff() async {
        let clock = TestClock()
        let h = Harness(count: 2, autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        rejectActiveLogin(h)
        h.client.onUsage = { _ in throw ClaudeService.UsageError.rateLimited(retryAfter: 1800) }
        await h.state.refresh()
        for _ in 0..<5 { clock.advance(300); await h.state.refresh() }
        XCTAssertEqual(h.client.usageCalls, ["t1"])
        XCTAssertTrue(h.client.switches.isEmpty)
    }

    func testRecoveryNeverOverridesAnAPIKeyOrOtherCredentialSource() async {
        let h = Harness(autoSwitch: true)
        defer { h.cleanup() }
        rejectActiveLogin(h)
        h.client.loggedIn = true
        h.client.authMethod = "api_key"
        await h.state.refresh()
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertTrue(h.client.usageCalls.isEmpty)
        XCTAssertEqual(h.client.profileCalls, 0)
    }

    func testFailureDuringUsageStopsFullSweepAfterOneRecoveryCheck() async {
        let h = Harness(count: 9, autoSwitch: true)
        defer { h.cleanup() }
        h.client.onUsage = { token in
            if token == "t0" {
                h.store.liveToken = Self.rejectedLogin
                h.client.loggedIn = false
                throw ClaudeService.UsageError.expired
            }
            return Harness.usage(10)
        }
        await h.state.refresh(allAccounts: true)
        XCTAssertEqual(h.client.usageCalls, ["t0", "t1"])
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
    }

    func testUpgradeRecognizesAlreadyRenewedLoginWithOneProfileCheck() async {
        let h = Harness(autoSwitch: true)
        defer { h.cleanup() }
        h.store.liveToken = Harness.token("renewed-before-upgrade")
        h.client.usage["renewed-before-upgrade"] = Harness.usage(20)
        h.client.onProfile = { _ in h.accounts[0].email }
        await h.state.refresh()
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[0].id)
        XCTAssertEqual(h.client.profileCalls, 1)
        await h.state.refresh()
        XCTAssertEqual(h.client.profileCalls, 1)
        XCTAssertTrue(h.client.switches.isEmpty)
    }

    func testProfileVerificationCannotAnchorAReplacedCredential() async {
        let h = Harness(autoSwitch: true)
        defer { h.cleanup() }
        h.store.liveToken = Harness.token("unrecognized")
        h.client.onProfile = { _ in
            h.store.liveToken = Harness.token("different-login")
            return h.accounts[0].email
        }
        await h.state.refresh()
        XCTAssertNil(h.state.activeAccount)
        XCTAssertTrue(h.client.usageCalls.isEmpty)
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.store.liveToken, Harness.token("different-login"))
    }

    func testUnrecognizedCredentialProfileCheckRespectsServerBackoff() async {
        let clock = TestClock()
        let h = Harness(autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        h.store.liveToken = Harness.token("unrecognized")
        h.client.onProfile = { _ in throw ClaudeService.UsageError.rateLimited(retryAfter: 1800) }
        await h.state.refresh()
        for _ in 0..<5 { clock.advance(300); await h.state.refresh() }
        XCTAssertEqual(h.client.profileCalls, 1)
        XCTAssertTrue(h.client.usageCalls.isEmpty)
        XCTAssertTrue(h.client.switches.isEmpty)
    }

    func testRecoveryStandsDownWhenUserRepairsLoginOrChangesSettingsDuringVerification() async {
        for action in ["repair", "disable", "pause", "threshold"] {
            let h = Harness(autoSwitch: true)
            rejectActiveLogin(h)
            h.client.onUsage = { _ in
                switch action {
                case "repair": h.store.liveToken = Harness.token("user-repaired")
                case "disable": h.defaults.set(false, forKey: "autoSwitchEnabled")
                case "pause": h.state.setAccountRotationPaused(h.accounts[1], paused: true)
                default: h.defaults.set(95.0, forKey: "autoSwitchWeeklyThreshold")
                }
                return Harness.usage(5)
            }
            await h.state.refresh()
            XCTAssertTrue(h.client.switches.isEmpty, action)
            if action == "repair" { XCTAssertEqual(h.store.liveToken, Harness.token("user-repaired")) }
            h.cleanup()
        }
    }

    func testRecoveryDoesNotOverwriteLoginRepairedJustBeforeSwitchWrite() async {
        let h = Harness(autoSwitch: true)
        defer { h.cleanup() }
        rejectActiveLogin(h)
        h.client.beforeSwitch = { h.store.liveToken = Harness.token("user-repaired") }
        await h.state.refresh()
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.store.liveToken, Harness.token("user-repaired"))
        h.client.beforeSwitch = nil
    }

    func testProfileDriftKeepsUsageOnActualCredentialOwner() async {
        let h = Harness(autoSwitch: true)
        defer { h.cleanup() }
        await h.state.refresh()
        h.client.email = h.accounts[1].email
        await h.state.refresh()
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[0].id)
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.store.backups[h.accounts[1].id.uuidString]?.token, Harness.token("t1"))
    }

    func testUnknownRotationAfterProfileDriftCannotBeFiledUnderAnotherAccount() async {
        let h = Harness(autoSwitch: true)
        defer { h.cleanup() }
        await h.state.refresh()
        h.client.email = h.accounts[1].email
        await h.state.refresh()
        h.store.liveToken = Harness.token("unknown-rotation")
        await h.state.refresh()
        XCTAssertNil(h.state.activeAccount)
        XCTAssertFalse(h.client.usageCalls.contains("unknown-rotation"))
        XCTAssertTrue(h.client.switches.isEmpty)
    }

    func testHandoffRenewsNearExpiryBeforeTouchingLiveLogin() async {
        let h = Harness()
        defer { h.cleanup() }
        h.expiringBackup(1, at: Date().addingTimeInterval(9 * 60))
        var renewals = 0
        h.client.onRotation = { _ in
            renewals += 1
            XCTAssertEqual(h.store.liveToken, Harness.token("t0"))
            XCTAssertTrue(h.client.switches.isEmpty)
            return .success(Harness.token("renewed"))
        }
        h.client.usage["renewed"] = Harness.usage(10)
        await h.state.switchTo(h.accounts[1])
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
        XCTAssertEqual(h.store.liveToken, Harness.token("renewed"))
        XCTAssertEqual(h.store.backups[h.accounts[1].id.uuidString]?.token, Harness.token("renewed"))
    }

    func testHealthyHandoffDoesNotRenewUnnecessarily() async {
        let h = Harness()
        defer { h.cleanup() }
        h.client.onRotation = { _ in XCTFail("Healthy login should not renew"); return .rejected }
        await h.state.switchTo(h.accounts[1])
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
    }

    func testRejectedHandoffLeavesLiveLoginAloneAndSurvivesRestart() async {
        let h = Harness()
        defer { h.cleanup() }
        h.expiringBackup(1, at: Date().addingTimeInterval(9 * 60))
        var renewals = 0
        h.client.onRotation = { _ in renewals += 1; return .rejected }
        await h.state.switchTo(h.accounts[1])
        XCTAssertEqual(h.store.liveToken, Harness.token("t0"))
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.state.accountAuthHealth[h.accounts[1].id]?.kind, .needsReauthentication)
        let restored = AppState(claudeService: h.client, keychain: h.store, defaults: h.defaults)
        restored.accounts = h.accounts
        restored.activeAccount = h.accounts[0]
        await restored.switchTo(h.accounts[1])
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(restored.accountAuthHealth[h.accounts[1].id]?.kind, .needsReauthentication)

        // A fresh browser login replaces the grant and clears the durable warning.
        h.store.backups[h.accounts[1].id.uuidString] = AccountBackup(token: Harness.token("fresh-login"),
            oauthAccount: ["emailAddress": AnyCodable(h.accounts[1].email)])
        h.client.usage["fresh-login"] = Harness.usage(10)
        await restored.switchTo(h.accounts[1])
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
        XCTAssertEqual(restored.accountAuthHealth[h.accounts[1].id]?.kind, .ready)
    }

    func testEmptyInactiveLoginIsRedWithoutWaitingForItsUsageTurn() async {
        let h = Harness()
        defer { h.cleanup() }
        h.store.backups[h.accounts[2].id.uuidString] = AccountBackup(
            token: "{\"claudeAiOauth\":{\"accessToken\":\"\",\"refreshToken\":\"\",\"expiresAt\":0}}",
            oauthAccount: ["emailAddress": AnyCodable(h.accounts[2].email)])
        await h.state.refresh()
        XCTAssertEqual(h.state.accountAuthHealth[h.accounts[2].id]?.kind, .needsReauthentication)
        XCTAssertEqual(h.client.usageCalls, ["t0", "t1"])
    }

    func testClearedActiveLoginIsRedEvenWhenAuthStatusThrows() async {
        let h = Harness()
        defer { h.cleanup() }
        h.store.liveToken = "{\"claudeAiOauth\":{\"accessToken\":\"\",\"refreshToken\":\"\",\"expiresAt\":0}}"
        h.client.authError = ClaudeServiceError.cliError("Exit 1")
        await h.state.refresh()
        XCTAssertEqual(h.state.accountAuthHealth[h.accounts[0].id]?.kind, .needsReauthentication)
        XCTAssertTrue(h.client.usageCalls.isEmpty)
        XCTAssertEqual(h.store.backups[h.accounts[0].id.uuidString]?.token, Harness.token("t0"))
    }

    func testClearedSourceDoesNotBlockBrowserRepairOrOverwriteSavedBackup() async {
        let h = Harness()
        defer { h.cleanup() }
        h.store.liveToken = "{\"claudeAiOauth\":{\"accessToken\":null,\"refreshToken\":null,\"expiresAt\":0}}"
        h.client.allowsCapture = false
        await h.state.loginNewAccount()
        XCTAssertEqual(h.client.loginCalls, 1)
        // Only the post-login capture runs; the cleared source was skipped.
        XCTAssertEqual(h.client.captureCalls, 1)
        XCTAssertEqual(h.store.backups[h.accounts[0].id.uuidString]?.token, Harness.token("t0"))
    }

    func testRenewalRateLimitBlocksRepeatedClicksUntilServerDeadline() async {
        let clock = TestClock()
        let h = Harness(clock: clock)
        defer { h.cleanup() }
        h.expiringBackup(1, at: clock.date.addingTimeInterval(60))
        var renewals = 0
        h.client.onRotation = { _ in renewals += 1; return .rateLimited(3600) }
        await h.state.switchTo(h.accounts[1])
        clock.advance(300)
        await h.state.switchTo(h.accounts[1])
        XCTAssertEqual(renewals, 1)
        XCTAssertEqual(h.state.accountAuthHealth[h.accounts[1].id]?.kind, .temporarilyUnavailable)
        XCTAssertTrue(h.client.usageCalls.isEmpty)
        XCTAssertEqual(h.store.liveToken, Harness.token("t0"))
        clock.advance(3300)
        await h.state.switchTo(h.accounts[1])
        XCTAssertEqual(renewals, 2)
    }

    func testRenewalCannotBeSelectedIfRotatedCredentialCannotBeSaved() async {
        let h = Harness()
        defer { h.cleanup() }
        h.expiringBackup(1, at: Date().addingTimeInterval(60))
        let original = h.store.backups[h.accounts[1].id.uuidString]?.token
        h.store.saveDecisions = [true, false, false]
        h.client.onRotation = { _ in .success(Harness.token("renewed")) }
        await h.state.switchTo(h.accounts[1])
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.store.backups[h.accounts[1].id.uuidString]?.token, original)
        XCTAssertEqual(h.state.accountAuthHealth[h.accounts[1].id]?.kind, .needsReauthentication)
        XCTAssertEqual(h.store.liveToken, Harness.token("t0"))
    }

    func testUnavailableStoreDoesNotTellUserToReauthenticate() async {
        let h = Harness()
        defer { h.cleanup() }
        h.store.storeUnavailable = true
        await h.state.switchTo(h.accounts[1])
        XCTAssertEqual(h.state.accountAuthHealth[h.accounts[1].id]?.kind, .temporarilyUnavailable)
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertNil(h.defaults.dictionary(forKey: "com.ccswitcher.rejectedAuthGrants"))
    }

    func testFreshQuotaCannotBypassNearExpiryRenewalDuringAutoSwitch() async {
        let clock = TestClock()
        let h = Harness(autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        h.expiringBackup(1, at: Date().addingTimeInterval(9 * 60))
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(0)
        h.client.usage["t0"] = Harness.usage(95)
        h.client.usage["t2"] = Harness.usage(95)
        h.client.onUsage = { token in
            if token == "t0" {
                h.state.accountUsageSampledAt[h.accounts[1].id] = clock.date
            }
            return h.client.usage[token]!
        }
        h.client.onRotation = { _ in .rejected }
        await h.state.refresh()
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertFalse(h.client.usageCalls.contains("t1"))
        XCTAssertEqual(h.state.accountAuthHealth[h.accounts[1].id]?.kind, .needsReauthentication)
    }

    func testAutoSwitchDisabledDuringPreflightRenewalLeavesLiveLoginAlone() async {
        let clock = TestClock()
        let h = Harness(autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        h.expiringBackup(1, at: clock.date.addingTimeInterval(60))
        h.client.usage["t0"] = Harness.usage(95)
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(0)
        h.client.onUsage = { token in
            if token == "t0" { h.state.accountUsageSampledAt[h.accounts[1].id] = clock.date }
            return Harness.usage(95)
        }
        h.client.onRotation = { _ in
            h.defaults.set(false, forKey: "autoSwitchEnabled")
            return .success(Harness.token("renewed"))
        }
        await h.state.refresh()
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.store.liveToken, Harness.token("t0"))
        XCTAssertEqual(h.store.backups[h.accounts[1].id.uuidString]?.token, Harness.token("renewed"))
    }

    func testSlowRenewalCannotUseQuotaThatBecameStaleDuringPreflight() async {
        let clock = TestClock()
        let h = Harness(autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        h.expiringBackup(1, at: clock.date.addingTimeInterval(60))
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(0)
        h.client.onUsage = { token in
            if token == "t0" { h.state.accountUsageSampledAt[h.accounts[1].id] = clock.date }
            return Harness.usage(95)
        }
        h.client.onRotation = { _ in
            clock.advance(31)
            return .success(Harness.token("renewed"))
        }
        await h.state.refresh()
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.store.liveToken, Harness.token("t0"))
    }

    func testRejectedFreshCandidateCanFallThroughToAnotherFreshCandidate() async {
        let clock = TestClock()
        let h = Harness(autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        h.defaults.set("mostRemaining", forKey: "autoSwitchStrategy")
        h.expiringBackup(1, at: clock.date.addingTimeInterval(60))
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(0, weekly: 0)
        h.state.accountUsage[h.accounts[2].id] = Harness.usage(20, weekly: 20)
        h.client.onUsage = { token in
            if token == "t0" {
                h.state.accountUsageSampledAt[h.accounts[1].id] = clock.date
                h.state.accountUsageSampledAt[h.accounts[2].id] = clock.date
                return Harness.usage(95)
            }
            return Harness.usage(20)
        }
        h.client.onRotation = { _ in .rejected }
        await h.state.refresh()
        XCTAssertEqual(h.client.switches, [h.accounts[2].id])
        XCTAssertFalse(h.client.usageCalls.contains("t1"))
        XCTAssertEqual(h.state.accountAuthHealth[h.accounts[1].id]?.kind, .needsReauthentication)
    }
    func testPauseAndResumePersistWithoutTouchingCredentialsOrPolling() throws {
        let h = Harness(autoSwitch: true)
        defer { h.cleanup() }
        let tokens = h.store.backups.mapValues(\.token)
        h.state.setAccountRotationPaused(h.accounts[0], paused: true)
        let saved = try XCTUnwrap(h.defaults.data(forKey: "com.ccswitcher.accounts"))
        let restored = try JSONDecoder().decode([Account].self, from: saved)
        XCTAssertTrue(restored[0].isRotationPaused)
        XCTAssertEqual(Array(restored.dropFirst()), Array(h.accounts.dropFirst()))
        XCTAssertTrue(try XCTUnwrap(h.state.activeAccount).isRotationPaused)
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[0].id)

        // The caller may hold the original unpaused value; resolve by ID.
        h.state.setAccountRotationPaused(h.accounts[0], paused: false)
        let resumedData = try XCTUnwrap(h.defaults.data(forKey: "com.ccswitcher.accounts"))
        XCTAssertEqual(try JSONDecoder().decode([Account].self, from: resumedData), h.accounts)
        XCTAssertFalse(try XCTUnwrap(h.state.activeAccount).isRotationPaused)
        XCTAssertTrue(h.client.usageCalls.isEmpty)
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.client.loginCalls, 0)
        XCTAssertEqual(h.client.captureCalls, 0)
        XCTAssertTrue(h.store.deleted.isEmpty)
        XCTAssertEqual(h.store.backups.mapValues(\.token), tokens)
        XCTAssertEqual(h.store.liveToken, Harness.token("t0"))
    }

    func testAllOtherAccountsPausedPreventsSwitchUntilResumed() async {
        let h = Harness(count: 2, autoSwitch: true)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(90)
        h.state.setAccountRotationPaused(h.accounts[1], paused: true)
        await h.state.refresh(allAccounts: true)
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[0].id)
        let requests = h.client.usageCalls.count
        h.state.setAccountRotationPaused(h.accounts[1], paused: false)
        XCTAssertEqual(h.client.usageCalls.count, requests)
        await h.state.refresh()
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
    }

    func testPausedAccountCanBeSelectedManuallyAndStaysPausedAfterRefresh() async throws {
        let h = Harness()
        defer { h.cleanup() }
        h.state.setAccountRotationPaused(h.accounts[1], paused: true)
        await h.state.switchTo(h.accounts[1])
        XCTAssertEqual(h.client.switches, [h.accounts[1].id])
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[1].id)
        XCTAssertTrue(try XCTUnwrap(h.state.activeAccount).isRotationPaused)
        let saved = try XCTUnwrap(h.defaults.data(forKey: "com.ccswitcher.accounts"))
        let restored = try JSONDecoder().decode([Account].self, from: saved)
        XCTAssertTrue(restored[1].isRotationPaused)
        XCTAssertTrue(restored[1].isActive)
        XCTAssertEqual(h.store.backups.count, 3)
    }

    func testPausingCandidateDuringVerificationCancelsItsAutomaticSwap() async {
        let h = Harness(count: 2, autoSwitch: true)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(90)
        h.state.accountUsage[h.accounts[1].id] = Harness.usage(20)
        var pausedDuringVerification = false
        h.client.onUsage = { token in
            if token == "t1" {
                pausedDuringVerification = true
                h.state.setAccountRotationPaused(h.accounts[1], paused: true)
            }
            return h.client.usage[token]!
        }
        await h.state.refresh()
        XCTAssertTrue(pausedDuringVerification)
        XCTAssertTrue(h.state.accounts[1].isRotationPaused)
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.state.activeAccount?.id, h.accounts[0].id)
        XCTAssertEqual(h.client.usageCalls.filter { $0 == "t1" }.count, 1)
    }

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
        h.store.allowsSave = false
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
            clock.advance(60)
            return Harness.usage(token == "t0" ? 97 : 100)
        }
        await h.state.refresh(allAccounts: true)
        // Eight slow inactive requests must not postpone active monitoring for
        // the whole sweep. No candidate is eligible in this fixture.
        XCTAssertEqual(h.client.usageCalls.filter { $0 == "t0" }.count, 2)
        XCTAssertEqual(Array(h.client.usageCalls.prefix(3)), ["t0", "t1", "t2"])
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

    func testFiveMinutePollingStaysFixedNearBothLimitsIncludingRequestLatency() async {
        for reading in [Harness.usage(89), Harness.usage(20, weekly: 98), Harness.usage(100)] {
            let clock = TestClock()
            let h = Harness(count: 1, autoSwitch: true, clock: clock)
            defer { h.cleanup() }
            var requests: [Date] = []
            h.client.onAuthStatus = { clock.advance(0.35) }
            h.client.onUsage = { _ in
                requests.append(clock.date)
                clock.advance(0.5)
                return reading
            }
            await h.state.refresh()
            for _ in 0..<3 {
                XCTAssertEqual(h.state.nextAutomaticRefreshDate, requests.last!.addingTimeInterval(300))
                clock.date = h.state.nextAutomaticRefreshDate
                await h.state.refreshAutomatically()
            }
            XCTAssertEqual(requests.count, 4)
            for (previous, next) in zip(requests, requests.dropFirst()) {
                XCTAssertGreaterThanOrEqual(next.timeIntervalSince(previous), 300)
                XCTAssertLessThan(next.timeIntervalSince(previous), 301)
            }
        }
    }

    func testNearLimitRateLimitSwitchesOnlyAfterFreshCandidateVerification() async {
        for reading in [Harness.usage(88), Harness.usage(20, weekly: 98)] {
            let clock = TestClock()
            let h = Harness(count: 2, autoSwitch: true, clock: clock)
            defer { h.cleanup() }
            h.client.usage["t0"] = reading
            await h.state.refresh(allAccounts: true)
            let originalSample = h.state.accountUsageSampledAt[h.accounts[0].id]
            XCTAssertTrue(h.client.switches.isEmpty)
            h.client.onUsage = { token in
                if token == "t0" { throw ClaudeService.UsageError.rateLimited(retryAfter: 0) }
                return Harness.usage(0, weekly: 93)
            }
            clock.advance(300)
            await h.state.refreshAutomatically()
            XCTAssertEqual(h.client.switches, [h.accounts[1].id])
            XCTAssertEqual(h.client.usageCalls, ["t0", "t1", "t0", "t1"])
            XCTAssertEqual(h.state.accountUsageSampledAt[h.accounts[0].id], originalSample)
            XCTAssertEqual(h.state.accountUsageErrors[h.accounts[0].id]?.isRateLimited, true)
        }
    }

    func testRateLimitFallbackRejectsCandidateWhoseFreshWeeklyUsageIsExhausted() async {
        let clock = TestClock()
        let h = Harness(count: 2, autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(20, weekly: 98)
        await h.state.refresh(allAccounts: true)
        h.client.onUsage = { token in
            if token == "t0" { throw ClaudeService.UsageError.rateLimited(retryAfter: 0) }
            return Harness.usage(0, weekly: 100)
        }
        clock.advance(300)
        await h.state.refreshAutomatically()
        XCTAssertTrue(h.client.switches.isEmpty)
        XCTAssertEqual(h.client.usageCalls.filter { $0 == "t1" }.count, 2)
    }

    func testRateLimitFallbackDoesNotMoveHealthyOrUnknownAccountsOrIgnoreDisabledSetting() async {
        for (reading, enabled) in [(Harness.usage(87, weekly: 96), true), (Harness.usage(89, weekly: 98), false)] {
            let clock = TestClock()
            let h = Harness(count: 2, autoSwitch: enabled, clock: clock)
            defer { h.cleanup() }
            h.client.usage["t0"] = reading
            await h.state.refresh(allAccounts: true)
            h.client.onUsage = { token in
                if token == "t0" { throw ClaudeService.UsageError.rateLimited(retryAfter: 0) }
                return Harness.usage(20)
            }
            clock.advance(300)
            await h.state.refreshAutomatically()
            XCTAssertTrue(h.client.switches.isEmpty)
            XCTAssertEqual(h.client.usageCalls.filter { $0 == "t1" }.count, 1)
        }
        let h = Harness(count: 2, autoSwitch: true)
        defer { h.cleanup() }
        h.client.onUsage = { token in
            if token == "t0" { throw ClaudeService.UsageError.rateLimited(retryAfter: 0) }
            return Harness.usage(20)
        }
        await h.state.refresh(allAccounts: true)
        XCTAssertTrue(h.client.switches.isEmpty)
    }

    func testRateLimitFallbackRechecksResetAfterCandidateRequest() async {
        let clock = TestClock()
        let h = Harness(count: 2, autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        h.client.usage["t0"] = Harness.usage(20, weekly: 98, weeklyReset: 310)
        await h.state.refresh(allAccounts: true)
        h.client.onUsage = { token in
            if token == "t0" { throw ClaudeService.UsageError.rateLimited(retryAfter: 0) }
            clock.advance(20)
            return Harness.usage(20)
        }
        clock.advance(300)
        await h.state.refreshAutomatically()
        XCTAssertTrue(h.client.switches.isEmpty)
    }

    func testRepeatedZeroRetryAfterUsesFiveThenTenMinutesAndSuccessClearsBackoff() async {
        let clock = TestClock()
        let h = Harness(count: 1, clock: clock)
        defer { h.cleanup() }
        var rejected = true
        h.client.onUsage = { _ in
            if rejected { throw ClaudeService.UsageError.rateLimited(retryAfter: 0) }
            return Harness.usage(20)
        }
        await h.state.refresh()
        for _ in 0..<4 {
            clock.advance(60)
            await h.state.refresh(allAccounts: true)
        }
        XCTAssertEqual(h.client.usageCalls.count, 1)
        clock.advance(60)
        await h.state.refresh()
        XCTAssertEqual(h.client.usageCalls.count, 2)
        clock.advance(300)
        await h.state.refresh()
        XCTAssertEqual(h.client.usageCalls.count, 2)
        rejected = false
        clock.advance(300)
        await h.state.refresh()
        XCTAssertEqual(h.client.usageCalls.count, 3)
        XCTAssertNil(h.state.accountUsageErrors[h.accounts[0].id])
        rejected = true
        clock.advance(300)
        await h.state.refresh()
        clock.advance(300)
        await h.state.refresh()
        XCTAssertEqual(h.client.usageCalls.count, 5, "Success must reset the backoff to five minutes")
    }

    func testFailedVerificationIsNotRepeatedBySameSweepOrBetweenAutomaticCycles() async {
        let clock = TestClock()
        let h = Harness(count: 3, autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        await h.state.refresh(allAccounts: true)
        h.client.usage["t0"] = Harness.usage(90)
        h.client.onUsage = { token in
            if token == "t1" { throw ClaudeService.UsageError.network("test unavailable") }
            return h.client.usage[token]!
        }
        clock.advance(300)
        await h.state.refresh(allAccounts: true)
        XCTAssertEqual(h.client.usageCalls.filter { $0 == "t1" }.count, 2,
                       "Failed verification counts as the sweep's attempt too")
        // The sweep can use t2's fresh sample without another verification.
        XCTAssertEqual(h.client.switches, [h.accounts[2].id])
    }

    func testFailedCandidateDoesNotCauseExtraVerificationRequestsAndNextCycleCanTryAnother() async {
        let clock = TestClock()
        let h = Harness(count: 3, autoSwitch: true, clock: clock)
        defer { h.cleanup() }
        await h.state.refresh(allAccounts: true)
        h.client.usage["t0"] = Harness.usage(90)
        h.client.onUsage = { token in
            if token == "t1" { throw ClaudeService.UsageError.network("test unavailable") }
            return h.client.usage[token]!
        }
        clock.advance(300)
        await h.state.refreshAutomatically()
        let count = h.client.usageCalls.count
        clock.advance(60)
        await h.state.refresh(forceActive: false)
        XCTAssertEqual(h.client.usageCalls.count, count)
        clock.advance(240)
        await h.state.refreshAutomatically()
        XCTAssertEqual(h.client.switches, [h.accounts[2].id])
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

import SwiftUI
import Combine
import WidgetKit

private let log = FileLog("AppState")

/// Central app state managing accounts, usage data, and active sessions.
@MainActor
final class AppState: ObservableObject {
    private let isPreview: Bool
    // MARK: - Published State

    @Published var accounts: [Account] = []
    @Published var activeAccount: Account?
    @Published var accountUsage: [UUID: UsageAPIResponse] = [:]
    /// When each account's usage sample was actually taken. Accounts are polled
    /// round-robin (active + one other per cycle), so a card can be showing a
    /// reading several cycles old; without this the UI would render a stale
    /// percentage exactly like a live one, and auto-switch could not tell
    /// which samples this cycle actually verified.
    @Published var accountUsageSampledAt: [UUID: Date] = [:]
    @Published var usageSummary: UsageSummary = .empty
    @Published var recentActivity: [DailyActivity] = []
    @Published var activeSessions: [SessionInfo] = []
    @Published var isLoading = false
    @Published var isLoggingIn = false
    @Published var errorMessage: String?
    @Published var claudeAvailable = false
    @Published var lastUsageRefresh: Date?
    @Published var costSummary: CostSummary = .empty
    @Published var activityStats: ActivityStats = .empty
    @Published var isRefreshingLocalStats = false
    @Published var lastLocalStatsRefresh: Date?
    @Published var localStatsProgress = ""
    @Published var localStatsMessage: String?
    @Published var isStoppingLocalStats = false
    private var localStatsTask: Task<Void, Never>?
    private var localStatsRunID: UUID?

    var hasCurrentLocalStats: Bool {
        lastLocalStatsRefresh.map { Calendar.current.isDateInToday($0) } ?? false
    }

    // Store errors as special struct to surface in UI
    struct UsageErrorState {
        let isExpired: Bool
        let isRateLimited: Bool
        let message: String
    }
    
    @Published var accountUsageErrors: [UUID: UsageErrorState] = [:]

    // MARK: - Services

    private lazy var claudeService: any ClaudeAccountClient = ClaudeService.shared
    private let statsParser = StatsParser.shared
    private var localStatsCalculator: any LocalStatsCalculating = LocalStatsCalculator()
    private var persistLocalStats: (LocalStatsSnapshot) -> Void = { $0.save() }
    private var readsSupplementalLocalStats = true
    private lazy var keychain: any AccountCredentialStore = KeychainService.shared

    private var defaults: UserDefaults = .standard
    private var now: () -> Date = Date.init
    private var pause: (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }
    private var publishesWidgets = true
    private var shouldAutoCaptureAccount = false
    private var identityVerified = false
    private var refreshCycleRunning = false
    private var lastUsageRequestAt: Date?
    private var configuredRefreshInterval: TimeInterval = 300
    private var lastIdentityAttempt: Date?
    private var lastWidgetData: WidgetData?
    private var lastWidgetAttempt: Date?
    private var lastWidgetAttemptActiveID: UUID?

    private let accountsKey = "com.ccswitcher.accounts"
    private var refreshTimer: Timer?
    private var autoRefreshStarted = false

    // MARK: - Usage polling state

    /// Re-entrancy guard: overlapping refreshes (timer + manual button + post-switch)
    /// would each burst per-account usage requests and trip the endpoint's rate limit.
    private var isRefreshing = false

    /// Attempts (including failures) drive scheduling; successful samples drive
    /// display freshness. Keeping them separate avoids retrying a broken account
    /// on every cycle and starving the remaining inactive accounts.
    private var usageLastAttempt: [UUID: Date] = [:]
    private var lastDiagnosticsAt: Date?

    private var inactiveRefreshInterval: TimeInterval {
        defaults.object(forKey: "inactiveRefreshInterval") as? Double
            ?? RefreshPolicy.defaultInactiveInterval
    }

    private var autoSwitchPolicy: AutoSwitchEngine.Policy {
        AutoSwitchEngine.Policy(
            strategy: AutoSwitchEngine.Strategy(rawValue: defaults.string(forKey: "autoSwitchStrategy") ?? "") ?? .soonestReset,
            sessionThreshold: defaults.object(forKey: "autoSwitchSessionThreshold") as? Double ?? 90,
            weeklyThreshold: defaults.object(forKey: "autoSwitchWeeklyThreshold") as? Double ?? 99,
            useNearResetThreshold: defaults.object(forKey: "useNearResetThreshold") as? Bool ?? true,
            hysteresis: autoSwitchHysteresis
        )
    }

    /// Per-account "leave it alone until" timestamps. The usage endpoint enforces a
    /// long-window per-account quota - observed Retry-After values run into tens of
    /// minutes - so once an account is rate-limited, polling it again before the
    /// server-given deadline just burns more quota. Stale samples are kept meanwhile.
    private var usageRetryNotBefore: [UUID: Date] = [:]
    private var consecutiveUsageRateLimits: [UUID: Int] = [:]

    /// When the current/most recent refresh cycle began. Auto-switch uses it to
    /// tell which usage samples were taken by THIS cycle (already fresh — no
    /// verification request needed) versus retained from earlier ones.
    private var lastCycleStart: Date = .distantPast

    /// One switch (manual or automatic) may mutate live credentials at a time.
    /// `switchTo` suspends across subprocess and keychain work while the UI stays
    /// responsive, so without this a second switch — a user click during an
    /// auto-switch verification, or vice versa — could interleave keychain and
    /// ~/.claude.json writes with the first.
    @Published private(set) var isSwitching = false

    // MARK: - Auto-switch

    /// Whether proactive auto-switch is on (written by SettingsView via @AppStorage).
    private var autoSwitchEnabled: Bool {
        defaults.bool(forKey: "autoSwitchEnabled")
    }

    /// Session headroom for selecting a candidate. Weekly eligibility is checked
    /// separately against its threshold, without subtracting this margin.
    private let autoSwitchHysteresis: Double = 10

    /// Minimum gap between two automatic switches, to avoid rapid flip-flopping.
    private let autoSwitchCooldown: TimeInterval = 300

    private var lastAutoSwitchAt: Date?
    private var isEvaluatingAutoSwitch = false
    private var failedAutoSwitchVerifications: [UUID: Date] = [:]
    private var lastSwitchVerificationAttempt: [UUID: Date] = [:]

    // MARK: - Initialization

    init(restoringSavedState: Bool = true) {
        isPreview = !restoringSavedState
        // The UI preview uses an empty state and must never open credentials.
        guard restoringSavedState else { return }
        log.info("[init] Loading accounts from UserDefaults...")
        shouldAutoCaptureAccount = defaults.data(forKey: accountsKey) == nil
        loadAccounts()
        if let snapshot = LocalStatsSnapshot.load() {
            costSummary = snapshot.cost
            activityStats = snapshot.activity
            lastLocalStatsRefresh = snapshot.updatedAt
        }
        log.info("[init] Loaded \(self.accounts.count) accounts, active: \(self.activeAccount?.id.uuidString ?? "none")")
    }

    /// Test initializer: every account operation uses in-memory services and an
    /// isolated defaults suite. No account restoration or widget publication.
    init(claudeService: any ClaudeAccountClient, keychain: any AccountCredentialStore,
         defaults: UserDefaults, now: @escaping () -> Date = Date.init,
         pause: @escaping (TimeInterval) async -> Void = { _ in },
         localStatsCalculator: any LocalStatsCalculating = LocalStatsCalculator(),
         persistLocalStats: @escaping (LocalStatsSnapshot) -> Void = { _ in }) {
        isPreview = false
        self.claudeService = claudeService
        self.keychain = keychain
        self.defaults = defaults
        self.now = now
        self.pause = pause
        self.localStatsCalculator = localStatsCalculator
        self.persistLocalStats = persistLocalStats
        readsSupplementalLocalStats = false
        publishesWidgets = false
    }

    // MARK: - Refresh

    func refresh(allAccounts: Bool = false, forceActive: Bool = true) async {
        guard !isPreview, !refreshCycleRunning, !isEvaluatingAutoSwitch,
              !isLoggingIn, !isSwitching else { return }
        refreshCycleRunning = true
        isLoading = true
        defer {
            refreshCycleRunning = false
            isLoading = false
            scheduleAutoRefresh()
        }
        errorMessage = nil
        guard await refreshIdentity() else { return }
        let started = now()
        lastCycleStart = started
        let targets = RefreshPolicy.usageTargets(
            accounts: accounts, activeID: activeAccount?.id,
            lastAttempt: usageLastAttempt, retryNotBefore: usageRetryNotBefore,
            inactiveInterval: inactiveRefreshInterval, refreshAll: allAccounts,
            usageByAccount: accountUsage, asOf: now()
        ).filter { $0.id != activeAccount?.id || forceActive || activePollIsDue() }
        if targets.isEmpty { await evaluateAutoSwitch() }
        for target in targets {
            // A startup/manual sweep must not put all eight inactive accounts
            // ahead of the next active check or delay an urgent switch.
            if target.id != activeAccount?.id, activePollIsDue(), let active = activeAccount {
                await fetchAccountUsage(active)
                await evaluateAutoSwitch()
            }
            guard let account = accounts.first(where: { $0.id == target.id }) else { continue }
            // A candidate verification already performed in this sweep counts
            // as its refresh, including when it just became the active account.
            if (usageLastAttempt[account.id] ?? .distantPast) >= started { continue }
            await fetchAccountUsage(account)
            await evaluateAutoSwitch()
        }
        lastUsageRefresh = now()
        updateWidgetData()
        let interval = defaults.object(forKey: "localStatsInterval") as? Double ?? 0
        // Failures and cancellations count as attempts too, including after a
        // relaunch. A large history must not restart at every usage poll.
        let lastAttempt = defaults.object(forKey: "lastLocalStatsAttempt") as? Date
        let lastRun = [lastLocalStatsRefresh, lastAttempt].compactMap { $0 }.max()
        if RefreshPolicy.localStatsDue(lastRefresh: lastRun, interval: interval, asOf: now()) {
            refreshLocalStats()
        }
    }

    private func refreshIdentity() async -> Bool {
        guard !isRefreshing, !isLoggingIn, !isSwitching, !isEvaluatingAutoSwitch else { return false }
        isRefreshing = true
        defer { isRefreshing = false }
        identityVerified = false
        lastIdentityAttempt = now()
        claudeAvailable = await claudeService.isClaudeAvailable()
        guard claudeAvailable else { return false }
        do {
            let status = try await claudeService.getAuthStatus()
            updateActiveAccount(from: status)
            identityVerified = status.loggedIn && status.email != nil && status.email == activeAccount?.email
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if RefreshPolicy.isDue(lastAttempt: lastDiagnosticsAt, interval: 3600, asOf: now()) {
            diagnoseTokenHealth()
            lastDiagnosticsAt = now()
        }
        return true
    }

    private func activePollIsDue() -> Bool {
        let time = now()
        let id = activeAccount?.id
        guard id.map({ (usageRetryNotBefore[$0] ?? .distantPast) <= time }) ?? true else { return false }
        let cadence = RefreshPolicy.activeInterval(configured: configuredRefreshInterval)
        return RefreshPolicy.isDue(lastAttempt: id == nil ? lastIdentityAttempt : id.flatMap { usageLastAttempt[$0] },
                                   interval: cadence, asOf: time)
    }

    private func waitForUsageSpacing() async {
        if let lastUsageRequestAt {
            let delay = 1.5 - now().timeIntervalSince(lastUsageRequestAt)
            if delay > 0 { await pause(delay) }
        }
        lastUsageRequestAt = now()
    }

    /// Explicitly requested, or scheduled on its own much slower cadence.
    /// The single task prevents overlapping scans while account polling carries on.
    func refreshLocalStats() {
        guard !isPreview, localStatsTask == nil else { return }
        isRefreshingLocalStats = true
        isStoppingLocalStats = false
        localStatsMessage = nil
        localStatsProgress = "Preparing local statistics…"
        defaults.set(now(), forKey: "lastLocalStatsAttempt")
        let runID = UUID()
        localStatsRunID = runID
        localStatsTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.isRefreshingLocalStats = false
                self.isStoppingLocalStats = false
                self.localStatsRunID = nil
                self.localStatsTask = nil
            }
            do {
                let snapshot = try await self.localStatsCalculator.calculate(budget: .init()) { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self, self.localStatsRunID == runID, !self.isStoppingLocalStats else { return }
                        self.localStatsProgress = text
                    }
                }
                try Task.checkCancellation()
                self.costSummary = snapshot.cost
                self.activityStats = snapshot.activity
                if self.readsSupplementalLocalStats {
                    self.usageSummary = self.statsParser.getUsageSummary()
                    self.recentActivity = self.statsParser.getRecentActivity(days: 7)
                    self.activeSessions = self.statsParser.getActiveSessions()
                }
                self.lastLocalStatsRefresh = snapshot.updatedAt
                self.persistLocalStats(snapshot)
                self.updateWidgetData()
            } catch is CancellationError {
                self.localStatsMessage = "Calculation stopped. Previous statistics were kept."
            } catch let error as LocalStatsError {
                self.localStatsMessage = error.localizedDescription
            } catch {
                self.localStatsMessage = LocalStatsError.historyUnavailable.localizedDescription
            }
        }
    }

    func cancelLocalStats() {
        guard let localStatsTask else { return }
        isStoppingLocalStats = true
        localStatsProgress = "Stopping calculation…"
        localStatsTask.cancel()
    }

    /// Used by the isolated tests to await cleanup without polling the UI state.
    func waitForLocalStats() async { await localStatsTask?.value }

    func startAutoRefresh(interval: TimeInterval = 300) {
        guard !isPreview else { return }
        stopAutoRefresh()
        configuredRefreshInterval = RefreshPolicy.activeInterval(configured: interval)
        autoRefreshStarted = true
        scheduleAutoRefresh()
    }

    /// Exposed internally so tests can exercise the real scheduler's deadline
    /// after simulated CLI/network latency, without sleeping for five minutes.
    var nextAutomaticRefreshDate: Date {
        RefreshPolicy.nextAutomaticRefresh(lastIdentityAttempt: lastIdentityAttempt,
            lastUsageAttempt: activeAccount.flatMap { usageLastAttempt[$0.id] },
            configured: configuredRefreshInterval, asOf: now())
    }

    private func scheduleAutoRefresh(notBefore: Date? = nil) {
        guard autoRefreshStarted else { return }
        refreshTimer?.invalidate()
        let deadline = max(nextAutomaticRefreshDate, notBefore ?? .distantPast,
                           now().addingTimeInterval(0.1))
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAutomatically()
            }
        }
        timer.tolerance = 1
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func refreshAutomatically() async {
        guard !refreshCycleRunning, !isEvaluatingAutoSwitch, !isLoggingIn, !isSwitching else {
            // A busy operation must not turn a past deadline into a rapid retry loop.
            scheduleAutoRefresh(notBefore: now().addingTimeInterval(configuredRefreshInterval))
            return
        }
        await refresh(forceActive: false)
    }

    func stopAutoRefresh() {
        autoRefreshStarted = false
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Account Management

    func addAccount() async {
        guard !isPreview else { return }
        guard !isRefreshing, !isSwitching, !isLoggingIn, !isEvaluatingAutoSwitch else { return }
        log.info("[addAccount] Starting add current account flow...")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[addAccount] Aborted: Claude CLI not found")
            return
        }

        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn else {
                errorMessage = String(localized: "Not logged in to Claude. Run 'claude auth login' first.", bundle: L10n.bundle)
                log.error("[addAccount] Aborted: not logged in")
                return
            }
            guard let email = status.email else {
                errorMessage = shadowedIdentityMessage(status)
                log.error("[addAccount] Aborted: CLI reports authMethod=\(status.authMethod ?? "nil") without an account identity")
                return
            }
            log.info("[addAccount] Current auth: logged in, sub=\(status.subscriptionType ?? "nil")")

            if accounts.contains(where: { $0.email == email }) {
                updateActiveAccount(from: status)
                errorMessage = String(localized: "Account already exists", bundle: L10n.bundle)
                log.warning("[addAccount] Aborted: duplicate account")
                return
            }

            var account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: accounts.isEmpty
            )
            log.info("[addAccount] Created account model, id=\(account.id)")

            log.info("[addAccount] Capturing token from keychain...")
            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString, expectedEmail: account.email)
            if !captured {
                errorMessage = String(localized: "Could not capture auth token from keychain", bundle: L10n.bundle)
                log.error("[addAccount] Token capture failed!")
                return
            }
            log.info("[addAccount] Token captured successfully")

            for index in accounts.indices { accounts[index].isActive = false }
            account.isActive = true
            activeAccount = account
            identityVerified = true
            lastAutoSwitchAt = now()
            accounts.append(account)
            saveAccounts()
            log.info("[addAccount] Account saved. Total accounts: \(self.accounts.count)")
        } catch {
            errorMessage = error.localizedDescription
            log.error("[addAccount] Error: \(error.localizedDescription)")
        }
    }

    func loginNewAccount() async {
        guard !isPreview else { return }
        log.info("[loginNewAccount] ===== Starting login new account flow =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            log.error("[loginNewAccount] Aborted: Claude CLI not found")
            return
        }
        // One credential mutation at a time (same guard as switchTo). A login
        // entering while a switch is suspended mid-swap would back up the
        // WRONG live credential under the old active account's id — quietly
        // destroying that account's usable backup. Also blocks double-clicks.
        guard !isRefreshing, !isSwitching, !isLoggingIn, !isEvaluatingAutoSwitch else {
            log.warning("[loginNewAccount] Skipped: a switch or another login is in progress")
            return
        }

        isLoggingIn = true
        identityVerified = false
        errorMessage = nil

        do {
            // 1. Back up current account (token + oauthAccount) before login overwrites them
            if let current = activeAccount {
                log.info("[loginNewAccount] Step 1: Backing up current account (\(current.email))...")
                guard claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString, expectedEmail: current.email) else {
                    throw ClaudeServiceError.backupWriteFailed
                }
            } else {
                log.info("[loginNewAccount] Step 1: No active account, skipping backup")
            }

            // 2. Run `claude auth login` — this overwrites both keychain and ~/.claude.json
            log.info("[loginNewAccount] Step 2: Running `claude auth login`...")
            try await claudeService.login()
            log.info("[loginNewAccount] Step 2: Login process completed")

            // 3. Read the new identity from ~/.claude.json
            log.info("[loginNewAccount] Step 3: Reading post-login state...")
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 3: Not logged in after login!")
                isLoggingIn = false
                return
            }
            guard let email = status.email else {
                errorMessage = shadowedIdentityMessage(status)
                log.error("[loginNewAccount] Step 3: CLI reports authMethod=\(status.authMethod ?? "nil") without an account identity")
                isLoggingIn = false
                return
            }
            log.info("[loginNewAccount] Step 3: Logged in as \(email)")

            // 4. Check for duplicate — if exists, refresh its backup and make it
            // the active account. The login DID change what the CLI is
            // authenticated as; returning without updating our model left the
            // menu bar and switcher presenting an account the CLI was no longer
            // using. The capture CAN also fail (e.g. the backup store refuses
            // writes while unreadable); claiming "credentials refreshed" then
            // would leave a stale backup behind an explicit success message.
            if let existing = accounts.firstIndex(where: { $0.email == email }) {
                log.info("[loginNewAccount] Step 4: Account already exists, refreshing backup and marking it active")
                let captured = claudeService.captureCurrentCredentials(forAccountId: accounts[existing].id.uuidString, expectedEmail: accounts[existing].email)
                for i in accounts.indices {
                    accounts[i].isActive = (i == existing)
                }
                accounts[existing].lastUsed = now()
                activeAccount = accounts[existing]
                // A login is a deliberate account choice; grant it the same
                // auto-switch grace period a manual switch gets.
                lastAutoSwitchAt = now()
                saveAccounts()
                if captured {
                    errorMessage = String(localized: "Account already exists - credentials refreshed", bundle: L10n.bundle)
                } else {
                    log.error("[loginNewAccount] Step 4: Backup capture FAILED for existing account")
                    errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                }
                isLoggingIn = false
                return
            }

            // 5. Create new account and capture credentials (token + oauthAccount)
            let account = Account(
                email: email,
                displayName: status.orgName ?? email,
                provider: .claudeCode,
                orgName: status.orgName,
                subscriptionType: status.subscriptionType,
                isActive: true
            )
            log.info("[loginNewAccount] Step 5: Created account, id=\(account.id)")

            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString, expectedEmail: account.email)
            if !captured {
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[loginNewAccount] Step 5: Capture failed!")
                isLoggingIn = false
                return
            }

            // 6. Mark new account as active
            for i in accounts.indices {
                accounts[i].isActive = false
            }
            accounts.append(account)
            activeAccount = account
            // A login is a deliberate account choice; grant it the same
            // auto-switch grace period a manual switch gets.
            lastAutoSwitchAt = now()
            saveAccounts()
            log.info("[loginNewAccount] Step 6: New account active. Total: \(self.accounts.count)")

            isLoggingIn = false
            await refresh()
            log.info("[loginNewAccount] ===== Login completed =====")
        } catch {
            errorMessage = error.localizedDescription
            isLoggingIn = false
            log.error("[loginNewAccount] Error: \(error.localizedDescription)")
        }
    }

    func updateAccountLabel(_ account: Account, label: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        accounts[index].customLabel = (trimmed?.isEmpty == true) ? nil : trimmed
        if accounts[index].isActive {
            activeAccount = accounts[index]
        }
        saveAccounts()
        updateWidgetData()
        log.info("[updateAccountLabel] Set label for \(account.email): \(trimmed ?? "nil")")
    }

    /// Changes future automatic selection only. Pausing the active account
    /// does not interrupt it, and manual switching never clears the pause.
    func setAccountRotationPaused(_ account: Account, paused: Bool) {
        guard !isSwitching,
              let index = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[index].isRotationPaused != paused else { return }
        accounts[index].isRotationPaused = paused
        if activeAccount?.id == account.id { activeAccount = accounts[index] }
        if !isPreview { saveAccounts() }
        log.info("[rotation] Account \(account.id) paused=\(paused)")
    }

    func removeAccount(_ account: Account) async {
        guard !isPreview else { return }
        guard !isRefreshing, !isSwitching, !isLoggingIn, !isEvaluatingAutoSwitch else { return }
        log.info("[removeAccount] Removing account \(account.id)")
        guard accounts.contains(where: { $0.id == account.id }) else { return }
        if activeAccount?.id == account.id, let replacement = accounts.first(where: { $0.id != account.id }) {
            // Keep the source account and backup until an actual switch succeeds.
            guard await performSwitch(to: replacement, refreshAfter: false) else { return }
        }
        guard keychain.removeAccountBackup(forAccountId: account.id.uuidString) else {
            errorMessage = "Could not remove the saved credentials. The account was kept."
            return
        }
        accounts.removeAll { $0.id == account.id }
        // Drop every per-account cache too, or a re-added account inherits the
        // removed one's readings, error banner and rate-limit park.
        accountUsage[account.id] = nil
        accountUsageSampledAt[account.id] = nil
        accountUsageErrors[account.id] = nil
        usageRetryNotBefore[account.id] = nil
        consecutiveUsageRateLimits[account.id] = nil
        usageLastAttempt[account.id] = nil
        failedAutoSwitchVerifications[account.id] = nil
        lastSwitchVerificationAttempt[account.id] = nil
        if activeAccount?.id == account.id { activeAccount = nil }
        shouldAutoCaptureAccount = false
        saveAccounts(refreshWidget: true)
        log.info("[removeAccount] Done. Remaining accounts: \(self.accounts.count)")
    }

    func switchTo(_ account: Account) async {
        guard !isPreview else { return }
        guard !isRefreshing, !isSwitching, !isLoggingIn, !isEvaluatingAutoSwitch else { return }
        _ = await performSwitch(to: account)
    }

    @discardableResult
    private func performSwitch(to requested: Account, refreshAfter: Bool = true) async -> Bool {
        guard let account = accounts.first(where: { $0.id == requested.id }), activeAccount?.id != account.id else {
            log.info("[switchTo] No switch needed (same account or no active account)")
            return false
        }
        let currentActive = activeAccount
        log.info("[switchTo] Switching to \(account.id)")

        // One credential mutation at a time: a switch already in flight (its
        // awaits leave the main actor free) or a running login must finish
        // before another switch may touch the keychain and ~/.claude.json.
        guard !isRefreshing, !isSwitching, !isLoggingIn else {
            log.warning("[switchTo] Skipped: another switch or a login is in progress")
            return false
        }
        isSwitching = true

        // Pre-switch: resolve the target's backup ONCE and hand it down.
        // "The store is briefly unreadable" and "no backup exists" are
        // different problems with different fixes — don't send the user to
        // re-authenticate over a locked keychain. Passing the resolved backup
        // into switchAccount also removes its second lookup, which collapsed
        // exactly this distinction one layer down.
        let targetBackup: AccountBackup
        switch keychain.lookupAccountBackup(forAccountId: account.id.uuidString) {
        case .found(let backup):
            targetBackup = backup
        case .missing:
            log.error("[switchTo] ABORT: no backup for target account")
            errorMessage = String(localized: "No stored credentials for \(account.email). Use re-authenticate to fix.", bundle: L10n.bundle)
            isSwitching = false
            return false
        case .storeUnavailable:
            log.error("[switchTo] ABORT: backup store unreadable right now")
            errorMessage = String(localized: "Credential storage is temporarily unavailable. Try again shortly.", bundle: L10n.bundle)
            isSwitching = false
            return false
        }

        // Any switch, deliberate or automatic, restarts the auto-switch cooldown:
        // a user who knowingly picks an account sitting at 95% must not be
        // auto-switched away from it seconds later by the refresh that follows.
        lastAutoSwitchAt = now()

        isLoading = true
        let outcome: ClaudeService.SwitchOutcome
        do {
            outcome = try await claudeService.switchAccount(from: currentActive, to: account, targetBackup: targetBackup)

            for i in accounts.indices {
                accounts[i].isActive = (accounts[i].id == account.id)
                if accounts[i].id == account.id {
                    accounts[i].lastUsed = now()
                }
            }
            activeAccount = accounts.first(where: { $0.id == account.id })
            identityVerified = outcome.shadowedBy == nil
            saveAccounts()
        } catch {
            identityVerified = false
            if case CredentialSwitchTransaction.Failure.rollbackFailed = error { clearActiveAccount() }
            errorMessage = error.localizedDescription
            isLoading = false
            isSwitching = false
            updateWidgetData()
            log.error("[switchTo] Switch failed: \(error.localizedDescription)")
            return false
        }
        isSwitching = false
        isLoading = false
        updateWidgetData()
        if refreshAfter { await refresh() }
        // `refresh()` clears errorMessage, so surface the warning afterwards.
        if let shadowedBy = outcome.shadowedBy {
            errorMessage = String(localized: "Switched to \(account.email), but the Claude CLI is authenticating via \(shadowedBy) instead of the stored login, so it will not use this account.", bundle: L10n.bundle)
        }
        log.info("[switchTo] ===== Switch completed =====")
        return true
    }

    // MARK: - Auto-switch

    /// Whether an account can be switched to right now: it must have a stored
    /// backup token and not be flagged expired (an expired backup would fail the
    /// switch verification, or silently swap in a dead session).
    private func isSwitchable(_ account: Account) -> Bool {
        guard keychain.getAccountBackup(forAccountId: account.id.uuidString) != nil else { return false }
        if let error = accountUsageErrors[account.id], error.isExpired { return false }
        return true
    }

    /// Evaluate the configured thresholds and the near-limit rate-limit fallback,
    /// then verify an eligible same-provider account using the selected policy.
    /// Called after every completed refresh. Safe to call repeatedly.
    ///
    /// Candidates are ranked from whatever samples we hold, then the chosen one
    /// is VERIFIED before committing: round-robin polling can leave a candidate's
    /// sample several cycles old, and quota may have been consumed on it from
    /// another device meanwhile. A sample taken by this very cycle counts as
    /// verified; otherwise one fresh reading is taken — a single request per
    /// (rare, threshold-gated, cooldown-gated) switch attempt, not the per-cycle
    /// burst the round-robin exists to prevent.
    private func evaluateAutoSwitch() async {
        guard autoSwitchEnabled, identityVerified, !isRefreshing, !isEvaluatingAutoSwitch else { return }
        guard !isLoggingIn, !isSwitching, let active = activeAccount else { return }

        let activeSampledThisCycle = RefreshPolicy.isFreshSample(accountUsageSampledAt[active.id],
                                                                 cycleStart: lastCycleStart, asOf: now())
        let policy = autoSwitchPolicy
        if AutoSwitchEngine.isCoolingDown(lastSwitch: lastAutoSwitchAt, cooldown: autoSwitchCooldown,
                                          activeUsage: accountUsage[active.id], activeSampleIsFresh: activeSampledThisCycle,
                                          policy: policy, asOf: now()) {
            return
        }

        // Only consider same-provider accounts (a Claude switch never touches Codex/Gemini).
        let time = now()
        let candidates = accounts.filter {
            $0.provider == active.provider && $0.id != active.id && !$0.isRotationPaused
                && (usageRetryNotBefore[$0.id] ?? .distantPast) <= time
                && (failedAutoSwitchVerifications[$0.id] ?? .distantPast).addingTimeInterval(2 * configuredRefreshInterval) <= time
        }
        let ranked = AutoSwitchEngine.rankedTargets(
            active: active,
            candidates: candidates,
            usageByAccount: accountUsage,
            isSwitchable: { [unowned self] in self.isSwitchable($0) },
            activeSampledThisCycle: activeSampledThisCycle,
            policy: policy,
            activeUsageIsRateLimited: accountUsageErrors[active.id]?.isRateLimited == true,
            asOf: now()
        )
        guard !ranked.isEmpty else { return }

        isEvaluatingAutoSwitch = true
        defer { isEvaluatingAutoSwitch = false }

        let reason = policy.shouldSwitch(accountUsage[active.id], asOf: now(), requireKnownWindow: !activeSampledThisCycle)
            ? "reached a limit" : "has rate-limited usage checks near a limit; switching early"
        log.info("[autoSwitch] Active \(active.id) \(reason) (session threshold \(policy.sessionLimit)%, weekly threshold \(policy.weeklyLimit(for: accountUsage[active.id], asOf: now()))%, strategy \(policy.strategy.rawValue)); \(ranked.count) candidate(s)")

        // At most ONE fresh verification request per evaluation. Later ranked
        // candidates only qualify via samples this cycle already took.
        // Reconsideration and inactive sweeps may evaluate several times. They
        // must not issue extra candidate checks between configured refreshes.
        var freshRequestBudget = RefreshPolicy.isDue(lastAttempt: lastSwitchVerificationAttempt[active.id],
                                                      interval: configuredRefreshInterval, asOf: now()) ? 1 : 0
        for target in ranked {
            // A previous candidate's network request can yield to a pause click.
            guard accounts.contains(where: { $0.id == target.id && !$0.isRotationPaused }) else { continue }
            let usage: UsageAPIResponse?
            if RefreshPolicy.isFreshSample(accountUsageSampledAt[target.id], cycleStart: lastCycleStart, asOf: now()) {
                // Sampled by this very cycle — that IS a fresh reading.
                usage = accountUsage[target.id]
            } else if freshRequestBudget > 0 {
                freshRequestBudget -= 1
                lastSwitchVerificationAttempt[active.id] = now()
                usage = await fetchUsageNow(for: target)
                if let usage {
                    recordUsage(usage, for: target)
                }
            } else {
                continue
            }

            guard policy.canSelect(usage, asOf: now()) else {
                failedAutoSwitchVerifications[target.id] = now()
                log.info("[autoSwitch] Candidate \(target.id) failed verification (\(AutoSwitchEngine.bindingUtilization(usage, asOf: now()).map { String(format: "%.0f%%", $0) } ?? "no reading")); trying next")
                continue
            }

            // Re-check volatile state: the verification await above can span a
            // login starting, a timer-tick refresh beginning, or a manual switch
            // the user just clicked (which updates `activeAccount` only after
            // its subprocess work finishes — hence the explicit isSwitching).
            guard autoSwitchEnabled, autoSwitchPolicy == policy, !isLoggingIn, !isRefreshing, !isSwitching,
                  activeAccount?.id == active.id, accounts.contains(where: { $0.id == target.id }) else {
                log.info("[autoSwitch] State changed during verification; standing down")
                return
            }
            // The user may have paused this very candidate during verification.
            // Read the current account, not the ranked snapshot from before the await.
            guard accounts.contains(where: { $0.id == target.id && !$0.isRotationPaused }) else { continue }

            // The active window may have reset while the network request was
            // in flight. Re-evaluate the trigger with the current clock.
            guard policy.shouldSwitch(accountUsage[active.id], asOf: now(), requireKnownWindow: !activeSampledThisCycle)
                    || (accountUsageErrors[active.id]?.isRateLimited == true
                        && policy.shouldSwitchAfterRateLimit(accountUsage[active.id], asOf: now())) else { return }
            failedAutoSwitchVerifications[target.id] = nil

            log.info("[autoSwitch] Switching to \(target.id), verified below both limits")
            lastAutoSwitchAt = now()
            // switchTo() calls refresh() -> evaluateAutoSwitch() again, but the
            // re-entrancy flag + the freshly-set cooldown make that a no-op.
            // The active account visibly changes in the menu bar as feedback.
            await performSwitch(to: target)
            return
        }
        log.info("[autoSwitch] Threshold reached but no candidate verified; staying put")
    }

    /// Take one fresh usage reading for an account right now, refreshing its
    /// stored credential in place first if the access token has expired.
    /// Returns nil when no reading could be taken. 429s are parked with the same
    /// scheme the polling loop uses, so verification can never leak around it.
    private func fetchUsageNow(for account: Account) async -> UsageAPIResponse? {
        if let notBefore = usageRetryNotBefore[account.id], notBefore > now() {
            log.info("[fetchUsageNow] \(account.id) is rate-limit parked; no fresh reading available")
            return nil
        }
        usageLastAttempt[account.id] = now()

        let tokenJSON = (account.id == activeAccount?.id)
            ? keychain.readClaudeToken()
            : keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
        guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
            return nil
        }

        do {
            await waitForUsageSpacing()
            return try await claudeService.getUsageLimits(accessToken: accessToken)
        } catch ClaudeService.UsageError.expired where account.id != activeAccount?.id {
            // Handle every refresh outcome, not just success: collapsing a dead
            // grant (or a lost rotation) to a plain nil here would leave the
            // account looking healthy — stale usage still shown, still eligible
            // for auto-switch — until a later polling pass happened to notice.
            switch await refreshBackupInPlace(for: account) {
            case .refreshed(let refreshed):
                guard let newToken = ClaudeService.extractAccessToken(from: refreshed) else { return nil }
                return await usageRespectingParking(accessToken: newToken, account: account)
            case .grantRejected, .noBackup, .rotationLost:
                accountUsage[account.id] = nil
                accountUsageSampledAt[account.id] = nil
                accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Session expired. Re-authenticate (↻) to fix.", bundle: L10n.bundle))
                return nil
            case .storeUnavailable:
                // Nothing spent, nothing lost; keep the stale sample and retry
                // on a later cycle.
                return nil
            }
        } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
            park(account, retryAfter: retryAfter)
            return nil
        } catch ClaudeService.UsageError.forbidden {
            clearForbiddenUsage(for: account)
            return nil
        } catch {
            log.warning("[fetchUsageNow] \(account.id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Re-authenticate an account by running `claude auth login` and capturing fresh credentials.
    func reauthenticateAccount(_ account: Account) async {
        guard !isPreview else { return }
        log.info("[reauth] ===== Re-authenticating account \(account.id) (\(account.email)) =====")
        guard claudeAvailable else {
            errorMessage = String(localized: "Claude CLI not found", bundle: L10n.bundle)
            return
        }
        // One credential mutation at a time — see loginNewAccount for why a
        // login during a suspended switch destroys a backup.
        guard !isRefreshing, !isSwitching, !isLoggingIn, !isEvaluatingAutoSwitch else {
            log.warning("[reauth] Skipped: a switch or another login is in progress")
            return
        }

        isLoggingIn = true
        identityVerified = false
        errorMessage = nil

        do {
            // 1. Back up current active account before login overwrites it
            if let current = activeAccount, current.id != account.id {
                log.info("[reauth] Backing up current account before login...")
                guard claudeService.captureCurrentCredentials(forAccountId: current.id.uuidString, expectedEmail: current.email) else {
                    throw ClaudeServiceError.backupWriteFailed
                }
            }

            // 2. Run login
            log.info("[reauth] Running `claude auth login`...")
            try await claudeService.login()

            // 3. Verify the login result matches the target account
            let status = try await claudeService.getAuthStatus()
            guard status.loggedIn else {
                errorMessage = String(localized: "Login did not complete", bundle: L10n.bundle)
                isLoggingIn = false
                return
            }
            guard let email = status.email else {
                errorMessage = shadowedIdentityMessage(status)
                log.error("[reauth] CLI reports authMethod=\(status.authMethod ?? "nil") without an account identity")
                isLoggingIn = false
                return
            }

            guard email == account.email else {
                updateActiveAccount(from: status)
                errorMessage = String(localized: "Logged in as \(email), but expected \(account.email). Credentials not updated.", bundle: L10n.bundle)
                log.error("[reauth] Email mismatch: got \(email), expected \(account.email)")
                isLoggingIn = false
                return
            }

            // 4. Capture the fresh token
            let captured = claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString, expectedEmail: account.email)
            log.info("[reauth] Token capture result: \(captured)")

            // 5. Update account metadata. Done even when the capture failed —
            // the CLI really is on this account now — but a failed capture must
            // be surfaced, not folded into "completed": the stored backup is
            // still the OLD credential, so a later switch away and back would
            // fail while the UI claimed everything was refreshed.
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].orgName = status.orgName
                accounts[index].subscriptionType = status.subscriptionType

                // Mark this account as active (it's what the CLI is now using)
                for i in accounts.indices {
                    accounts[i].isActive = (i == index)
                }
                activeAccount = accounts[index]
                // A re-authentication is a deliberate account choice; grant it
                // the same auto-switch grace period a manual switch gets.
                lastAutoSwitchAt = now()
                saveAccounts()
            }

            isLoggingIn = false
            await refresh()
            if captured {
                log.info("[reauth] ===== Re-authentication completed =====")
            } else {
                // Set AFTER refresh() — refresh clears errorMessage.
                errorMessage = String(localized: "Could not capture credentials", bundle: L10n.bundle)
                log.error("[reauth] ===== Re-authentication finished, but the backup capture FAILED =====")
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoggingIn = false
            log.error("[reauth] Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Usage

    /// Retain the last reading, but make the monitoring failure visible even
    /// when we have cached data. Every 429 path shares this progressive backoff.
    private func park(_ account: Account, retryAfter: TimeInterval?) {
        let failures = min(4, (consecutiveUsageRateLimits[account.id] ?? 0) + 1)
        consecutiveUsageRateLimits[account.id] = failures
        let parkFor = RefreshPolicy.rateLimitDelay(consecutiveFailures: failures,
                                                   configured: configuredRefreshInterval, retryAfter: retryAfter)
        usageRetryNotBefore[account.id] = now().addingTimeInterval(parkFor)
        accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: true,
            message: accountUsage[account.id] == nil
                ? "Usage checks are rate-limited. Retrying later."
                : "Usage checks paused (rate limit). Showing the last reading.")
        log.warning("[fetchUsage] \(account.id) rate-limited; parked for \(String(format: "%.0f", parkFor))s")
    }

    private func recordUsage(_ usage: UsageAPIResponse, for account: Account) {
        accountUsage[account.id] = usage
        accountUsageSampledAt[account.id] = now()
        accountUsageErrors[account.id] = nil
        usageRetryNotBefore[account.id] = nil
        consecutiveUsageRateLimits[account.id] = nil
        failedAutoSwitchVerifications[account.id] = nil
    }

    /// Fetch usage, honouring a 429 by parking the account. The post-refresh
    /// recovery paths previously wrapped this call in `try?`, which swallowed a
    /// 429 without parking it — leaking around the parking scheme and re-hitting
    /// a rate-limited account every cycle.
    private func usageRespectingParking(accessToken: String, account: Account) async -> UsageAPIResponse? {
        do {
            await waitForUsageSpacing()
            return try await claudeService.getUsageLimits(accessToken: accessToken)
        } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
            park(account, retryAfter: retryAfter)
            return nil
        } catch ClaudeService.UsageError.forbidden {
            clearForbiddenUsage(for: account)
            return nil
        } catch ClaudeService.UsageError.expired {
            accountUsage[account.id] = nil
            accountUsageSampledAt[account.id] = nil
            accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false,
                message: "Session expired. Re-authenticate to fix.")
            return nil
        } catch {
            log.warning("[fetchUsage] Post-refresh retry failed for \(account.id): \(error.localizedDescription)")
            return nil
        }
    }

    private enum BackupRefreshOutcome {
        /// New credential JSON, persisted to the store.
        case refreshed(String)
        /// The endpoint decided the grant is invalid: the refresh token is dead
        /// (rotated elsewhere or revoked). Only re-authentication fixes this.
        case grantRejected
        /// No stored backup exists for this account at all.
        case noBackup
        /// The store cannot be read or written right now. Nothing was spent;
        /// heals by itself on a later cycle.
        case storeUnavailable
        /// Worst case: the rotation succeeded but the result could not be
        /// persisted even after a retry. The old refresh token is spent and the
        /// new credential is gone — only re-authentication brings this account
        /// back. Deliberately NOT held in memory: a credential that exists only
        /// in volatile state while some paths read the (dead) stored one is the
        /// split-brain that broke the previous attempt at this feature.
        case rotationLost
    }

    /// Refresh a non-active account's stored credential in place via the OAuth
    /// token endpoint — no keychain swap, so no race with running Claude Code
    /// sessions.
    private func refreshBackupInPlace(for account: Account) async -> BackupRefreshOutcome {
        let accountId = account.id.uuidString

        let backup: AccountBackup
        switch keychain.lookupAccountBackup(forAccountId: accountId) {
        case .found(let found):
            backup = found
        case .missing:
            log.warning("[refreshBackup] No stored backup for \(account.id)")
            return .noBackup
        case .storeUnavailable:
            log.warning("[refreshBackup] Store unreadable for \(account.id); trying again next cycle")
            return .storeUnavailable
        }

        // Prove the store is writable BEFORE spending the refresh token: the
        // endpoint can rotate it, and a rotation that cannot be persisted kills
        // the account (old token dead server-side, new one lost, manual re-login
        // the only way back). Re-saving what was just read is idempotent, and
        // the failures that matter here (locked keychain, denied prompt) are
        // conditions rather than blips, so this turns them into a harmless
        // "try again next cycle".
        guard keychain.saveAccountBackup(token: backup.token, oauthAccount: backup.oauthAccount, forAccountId: accountId) else {
            log.error("[refreshBackup] Store not writable; skipping refresh for \(account.id) so its refresh token stays valid")
            return .storeUnavailable
        }

        switch await claudeService.refreshOAuthCredentials(backup.token) {
        case .success(let refreshed):
            if keychain.saveAccountBackup(token: refreshed, oauthAccount: backup.oauthAccount, forAccountId: accountId) {
                return .refreshed(refreshed)
            }
            // The probe passed moments ago, so this is likely a blip — one retry.
            await pause(1)
            if keychain.saveAccountBackup(token: refreshed, oauthAccount: backup.oauthAccount, forAccountId: accountId) {
                return .refreshed(refreshed)
            }
            log.error("[refreshBackup] Rotation succeeded but the store write failed twice for \(account.id); the account needs re-authentication")
            return .rotationLost

        case .rejected:
            log.warning("[refreshBackup] Refresh grant rejected for \(account.id); the refresh token is dead")
            return .grantRejected

        case .transient:
            log.warning("[refreshBackup] Refresh attempt for \(account.id) failed transiently (network/server); will retry")
            return .storeUnavailable
        }
    }

    private func fetchAccountUsage(_ account: Account) async {
        guard !isRefreshing, !isLoggingIn, !isSwitching, !isEvaluatingAutoSwitch,
              (usageRetryNotBefore[account.id] ?? .distantPast) <= now() else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if account.id == activeAccount?.id { lastCycleStart = now() }
        await waitForUsageSpacing()
        usageLastAttempt[account.id] = now()
        let tokenJSON: String?
        if account.id == activeAccount?.id {
            tokenJSON = keychain.readClaudeToken()
        } else {
            tokenJSON = keychain.getAccountBackup(forAccountId: account.id.uuidString)?.token
        }
        guard let tokenJSON, let accessToken = ClaudeService.extractAccessToken(from: tokenJSON) else {
            log.warning("[fetchUsage] No token for \(account.email), skipping")
            accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false,
                message: "Could not read saved credentials. Check keychain access.")
            return
        }
        do {
            // A rate limit parks this account immediately. Sleeping/retrying
            // here would delay active-account monitoring behind idle accounts.
            let usage = try await claudeService.getUsageLimits(accessToken: accessToken)
            recordUsage(usage, for: account)
            log.info("[fetchUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
        } catch ClaudeService.UsageError.forbidden {
            // No active Pro/Max subscription on this account (e.g. the plan
            // lapsed) - usage is meaningless until it recovers. Observed as:
            // {"error":{"type":"permission_error","message":"OAuth
            // authentication is currently not allowed for this organization."}}
            log.warning("[fetchUsage] \(account.email) forbidden (no active subscription?)")
            clearForbiddenUsage(for: account)
        } catch ClaudeService.UsageError.rateLimited(let retryAfter) {
            // Preserve the sample and its timestamp. The warning stays visible
            // alongside it, and a known near-limit window can trigger failover.
            park(account, retryAfter: retryAfter)
        } catch ClaudeService.UsageError.expired {
            log.warning("[fetchUsage] Token expired for \(account.email)")
            if account.id == activeAccount?.id {
                // Active account: delegated refresh via `claude auth status` is safe (no keychain swap)
                do {
                    let status = try await claudeService.getAuthStatus()
                    updateActiveAccount(from: status)
                    identityVerified = status.loggedIn && status.email == account.email
                    guard identityVerified else { return }
                    log.info("[fetchUsage] Delegated refresh completed for active account.")
                    // Re-read refreshed token and retry
                    if let refreshedJSON = keychain.readClaudeToken(),
                       let refreshedToken = ClaudeService.extractAccessToken(from: refreshedJSON),
                       let usage = await usageRespectingParking(accessToken: refreshedToken, account: account) {
                        recordUsage(usage, for: account)
                        log.info("[fetchUsage] Recovered \(account.email) via delegated refresh.")
                    }
                } catch {
                    log.error("[fetchUsage] Delegated refresh failed for active account: \(error.localizedDescription)")
                    accountUsage[account.id] = nil
                    accountUsageSampledAt[account.id] = nil
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Token expired. Switch to refresh.", bundle: L10n.bundle))
                }
            } else {
                // Non-active account: refresh the backup credential in place via
                // the OAuth token endpoint - no keychain swap, so no race with
                // running Claude Code sessions. Access tokens only live a few
                // hours, so without this every non-active account would sit in
                // a permanent "Token expired" state between switches.
                switch await refreshBackupInPlace(for: account) {
                case .refreshed(let refreshed):
                    log.info("[fetchUsage] Silently refreshed backup for \(account.email); retrying usage")
                    if let newToken = ClaudeService.extractAccessToken(from: refreshed),
                       let usage = await usageRespectingParking(accessToken: newToken, account: account) {
                        recordUsage(usage, for: account)
                        log.info("[fetchUsage] \(account.email): session=\(usage.fiveHour?.utilization ?? -1)%, weekly=\(usage.sevenDay?.utilization ?? -1)%")
                    }
                case .grantRejected, .noBackup, .rotationLost:
                    // Only re-authentication mints a new refresh token or a
                    // new backup — an honest dead end until the user acts.
                    // (.rotationLost is the loudest of the three; its log
                    // line already says exactly what was lost and why.)
                    accountUsage[account.id] = nil
                    accountUsageSampledAt[account.id] = nil
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: true, isRateLimited: false, message: String(localized: "Session expired. Re-authenticate (↻) to fix.", bundle: L10n.bundle))
                case .storeUnavailable:
                    // Nothing was spent and nothing is lost; this heals by
                    // itself on a later cycle. Keep the stale sample.
                    accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Could not save the refreshed sign-in; will retry automatically.", bundle: L10n.bundle))
                }
            }
        } catch {
            log.error("[fetchUsage] Failed to get usage for \(account.email): \(error.localizedDescription)")
            accountUsage[account.id] = nil
            accountUsageSampledAt[account.id] = nil
            accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false, message: String(localized: "Could not fetch usage: \(error.localizedDescription)", bundle: L10n.bundle))
        }
    }

    // MARK: - Diagnostics

    private func clearForbiddenUsage(for account: Account) {
        accountUsage[account.id] = nil
        accountUsageSampledAt[account.id] = nil
        accountUsageErrors[account.id] = UsageErrorState(isExpired: false, isRateLimited: false,
            message: String(localized: "No active subscription on this account (OAuth not allowed).", bundle: L10n.bundle))
    }

    /// Message for the case where the CLI *is* authenticated but reports no
    /// account, because a credential source outranking the stored claude.ai login
    /// is in play. Without this the user only saw "Not logged in" / "Login did not
    /// complete" and re-authorized in a loop that could never help (issue #18).
    private func shadowedIdentityMessage(_ status: AuthStatus) -> String {
        let method = status.shadowingAuthMethod ?? "unknown"
        return String(localized: "Claude CLI is authenticating via \(method) instead of a stored claude.ai login, so it reports no account. Unset ANTHROPIC_AUTH_TOKEN / CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_PROFILE and remove any apiKeyHelper, then try again.", bundle: L10n.bundle)
    }

    /// Passive health check — verifies backup existence and identity consistency.
    private func diagnoseTokenHealth() {
        guard !accounts.isEmpty else { return }

        log.info("[diagnose] === Health Check ===")
        log.info("[diagnose] Accounts: \(self.accounts.count), active: \(self.activeAccount?.email ?? "none")")

        // Check live oauthAccount identity
        if let liveOAuth = keychain.readOAuthAccount() {
            let liveEmail = (liveOAuth["emailAddress"]?.value as? String) ?? "?"
            log.info("[diagnose] Live oauthAccount: \(liveEmail)")
        } else {
            log.warning("[diagnose] Live oauthAccount: MISSING")
        }

        // Check each account has a backup
        for account in accounts {
            if let backup = keychain.getAccountBackup(forAccountId: account.id.uuidString) {
                let backupEmail = (backup.oauthAccount["emailAddress"]?.value as? String) ?? "?"
                log.info("[diagnose] Backup [\(account.email)]: OK (email=\(backupEmail))")
            } else {
                log.warning("[diagnose] Backup [\(account.email)]: MISSING — switch will fail")
            }
        }

        log.info("[diagnose] === End Health Check ===")
    }

    // MARK: - Widget

    private func updateWidgetData() {
        guard !isPreview, publishesWidgets else { return }
        let widgetAccounts = accounts.map { account in
            let usage = accountUsage[account.id]
            let error = accountUsageErrors[account.id]
            return WidgetAccountData(
                email: account.displayEmail(obfuscated: !defaults.bool(forKey: "showFullEmail")),
                displayName: account.effectiveDisplayName(obfuscated: !defaults.bool(forKey: "showFullEmail")),
                subscriptionType: account.displaySubscriptionType,
                isActive: account.isActive,
                sessionUtilization: usage?.fiveHour?.utilization,
                sessionResetTime: usage?.fiveHour?.resetTimeString,
                weeklyUtilization: usage?.sevenDay?.utilization,
                weeklyResetTime: usage?.sevenDay?.resetTimeString,
                extraUsageEnabled: usage?.extraUsage?.isEnabled,
                hasError: error != nil,
                errorMessage: error?.message
            )
        }

        let data = WidgetData(
            accounts: widgetAccounts,
            todayCost: costSummary.todayCost,
            conversationTurns: activityStats.conversationTurns,
            activeCodingTime: activityStats.activeCodingTimeString,
            linesWritten: activityStats.linesWritten,
            modelUsage: activityStats.modelUsage,
            lastUpdated: lastUsageRefresh ?? now(),
            localStatsUpdatedAt: lastLocalStatsRefresh
        )
        let activeChanged = activeAccount?.id != lastWidgetAttemptActiveID
        // Frequent quota checks should not continually wake WidgetKit. Account
        // switches publish immediately; other changes are coalesced to a minute.
        guard activeChanged || RefreshPolicy.isDue(lastAttempt: lastWidgetAttempt, interval: 60, asOf: now()) else { return }
        if let previous = lastWidgetData, data.hasSameContent(as: previous),
           now().timeIntervalSince(previous.lastUpdated) < 900 { return }
        lastWidgetAttempt = now()
        lastWidgetAttemptActiveID = activeAccount?.id
        guard data.save() else { return }
        lastWidgetData = data
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Persistence

    private func loadAccounts() {
        guard let data = defaults.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            log.info("[loadAccounts] No saved accounts found")
            return
        }
        accounts = decoded
        activeAccount = accounts.first(where: \.isActive)
        log.info("[loadAccounts] Loaded \(decoded.count) accounts")
    }

    private func saveAccounts(refreshWidget: Bool = false) {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: accountsKey)
            log.debug("[saveAccounts] Saved \(self.accounts.count) accounts to UserDefaults")
        }
        if refreshWidget {
            updateWidgetData()
        }
    }

    private func updateActiveAccount(from status: AuthStatus) {
        guard status.loggedIn, let email = status.email else {
            if !status.loggedIn { clearActiveAccount() }
            return
        }
        if let index = accounts.firstIndex(where: { $0.email == email }) {
            var updated = accounts
            for i in updated.indices { updated[i].isActive = i == index }
            updated[index].orgName = status.orgName
            updated[index].subscriptionType = status.subscriptionType
            if accounts != updated {
                accounts = updated
                saveAccounts()
            }
            if activeAccount != updated[index] { activeAccount = updated[index] }
        } else if accounts.isEmpty, shouldAutoCaptureAccount {
            let account = Account(email: email, displayName: status.orgName ?? email,
                                  provider: .claudeCode, orgName: status.orgName,
                                  subscriptionType: status.subscriptionType, isActive: true)
            guard claudeService.captureCurrentCredentials(forAccountId: account.id.uuidString, expectedEmail: account.email) else { return }
            accounts.append(account)
            activeAccount = account
            shouldAutoCaptureAccount = false
            saveAccounts()
        } else {
            // An external login must never attach the new token's usage to a
            // previously active saved account or trigger a switch from it.
            clearActiveAccount()
        }
    }

    private func clearActiveAccount() {
        guard activeAccount != nil || accounts.contains(where: \.isActive) else { return }
        for index in accounts.indices { accounts[index].isActive = false }
        activeAccount = nil
        saveAccounts()
    }
}

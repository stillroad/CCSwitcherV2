import Foundation

/// Injectable boundaries let coordination tests exercise AppState without real
/// credentials, subprocesses, network access or the user's preferences.
@MainActor
protocol ClaudeAccountClient {
    func isClaudeAvailable() async -> Bool
    func getAuthStatus() async throws -> AuthStatus
    func getAccountEmail(accessToken: String) async throws -> String
    func getUsageLimits(accessToken: String) async throws -> UsageAPIResponse
    func refreshOAuthCredentials(_ credentialsJSON: String) async -> ClaudeService.OAuthRefreshResult
    func switchAccount(from currentAccount: Account?, to targetAccount: Account,
                       targetBackup: AccountBackup, expectedCurrentToken: String?) async throws -> ClaudeService.SwitchOutcome
    func captureCurrentCredentials(forAccountId accountId: String, expectedEmail: String) -> Bool
    func login() async throws
}

extension ClaudeService: ClaudeAccountClient {}

@MainActor
protocol AccountCredentialStore {
    func readClaudeToken() -> String?
    func readOAuthAccount() -> [String: AnyCodable]?
    func getAccountBackup(forAccountId accountId: String) -> AccountBackup?
    func lookupAccountBackup(forAccountId accountId: String) -> KeychainService.BackupLookup
    func saveAccountBackup(token: String, oauthAccount: [String: AnyCodable], forAccountId accountId: String) -> Bool
    func removeAccountBackup(forAccountId accountId: String) -> Bool
}

extension KeychainService: AccountCredentialStore {}

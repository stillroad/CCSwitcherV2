import Foundation

/// Both credential stores must agree before a switch is reported as successful.
/// The caller serializes this with login, removal and backup-token rotation.
@MainActor
enum CredentialSwitchTransaction {
    enum Failure: LocalizedError {
        case tokenWrite
        case identityWrite
        case rollbackFailed
        case credentialsChanged

        var errorDescription: String? {
            switch self {
            case .tokenWrite: return "Could not change the Claude token. The previous credentials were restored."
            case .identityWrite: return "Could not change the Claude identity. The previous credentials were restored."
            case .rollbackFailed: return "The account switch failed and the previous credentials could not be fully restored. Check keychain access and re-authenticate before continuing."
            case .credentialsChanged: return "Claude's login changed during the switch. The newer credentials were kept; the account will be checked again."
            }
        }
    }

    static func run<Outcome>(previous: AccountBackup, target: AccountBackup,
                             readToken: () -> String?,
                             writeToken: (String) -> Bool,
                             writeIdentity: ([String: AnyCodable]) -> Bool,
                             verify: () async throws -> Outcome) async throws -> Outcome {
        guard readToken() == previous.token else { throw Failure.credentialsChanged }
        do {
            guard writeToken(target.token) else { throw Failure.tokenWrite }
            guard writeIdentity(target.oauthAccount) else { throw Failure.identityWrite }
            return try await verify()
        } catch {
            // Verification awaits a subprocess. Another Claude window may have
            // renewed or replaced the login meanwhile. Never roll that fresh
            // credential back to an older (or cleared) source login.
            guard let live = readToken(), live == target.token || live == previous.token else {
                throw Failure.credentialsChanged
            }
            // Attempt both restorations even when one fails.
            let tokenRestored = writeToken(previous.token)
            let identityRestored = writeIdentity(previous.oauthAccount)
            guard tokenRestored && identityRestored else { throw Failure.rollbackFailed }
            throw error
        }
    }
}

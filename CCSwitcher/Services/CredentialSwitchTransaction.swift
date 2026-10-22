import Foundation

/// Both credential stores must agree before a switch is reported as successful.
/// The caller serializes this with login, removal and backup-token rotation.
@MainActor
enum CredentialSwitchTransaction {
    enum Failure: LocalizedError {
        case tokenWrite
        case identityWrite
        case rollbackFailed

        var errorDescription: String? {
            switch self {
            case .tokenWrite: return "Could not change the Claude token. The previous credentials were restored."
            case .identityWrite: return "Could not change the Claude identity. The previous credentials were restored."
            case .rollbackFailed: return "The account switch failed and the previous credentials could not be fully restored. Check keychain access and re-authenticate before continuing."
            }
        }
    }

    static func run<Outcome>(previous: AccountBackup, target: AccountBackup,
                             writeToken: (String) -> Bool,
                             writeIdentity: ([String: AnyCodable]) -> Bool,
                             verify: () async throws -> Outcome) async throws -> Outcome {
        do {
            guard writeToken(target.token) else { throw Failure.tokenWrite }
            guard writeIdentity(target.oauthAccount) else { throw Failure.identityWrite }
            return try await verify()
        } catch {
            // Attempt both restorations even when one fails.
            let tokenRestored = writeToken(previous.token)
            let identityRestored = writeIdentity(previous.oauthAccount)
            guard tokenRestored && identityRestored else { throw Failure.rollbackFailed }
            throw error
        }
    }
}

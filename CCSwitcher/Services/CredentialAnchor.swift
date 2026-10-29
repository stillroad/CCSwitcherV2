import Foundation

/// The profile file can be rewritten by an older Claude window. Keep ownership
/// tied to the actual credential instead. Only hashes are stored in preferences.
final class CredentialAnchorStore {
    private struct Anchor: Codable {
        let accountID: UUID
        var access: String
        var grant: String
        var desynced: Bool
    }

    private let defaults: UserDefaults
    private let key = "com.ccswitcher.liveCredentialAnchor.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var lastKnownAccountID: UUID? { load()?.accountID }

    func anchor(accountID: UUID, token: String) {
        guard let credential = OAuthCredential(token), credential.isComplete,
              let access = credential.accessToken else { return }
        save(Anchor(accountID: accountID, access: OAuthCredential.digest(access),
                    grant: credential.grantID, desynced: false))
    }

    func owns(accountID: UUID, token: String) -> Bool {
        owner(of: token) == accountID
    }

    func owner(of token: String) -> UUID? {
        guard let stored = load(),
              let credential = OAuthCredential(token), credential.isComplete,
              let access = credential.accessToken else { return nil }
        return stored.access == OAuthCredential.digest(access) || stored.grant == credential.grantID
            ? stored.accountID : nil
    }

    /// A changed profile alone never transfers a credential to another account.
    /// After a profile mismatch, an unfamiliar rotated grant is ambiguous: stop
    /// attributing it until a deliberate login/switch establishes ownership.
    func resolve(token: String, claimedID: UUID?, matchingBackup: () -> UUID?) -> UUID? {
        guard let credential = OAuthCredential(token), credential.isComplete,
              let access = credential.accessToken else { return nil }
        let fingerprint = OAuthCredential.digest(access)
        if var stored = load() {
            if stored.access == fingerprint || stored.grant == credential.grantID {
                stored.desynced = stored.desynced || (claimedID != nil && claimedID != stored.accountID)
                stored.access = fingerprint
                stored.grant = credential.grantID
                save(stored)
                return stored.accountID
            }
            if let known = matchingBackup() {
                anchor(accountID: known, token: token)
                return resolve(token: token, claimedID: claimedID, matchingBackup: { nil })
            }
            guard !stored.desynced, claimedID == stored.accountID else { return nil }
            // Normal renewal by Claude while the identity remained consistent.
            stored.access = fingerprint
            stored.grant = credential.grantID
            save(stored)
            return stored.accountID
        }
        guard let known = matchingBackup() else { return nil }
        anchor(accountID: known, token: token)
        // Record a mismatch during bootstrap too.
        return resolve(token: token, claimedID: claimedID, matchingBackup: { nil })
    }

    func forget(accountID: UUID) {
        if lastKnownAccountID == accountID { defaults.removeObject(forKey: key) }
    }

    private func load() -> Anchor? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Anchor.self, from: data)
    }

    private func save(_ value: Anchor) {
        guard let data = try? JSONEncoder().encode(value), data != defaults.data(forKey: key) else { return }
        defaults.set(data, forKey: key)
    }
}

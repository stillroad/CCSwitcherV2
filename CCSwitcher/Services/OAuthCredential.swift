import Foundation
import CryptoKit

/// Local inspection only. Access-token expiry is not the expiry of the browser
/// login/refresh grant; the provider can reject that grant without advance notice.
struct OAuthCredential {
    static let renewalMargin: TimeInterval = 15 * 60

    let accessToken: String?
    let refreshToken: String?
    let expiresAt: Date?

    init?(_ json: String) {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        func nonempty(_ value: Any?) -> String? {
            guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        accessToken = nonempty(oauth["accessToken"])
        refreshToken = nonempty(oauth["refreshToken"])
        if let milliseconds = oauth["expiresAt"] as? Double,
           milliseconds.isFinite, milliseconds > 0 {
            expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
        } else {
            expiresAt = nil
        }
    }

    var isComplete: Bool { accessToken != nil && refreshToken != nil && expiresAt != nil }
    /// Claude leaves this shape behind when its refresh grant is rejected.
    var isCleared: Bool { accessToken == nil && refreshToken == nil }

    func needsRenewal(asOf now: Date, margin: TimeInterval = Self.renewalMargin) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) <= margin
    }

    /// Only a hash is persisted outside Keychain. Tie rejection to the refresh
    /// grant so a new browser login can clear it, but a usage success cannot.
    var grantID: String {
        Self.digest(refreshToken ?? accessToken ?? "cleared")
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func canBackUp(_ json: String) -> Bool { OAuthCredential(json)?.isComplete == true }
}

struct AccountAuthHealth: Equatable {
    enum Kind { case ready, renewalDue, temporarilyUnavailable, needsReauthentication }
    let kind: Kind
    let message: String
    let accessExpiresAt: Date?

    var needsReauthentication: Bool { kind == .needsReauthentication }
}

import XCTest
@testable import CCSwitcherPolicy

final class CredentialAnchorTests: XCTestCase {
    private func token(_ access: String, grant: String = "grant") -> String {
        "{\"claudeAiOauth\":{\"accessToken\":\"\(access)\",\"refreshToken\":\"\(grant)\",\"expiresAt\":2000000000000}}"
    }

    func testProfileOnlyChangeDoesNotChangeOwnerAndSurvivesRestart() {
        let suite = "AnchorTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CredentialAnchorStore(defaults: defaults), a = UUID(), b = UUID()
        store.anchor(accountID: a, token: token("access"))
        XCTAssertEqual(store.resolve(token: token("access"), claimedID: b, matchingBackup: { nil }), a)
        let restored = CredentialAnchorStore(defaults: defaults)
        XCTAssertTrue(restored.owns(accountID: a, token: token("access")))
        XCTAssertFalse(restored.owns(accountID: b, token: token("access")))
        XCTAssertNil(restored.resolve(token: token("rotated", grant: "rotated-grant"), claimedID: b, matchingBackup: { nil }))
    }

    func testNormalRotationAndDeliberateSwitchEstablishOwnership() {
        let suite = "AnchorTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CredentialAnchorStore(defaults: defaults), a = UUID(), b = UUID()
        store.anchor(accountID: a, token: token("access"))
        XCTAssertEqual(store.resolve(token: token("rotated", grant: "new-grant"), claimedID: a, matchingBackup: { nil }), a)
        store.anchor(accountID: b, token: token("b", grant: "b-grant"))
        XCTAssertTrue(store.owns(accountID: b, token: token("b", grant: "b-grant")))
    }

    func testBootstrapRequiresUniqueBackupRatherThanProfileAssertion() {
        let suite = "AnchorTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CredentialAnchorStore(defaults: defaults), a = UUID(), b = UUID()
        XCTAssertNil(store.resolve(token: token("access"), claimedID: b, matchingBackup: { nil }))
        XCTAssertEqual(store.resolve(token: token("access"), claimedID: b, matchingBackup: { a }), a)
        XCTAssertNil(store.resolve(token: token("new", grant: "new"), claimedID: b, matchingBackup: { nil }))
    }

    func testOnlyExplicitRejectedLoginShapePermitsRecovery() {
        let rejected = "{\"claudeAiOauth\":{\"accessToken\":\"\",\"refreshToken\":\"\",\"expiresAt\":0}}"
        XCTAssertEqual(OAuthCredential(rejected)?.isRejectedLogin, true)
        for json in ["{}", "broken", "{\"claudeAiOauth\":{}}",
                     "{\"claudeAiOauth\":{\"accessToken\":null,\"refreshToken\":null,\"expiresAt\":0}}", token("healthy")] {
            XCTAssertNotEqual(OAuthCredential(json)?.isRejectedLogin, true)
        }
    }
}

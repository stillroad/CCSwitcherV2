import XCTest
@testable import CCSwitcherPolicy

final class OAuthCredentialTests: XCTestCase {
    func testClearedLoginCannotReplaceBackupOrSupplyEmptyBearerToken() {
        for json in ["{}", "broken", "{\"claudeAiOauth\":{}}",
                     "{\"claudeAiOauth\":{\"accessToken\":\"\",\"refreshToken\":\"\",\"expiresAt\":0}}",
                     "{\"claudeAiOauth\":{\"accessToken\":\" \",\"refreshToken\":null,\"expiresAt\":0}}"] {
            XCTAssertFalse(OAuthCredential.canBackUp(json))
            XCTAssertNil(ClaudeService.extractAccessToken(from: json))
        }
    }

    func testAccessExpiryDoesNotMakeRenewableBackupUnsavable() throws {
        let json = "{\"claudeAiOauth\":{\"accessToken\":\"test-access\",\"refreshToken\":\"test-refresh\",\"expiresAt\":1000}}"
        let credential = try XCTUnwrap(OAuthCredential(json))
        XCTAssertTrue(OAuthCredential.canBackUp(json))
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1))
        XCTAssertTrue(credential.needsRenewal(asOf: Date()))
    }

    func testRenewalMarginUsesIssuanceExpiryAndGrantIdentitySurvivesAccessRenewal() throws {
        let now = Date(timeIntervalSince1970: 100)
        let json = "{\"claudeAiOauth\":{\"accessToken\":\"test-access\",\"refreshToken\":\"test-refresh\",\"expiresAt\":1000000}}"
        let credential = try XCTUnwrap(OAuthCredential(json))
        XCTAssertTrue(credential.needsRenewal(asOf: now))
        XCTAssertFalse(credential.needsRenewal(asOf: now.addingTimeInterval(-1)))
        let renewedAccess = try XCTUnwrap(OAuthCredential(json.replacingOccurrences(of: "test-access", with: "other-access")))
        let newLogin = try XCTUnwrap(OAuthCredential(json.replacingOccurrences(of: "test-refresh", with: "new-grant")))
        XCTAssertEqual(credential.grantID, renewedAccess.grantID)
        XCTAssertNotEqual(credential.grantID, newLogin.grantID)
        XCTAssertFalse(credential.grantID.contains("test-refresh"))
    }
}

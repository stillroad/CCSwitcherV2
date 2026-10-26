import XCTest
@testable import CCSwitcherPolicy

final class AccountTests: XCTestCase {
    func testLegacySavedAccountsRemainInRotationWithTheirMetadataIntact() throws {
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001",
          "email":"saved@example.test","displayName":"Saved account",
          "provider":"Claude Code","isActive":true,"orgName":"Test org",
          "subscriptionType":"max","lastUsed":42,"customLabel":"Work"},
         {"id":"00000000-0000-0000-0000-000000000002",
          "email":"other@example.test","displayName":"Other",
          "provider":"Claude Code","isActive":false}]
        """
        let accounts = try JSONDecoder().decode([Account].self, from: Data(json.utf8))
        XCTAssertEqual(accounts.count, 2)
        XCTAssertTrue(accounts.allSatisfy { !$0.isRotationPaused })
        XCTAssertTrue(accounts[0].isActive)
        XCTAssertEqual(accounts[0].orgName, "Test org")
        XCTAssertEqual(accounts[0].subscriptionType, "max")
        XCTAssertEqual(accounts[0].lastUsed, Date(timeIntervalSinceReferenceDate: 42))
        XCTAssertEqual(accounts[0].customLabel, "Work")
        XCTAssertNil(accounts[1].lastUsed)
    }

    func testPauseStateRoundTripsAlongsideExistingAccountFields() throws {
        let accounts = [
            Account(email: "paused@example.test", displayName: "Paused", orgName: "Test",
                    subscriptionType: "max", isActive: true, lastUsed: Date(timeIntervalSinceReferenceDate: 42),
                    customLabel: "Reserved", isRotationPaused: true),
            Account(email: "ready@example.test", displayName: "Ready")
        ]
        let restored = try JSONDecoder().decode([Account].self, from: JSONEncoder().encode(accounts))
        XCTAssertEqual(restored, accounts)
        XCTAssertTrue(restored[0].isRotationPaused)
        XCTAssertFalse(restored[1].isRotationPaused)
    }
}

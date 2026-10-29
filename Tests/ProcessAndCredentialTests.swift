import XCTest
@testable import CCSwitcherPolicy

final class ProcessAndCredentialTests: XCTestCase {
    func testLargeStdoutAndStderrAreDrainedSeparately() async throws {
        let result = try await BoundedProcess.run(executable: "/bin/sh", arguments: ["-c",
            "i=0; while [ $i -lt 12000 ]; do printf 'output-data\\n'; printf 'warning-data\\n' >&2; i=$((i + 1)); done"], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.utf8.count, 12_000 * 12)
        XCTAssertEqual(result.stderr.utf8.count, 12_000 * 13)
    }

    func testHungCommandTimesOut() async throws {
        let start = Date()
        do {
            _ = try await BoundedProcess.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch BoundedProcess.Failure.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }

    func testExcessiveOutputIsBounded() async throws {
        do {
            _ = try await BoundedProcess.run(executable: "/usr/bin/yes", arguments: [], timeout: 3, outputLimit: 1024)
            XCTFail("Expected output limit")
        } catch BoundedProcess.Failure.outputTooLarge {}
    }

    func testNonzeroExitStillReturnsSeparateOutput() async throws {
        let result = try await BoundedProcess.run(executable: "/bin/sh", arguments: ["-c", "printf ok; printf bad >&2; exit 7"])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.stdout, "ok")
        XCTAssertEqual(result.stderr, "bad")
    }

    @MainActor
    func testCredentialFailureRestoresBothStores() async throws {
        let old = AccountBackup(token: "old-token", oauthAccount: ["emailAddress": AnyCodable("old@example.test")])
        let new = AccountBackup(token: "new-token", oauthAccount: ["emailAddress": AnyCodable("new@example.test")])
        for failingStage in ["token", "identity", "verify"] {
            var token = old.token
            var identity = old.oauthAccount
            var verified = false
            do {
                try await CredentialSwitchTransaction.run(previous: old, target: new, readToken: { token }, writeToken: {
                    token = $0
                    return !(failingStage == "token" && $0 == new.token)
                }, writeIdentity: {
                    identity = $0
                    return !(failingStage == "identity" && $0 == new.oauthAccount)
                }, verify: {
                    verified = true
                    throw NSError(domain: "synthetic-verification", code: 1)
                })
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(token, old.token, failingStage)
                XCTAssertEqual(identity, old.oauthAccount, failingStage)
                XCTAssertEqual(verified, failingStage == "verify")
            }
        }
    }

    @MainActor
    func testSuccessfulCredentialSwapKeepsTargetAndReturnsVerification() async throws {
        let old = AccountBackup(token: "old", oauthAccount: [:])
        let new = AccountBackup(token: "new", oauthAccount: ["id": AnyCodable(2)])
        var writes: [String] = []
        var token = old.token
        let result = try await CredentialSwitchTransaction.run(previous: old, target: new, readToken: { token }, writeToken: {
            token = $0; writes.append($0); return true
        }, writeIdentity: { _ in true }, verify: { "verified" })
        XCTAssertEqual(result, "verified")
        XCTAssertEqual(writes, ["new"])
    }

    @MainActor
    func testFailedRollbackIsSurfacedAndBothRestorationsAttempted() async throws {
        let old = AccountBackup(token: "old", oauthAccount: ["id": AnyCodable(1)])
        let new = AccountBackup(token: "new", oauthAccount: ["id": AnyCodable(2)])
        var restoredIdentity = false
        do {
            try await CredentialSwitchTransaction.run(previous: old, target: new, readToken: { old.token }, writeToken: { _ in false },
                writeIdentity: { identity in restoredIdentity = identity == old.oauthAccount; return true }, verify: {})
            XCTFail("Expected rollback failure")
        } catch CredentialSwitchTransaction.Failure.rollbackFailed {
            XCTAssertTrue(restoredIdentity)
        }
    }

    @MainActor
    func testRollbackCannotEraseAnotherWindowsNewLogin() async throws {
        let old = AccountBackup(token: "cleared-old-login", oauthAccount: ["id": AnyCodable(1)])
        let target = AccountBackup(token: "target", oauthAccount: ["id": AnyCodable(2)])
        var token = old.token
        var identity = old.oauthAccount
        do {
            try await CredentialSwitchTransaction.run(previous: old, target: target,
                readToken: { token }, writeToken: { token = $0; return true },
                writeIdentity: { identity = $0; return true }, verify: {
                    token = "new-browser-login"
                    identity = ["id": AnyCodable(3)]
                    throw ClaudeServiceError.switchVerificationFailed
                })
            XCTFail("Expected concurrent change")
        } catch CredentialSwitchTransaction.Failure.credentialsChanged {
            XCTAssertEqual(token, "new-browser-login")
            XCTAssertEqual(identity, ["id": AnyCodable(3)])
        }
    }

    @MainActor
    func testChangedSourceStopsBeforeWritingEitherStore() async throws {
        let old = AccountBackup(token: "old", oauthAccount: [:])
        let target = AccountBackup(token: "target", oauthAccount: [:])
        do {
            try await CredentialSwitchTransaction.run(previous: old, target: target,
                readToken: { "newer-login" }, writeToken: { _ in XCTFail("Must not write"); return true },
                writeIdentity: { _ in XCTFail("Must not write"); return true }, verify: {})
            XCTFail("Expected concurrent change")
        } catch CredentialSwitchTransaction.Failure.credentialsChanged {}
    }
}

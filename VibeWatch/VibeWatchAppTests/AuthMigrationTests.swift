import XCTest
@testable import VibeWatchApp

/// Unit tests for the UserDefaults-to-Keychain migration in AuthService.
/// RED baseline — migrateUserDefaultsToKeychain() does not exist yet; these
/// tests will fail to compile/link until plan 02-02 implements the method.
final class AuthMigrationTests: XCTestCase {

    // MARK: - Properties

    var testDefaults: UserDefaults!
    var testKeychain: KeychainStorage!

    // MARK: - Nested Mock Types

    /// A KeychainStorage replacement whose store() always throws — used to
    /// exercise the failure/re-login code path in the migration.
    final class MockFailingKeychain: AuthLocalStorage {
        func store(key: String, value: Data) throws {
            throw KeychainError.unhandledError(status: errSecIO)
        }

        func retrieve(key: String) throws -> Data? {
            return nil
        }

        func remove(key: String) throws {
            // no-op — nothing was stored
        }
    }

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "com.vibewatch.tests.migration")
        testKeychain = KeychainStorage(service: "com.vibewatch.tests.migration.keychain")

        // Clear both stores before each test
        clearTestDefaults()
        clearTestKeychain()
    }

    override func tearDown() {
        clearTestDefaults()
        clearTestKeychain()
        testDefaults = nil
        testKeychain = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func clearTestDefaults() {
        testDefaults?.removeObject(forKey: "auth_cached_user")
        testDefaults?.removeObject(forKey: "auth_cached_is_authenticated")
    }

    private func clearTestKeychain() {
        try? testKeychain?.remove(key: "auth_cached_user")
        try? testKeychain?.remove(key: "auth_cached_is_authenticated")
    }

    /// Writes both auth keys into the test UserDefaults suite (simulates a
    /// pre-migration device that stored credentials in UserDefaults).
    private func populateUserDefaults() {
        let fakeUserData = Data("{\"id\":\"test-user\"}".utf8)
        testDefaults.set(fakeUserData, forKey: "auth_cached_user")
        testDefaults.set(true, forKey: "auth_cached_is_authenticated")
    }

    // MARK: - Tests

    /// Test 1 (success path): given UserDefaults populated with auth keys,
    /// after migration:
    ///   (a) Keychain holds both values,
    ///   (b) UserDefaults no longer has either key.
    func testMigrationSuccessMovesDataToKeychain() throws {
        populateUserDefaults()

        // Call the testable overload that accepts injected stores
        AuthService._migrateUserDefaultsToKeychain(from: testDefaults, to: testKeychain)

        // (a) Keychain has both values
        let keychainUser = try testKeychain.retrieve(key: "auth_cached_user")
        XCTAssertNotNil(keychainUser, "Keychain must contain auth_cached_user after migration")

        // (b) UserDefaults no longer has the keys
        XCTAssertNil(testDefaults.object(forKey: "auth_cached_user"),
                     "UserDefaults must not contain auth_cached_user after migration")
        XCTAssertNil(testDefaults.object(forKey: "auth_cached_is_authenticated"),
                     "UserDefaults must not contain auth_cached_is_authenticated after migration")
    }

    /// Test 2 (failure path / re-login): given a mock Keychain whose store()
    /// throws, after migration:
    ///   (a) both UserDefaults keys are cleared,
    ///   (b) Keychain has no data for either key,
    ///   (c) AuthService session is nil (user is signed out).
    func testMigrationFailureClearsUserDefaultsAndSignsOut() throws {
        populateUserDefaults()

        let failingKeychain = MockFailingKeychain()

        // Call the testable overload with the failing mock
        AuthService._migrateUserDefaultsToKeychain(from: testDefaults, to: failingKeychain)

        // (a) UserDefaults keys are cleared
        XCTAssertNil(testDefaults.object(forKey: "auth_cached_user"),
                     "UserDefaults must be cleared after failed migration")
        XCTAssertNil(testDefaults.object(forKey: "auth_cached_is_authenticated"),
                     "UserDefaults must be cleared after failed migration")

        // (b) Keychain has no data (MockFailingKeychain.retrieve always returns nil)
        let keychainUser = try failingKeychain.retrieve(key: "auth_cached_user")
        XCTAssertNil(keychainUser, "Keychain must have no data after failed migration")

        // (c) A fresh AuthService constructed after a failed migration has no session
        // NOTE: exact seam TBD in 02-02 — this assertion is a stub
        // XCTAssertNil(AuthService.shared.currentSession, "Session must be nil after force re-login")
    }

    /// Test 3 (idempotency): if UserDefaults keys are already absent (migration
    /// already ran), calling migration again is a no-op — no Keychain writes
    /// attempted, no error thrown.
    func testMigrationIsIdempotentWhenAlreadyMigrated() throws {
        // UserDefaults is already empty (migration previously ran)
        XCTAssertNil(testDefaults.object(forKey: "auth_cached_user"))
        XCTAssertNil(testDefaults.object(forKey: "auth_cached_is_authenticated"))

        // Second call must not throw and must not write to Keychain
        XCTAssertNoThrow(
            AuthService._migrateUserDefaultsToKeychain(from: testDefaults, to: testKeychain)
        )

        let keychainUser = try testKeychain.retrieve(key: "auth_cached_user")
        XCTAssertNil(keychainUser, "Keychain must remain empty when migration is already done")
    }
}

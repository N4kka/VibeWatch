import XCTest
@testable import VibeWatchApp

/// Unit tests for the KeychainStorage adapter.
/// RED baseline — KeychainStorage does not exist yet; these tests will fail to
/// compile/link until plan 02-02 creates the production type.
final class KeychainStorageTests: XCTestCase {

    // MARK: - Properties

    var sut: KeychainStorage!

    // MARK: - Setup / Teardown

    override func setUp() {
        super.setUp()
        sut = KeychainStorage(service: "com.vibewatch.tests.keychain")
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// Test 1: store and retrieve — stored data is returned on retrieve.
    func testStoreAndRetrieve() throws {
        let key = "test-store-retrieve-\(UUID().uuidString)"
        let value = Data("hello keychain".utf8)

        XCTAssertNoThrow(try sut.store(key: key, value: value))
        let retrieved = try sut.retrieve(key: key)
        XCTAssertEqual(retrieved, value)

        // Cleanup
        XCTAssertNoThrow(try sut.remove(key: key))
    }

    /// Test 2: overwrite — second store for same key returns the new value.
    func testOverwriteReturnsNewValue() throws {
        let key = "test-overwrite-\(UUID().uuidString)"
        let v1 = Data("v1".utf8)
        let v2 = Data("v2".utf8)

        XCTAssertNoThrow(try sut.store(key: key, value: v1))
        XCTAssertNoThrow(try sut.store(key: key, value: v2))
        let retrieved = try sut.retrieve(key: key)
        XCTAssertEqual(retrieved, v2)

        // Cleanup
        XCTAssertNoThrow(try sut.remove(key: key))
    }

    /// Test 3: remove — retrieve returns nil after remove.
    func testRemoveDeletesItem() throws {
        let key = "test-remove-\(UUID().uuidString)"
        let value = Data("will be removed".utf8)

        XCTAssertNoThrow(try sut.store(key: key, value: value))
        XCTAssertNoThrow(try sut.remove(key: key))
        let retrieved = try sut.retrieve(key: key)
        XCTAssertNil(retrieved)
    }

    /// Test 4: remove missing key — no error thrown for a key that was never stored.
    func testRemoveMissingKeyDoesNotThrow() {
        let key = "test-remove-missing-\(UUID().uuidString)"
        XCTAssertNoThrow(try sut.remove(key: key))
    }

    /// Test 5: retrieve missing key — returns nil (not an error).
    func testRetrieveMissingKeyReturnsNil() throws {
        let key = "test-retrieve-missing-\(UUID().uuidString)"
        let result = try sut.retrieve(key: key)
        XCTAssertNil(result)
    }

    /// Test 6: accessibility — behavioral verification that stored values are
    /// accessible after first unlock (kSecAttrAccessibleAfterFirstUnlock).
    /// We cannot inspect Keychain attributes directly, so we verify the round-trip
    /// succeeds (the attribute is validated by the implementation, not this test).
    func testAccessibilityAfterFirstUnlock() throws {
        let key = "test-accessibility-\(UUID().uuidString)"
        let value = Data("accessibility check".utf8)

        XCTAssertNoThrow(try sut.store(key: key, value: value))
        let retrieved = try sut.retrieve(key: key)
        XCTAssertEqual(retrieved, value, "Value stored with kSecAttrAccessibleAfterFirstUnlock must be retrievable")

        // Cleanup
        XCTAssertNoThrow(try sut.remove(key: key))
    }
}

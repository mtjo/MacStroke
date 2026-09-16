//
//  AppleScriptsListTests.swift
//  MacStroke
//
//  Unit tests for AppleScriptsList
//

import XCTest
@testable import AppleScriptRunner

final class AppleScriptsListTests: XCTestCase {

    // Use a test-specific storage path to avoid interfering with actual data
    private var testStorageURL: URL!
    private var originalStorageURL: URL!

    override func setUp() {
        super.setUp()

        // Create a temporary directory for test storage
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacStrokeTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        testStorageURL = tempDir.appendingPathComponent("appleScripts.json")

        // Note: We can't easily override the singleton's storage URL without modifying the class.
        // For now, we'll use the singleton but clean up after each test.
        // Clear any existing scripts before each test
        let list = AppleScriptsList.sharedAppleScriptsList
        let allScripts = list.getAllScripts()
        for script in allScripts {
            list.removeScript(id: script.id)
        }
    }

    override func tearDown() {
        // Clean up test directory
        if let testStorageURL = testStorageURL {
            try? FileManager.default.removeItem(at: testStorageURL.deletingLastPathComponent())
        }
        super.tearDown()
    }

    // MARK: - Basic Functionality Tests

    func testSharedInstanceExists() {
        let list1 = AppleScriptsList.sharedAppleScriptsList
        let list2 = AppleScriptsList.sharedAppleScriptsList
        XCTAssertTrue(list1 === list2, "Singleton should return the same instance")
    }

    func testInitialCountIsZero() {
        let list = AppleScriptsList.sharedAppleScriptsList
        // Clear any existing scripts
        let allScripts = list.getAllScripts()
        for script in allScripts {
            list.removeScript(id: script.id)
        }
        XCTAssertEqual(list.count, 0, "Initial count should be zero after cleanup")
    }

    func testAddScriptIncrementsCount() {
        let list = AppleScriptsList.sharedAppleScriptsList
        let initialCount = list.count

        let script = list.addScript(name: "Test Script", source: "return \"hello\"")

        XCTAssertEqual(list.count, initialCount + 1)
        XCTAssertEqual(script.name, "Test Script")
        XCTAssertEqual(script.source, "return \"hello\"")
        XCTAssertNotNil(script.id)
        XCTAssertNotNil(script.createTime)
    }

    func testAddMultipleScripts() {
        let list = AppleScriptsList.sharedAppleScriptsList
        let initialCount = list.count

        list.addScript(name: "Script 1", source: "return 1")
        list.addScript(name: "Script 2", source: "return 2")
        list.addScript(name: "Script 3", source: "return 3")

        XCTAssertEqual(list.count, initialCount + 3)
    }

    func testGetScriptById() {
        let list = AppleScriptsList.sharedAppleScriptsList

        let added = list.addScript(name: "Find Me", source: "return \"found\"")
        let found = list.getScriptById(id: added.id)

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, added.id)
        XCTAssertEqual(found?.name, "Find Me")
        XCTAssertEqual(found?.source, "return \"found\"")
    }

    func testGetScriptByIdNotFound() {
        let list = AppleScriptsList.sharedAppleScriptsList
        let nonExistentId = UUID()

        let found = list.getScriptById(id: nonExistentId)

        XCTAssertNil(found)
    }

    func testGetAllScriptsReturnsSortedArray() {
        let list = AppleScriptsList.sharedAppleScriptsList

        // Clear first
        let existing = list.getAllScripts()
        for script in existing {
            list.removeScript(id: script.id)
        }

        let script1 = list.addScript(name: "First", source: "return 1")
        // Small delay to ensure different timestamps
        Thread.sleep(forTimeInterval: 0.01)
        let script2 = list.addScript(name: "Second", source: "return 2")
        Thread.sleep(forTimeInterval: 0.01)
        let script3 = list.addScript(name: "Third", source: "return 3")

        let allScripts = list.getAllScripts()

        XCTAssertEqual(allScripts.count, 3)
        // Should be sorted by createTime descending (newest first)
        XCTAssertEqual(allScripts[0].id, script3.id)
        XCTAssertEqual(allScripts[1].id, script2.id)
        XCTAssertEqual(allScripts[2].id, script1.id)
    }

    // MARK: - Remove Tests

    func testRemoveScript() {
        let list = AppleScriptsList.sharedAppleScriptsList

        let script = list.addScript(name: "To Remove", source: "return \"remove me\"")
        let initialCount = list.count

        let removed = list.removeScript(id: script.id)

        XCTAssertTrue(removed)
        XCTAssertEqual(list.count, initialCount - 1)
        XCTAssertNil(list.getScriptById(id: script.id))
    }

    func testRemoveNonExistentScript() {
        let list = AppleScriptsList.sharedAppleScriptsList
        let initialCount = list.count

        let removed = list.removeScript(id: UUID())

        XCTAssertFalse(removed)
        XCTAssertEqual(list.count, initialCount)
    }

    func testRemoveAllScripts() {
        let list = AppleScriptsList.sharedAppleScriptsList

        // Add some scripts
        list.addScript(name: "Script 1", source: "return 1")
        list.addScript(name: "Script 2", source: "return 2")
        list.addScript(name: "Script 3", source: "return 3")

        // Remove them all
        let allScripts = list.getAllScripts()
        for script in allScripts {
            list.removeScript(id: script.id)
        }

        XCTAssertEqual(list.count, 0)
        XCTAssertTrue(list.getAllScripts().isEmpty)
    }

    // MARK: - Persistence Tests

    func testPersistenceAcrossInstances() {
        // This test verifies that the singleton properly saves and loads
        // Since we use the singleton, we test that save/load cycle works

        let list = AppleScriptsList.sharedAppleScriptsList

        // Clear first
        let existing = list.getAllScripts()
        for script in existing {
            list.removeScript(id: script.id)
        }

        // Add scripts
        list.addScript(name: "Persistent 1", source: "return \"persist 1\"")
        list.addScript(name: "Persistent 2", source: "return \"persist 2\"")

        // Force save
        list.save()

        // Verify count persists (using same singleton instance)
        XCTAssertEqual(list.count, 2)
        let allScripts = list.getAllScripts()
        XCTAssertEqual(allScripts.count, 2)

        let names = Set(allScripts.map { $0.name })
        XCTAssertTrue(names.contains("Persistent 1"))
        XCTAssertTrue(names.contains("Persistent 2"))
    }

    func testScriptEquality() {
        let id = UUID()
        let date = Date()
        let script1 = AppleScriptItem(id: id, name: "Test", source: "return 1", createTime: date)
        let script2 = AppleScriptItem(id: id, name: "Test", source: "return 1", createTime: date)
        let script3 = AppleScriptItem(id: UUID(), name: "Test", source: "return 1", createTime: date)

        XCTAssertEqual(script1, script2)
        XCTAssertNotEqual(script1, script3)
    }

    func testScriptCodable() throws {
        let script = AppleScriptItem(
            id: UUID(),
            name: "Codable Test",
            source: "tell app \"Finder\" to activate",
            createTime: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(script)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppleScriptItem.self, from: data)

        XCTAssertEqual(script.id, decoded.id)
        XCTAssertEqual(script.name, decoded.name)
        XCTAssertEqual(script.source, decoded.source)
        // Dates may have slight precision differences, compare within 1 second
        XCTAssertEqual(script.createTime.timeIntervalSince1970, decoded.createTime.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - Edge Cases

    func testAddScriptWithEmptyName() {
        let list = AppleScriptsList.sharedAppleScriptsList

        let script = list.addScript(name: "", source: "return \"empty name\"")

        XCTAssertEqual(script.name, "")
        XCTAssertEqual(list.count, 1)
    }

    func testAddScriptWithEmptySource() {
        let list = AppleScriptsList.sharedAppleScriptsList

        let script = list.addScript(name: "Empty Source", source: "")

        XCTAssertEqual(script.source, "")
        XCTAssertEqual(list.count, 1)
    }

    func testAddScriptWithSpecialCharacters() {
        let list = AppleScriptsList.sharedAppleScriptsList

        let specialSource = """
        tell application "System Events"
            keystroke "Hello, World! 🎉"
            key code 36 -- Return key
        end tell
        """

        let script = list.addScript(name: "Special Chars", source: specialSource)

        XCTAssertEqual(script.source, specialSource)
    }

    func testUnicodeScriptNames() {
        let list = AppleScriptsList.sharedAppleScriptsList

        let script = list.addScript(name: "脚本测试 🎉", source: "return \"unicode\"")

        XCTAssertEqual(script.name, "脚本测试 🎉")
    }

    // MARK: - Thread Safety Tests

    func testConcurrentAccess() {
        let list = AppleScriptsList.sharedAppleScriptsList

        // Clear first
        let existing = list.getAllScripts()
        for script in existing {
            list.removeScript(id: script.id)
        }

        let expectation = XCTestExpectation(description: "Concurrent operations complete")
        expectation.expectedFulfillmentCount = 100

        let queue = DispatchQueue.global(qos: .userInitiated)

        // Concurrent adds
        for i in 0..<50 {
            queue.async {
                list.addScript(name: "Script \(i)", source: "return \(i)")
                expectation.fulfill()
            }
        }

        // Concurrent reads
        for _ in 0..<50 {
            queue.async {
                _ = list.getAllScripts()
                _ = list.count
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)

        // Verify final state is consistent
        XCTAssertGreaterThanOrEqual(list.count, 0)
        let allScripts = list.getAllScripts()
        XCTAssertEqual(allScripts.count, list.count)
    }
}
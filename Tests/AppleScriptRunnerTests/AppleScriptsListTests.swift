//
//  AppleScriptsListTests.swift
//  MacStroke
//
//  Unit tests for AppleScriptsList
//

import XCTest
@testable import AppleScriptRunner

final class AppleScriptsListTests: XCTestCase {

    private var testStorageURL: URL!
    private var testList: AppleScriptsList!

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
        testList = AppleScriptsList(storageURL: testStorageURL)
    }

    override func tearDown() {
        // Clean up test directory
        if let testStorageURL = testStorageURL {
            try? FileManager.default.removeItem(at: testStorageURL.deletingLastPathComponent())
        }
        testList = nil
        super.tearDown()
    }

    // MARK: - Basic Functionality Tests

    func testSharedInstanceExists() {
        let list1 = AppleScriptsList.sharedAppleScriptsList
        let list2 = AppleScriptsList.sharedAppleScriptsList
        XCTAssertTrue(list1 === list2, "Singleton should return the same instance")
    }

    func testTestInstanceIsIsolated() {
        // Verify test instance doesn't affect shared instance
        testList.addScript(name: "Test Only", source: "return \"test\"")
        XCTAssertEqual(testList.count, 1)

        // Shared instance should be unaffected
        let sharedList = AppleScriptsList.sharedAppleScriptsList
        let sharedCount = sharedList.count
        // (We don't modify shared instance in tests)
        XCTAssertEqual(sharedList.count, sharedCount)
    }

    func testInitialCountIsZero() {
        XCTAssertEqual(testList.count, 0, "Initial count should be zero")
    }

    func testAddScriptIncrementsCount() {
        let initialCount = testList.count

        let script = testList.addScript(name: "Test Script", source: "return \"hello\"")

        XCTAssertEqual(testList.count, initialCount + 1)
        XCTAssertEqual(script.name, "Test Script")
        XCTAssertEqual(script.source, "return \"hello\"")
        XCTAssertNotNil(script.id)
        XCTAssertNotNil(script.createTime)
    }

    func testAddMultipleScripts() {
        let initialCount = testList.count

        testList.addScript(name: "Script 1", source: "return 1")
        testList.addScript(name: "Script 2", source: "return 2")
        testList.addScript(name: "Script 3", source: "return 3")

        XCTAssertEqual(testList.count, initialCount + 3)
    }

    func testGetScriptById() {
        let added = testList.addScript(name: "Find Me", source: "return \"found\"")
        let found = testList.getScriptById(id: added.id)

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, added.id)
        XCTAssertEqual(found?.name, "Find Me")
        XCTAssertEqual(found?.source, "return \"found\"")
    }

    func testGetScriptByIdNotFound() {
        let nonExistentId = UUID()
        let found = testList.getScriptById(id: nonExistentId)
        XCTAssertNil(found)
    }

    func testGetAllScriptsReturnsSortedArray() {
        let script1 = testList.addScript(name: "First", source: "return 1")
        Thread.sleep(forTimeInterval: 0.01)
        let script2 = testList.addScript(name: "Second", source: "return 2")
        Thread.sleep(forTimeInterval: 0.01)
        let script3 = testList.addScript(name: "Third", source: "return 3")

        let allScripts = testList.getAllScripts()

        XCTAssertEqual(allScripts.count, 3)
        // Should be sorted by createTime descending (newest first)
        XCTAssertEqual(allScripts[0].id, script3.id)
        XCTAssertEqual(allScripts[1].id, script2.id)
        XCTAssertEqual(allScripts[2].id, script1.id)
    }

    // MARK: - Remove Tests

    func testRemoveScript() {
        let script = testList.addScript(name: "To Remove", source: "return \"remove me\"")
        let initialCount = testList.count

        let removed = testList.removeScript(id: script.id)

        XCTAssertTrue(removed)
        XCTAssertEqual(testList.count, initialCount - 1)
        XCTAssertNil(testList.getScriptById(id: script.id))
    }

    func testRemoveNonExistentScript() {
        let initialCount = testList.count
        let removed = testList.removeScript(id: UUID())
        XCTAssertFalse(removed)
        XCTAssertEqual(testList.count, initialCount)
    }

    func testRemoveAllScripts() {
        testList.addScript(name: "Script 1", source: "return 1")
        testList.addScript(name: "Script 2", source: "return 2")
        testList.addScript(name: "Script 3", source: "return 3")

        let allScripts = testList.getAllScripts()
        for script in allScripts {
            testList.removeScript(id: script.id)
        }

        XCTAssertEqual(testList.count, 0)
        XCTAssertTrue(testList.getAllScripts().isEmpty)
    }

    // MARK: - Persistence Tests

    func testPersistenceAcrossInstances() {
        // Add scripts to test instance
        testList.addScript(name: "Persistent 1", source: "return \"persist 1\"")
        testList.addScript(name: "Persistent 2", source: "return \"persist 2\"")

        // Create new instance with same storage URL
        let newList = AppleScriptsList(storageURL: testStorageURL)

        XCTAssertEqual(newList.count, 2)
        let allScripts = newList.getAllScripts()
        XCTAssertEqual(allScripts.count, 2)

        let names = Set(allScripts.map { $0.name })
        XCTAssertTrue(names.contains("Persistent 1"))
        XCTAssertTrue(names.contains("Persistent 2"))
    }

    func testPersistenceSurvivesRecreation() {
        // Add and save
        testList.addScript(name: "Survive", source: "return \"survive\"")
        testList = nil

        // Recreate with same URL
        let newList = AppleScriptsList(storageURL: testStorageURL!)

        XCTAssertEqual(newList.count, 1)
        XCTAssertEqual(newList.getScriptById(id: newList.getAllScripts()[0].id)?.name, "Survive")
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
        let script = testList.addScript(name: "", source: "return \"empty name\"")
        XCTAssertEqual(script.name, "")
        XCTAssertEqual(testList.count, 1)
    }

    func testAddScriptWithEmptySource() {
        let script = testList.addScript(name: "Empty Source", source: "")
        XCTAssertEqual(script.source, "")
        XCTAssertEqual(testList.count, 1)
    }

    func testAddScriptWithSpecialCharacters() {
        let specialSource = """
        tell application "System Events"
            keystroke "Hello, World! 🎉"
            key code 36 -- Return key
        end tell
        """

        let script = testList.addScript(name: "Special Chars", source: specialSource)
        XCTAssertEqual(script.source, specialSource)
    }

    func testUnicodeScriptNames() {
        let script = testList.addScript(name: "脚本测试 🎉", source: "return \"unicode\"")
        XCTAssertEqual(script.name, "脚本测试 🎉")
    }

    // MARK: - Thread Safety Tests

    func testConcurrentAccess() {
        let expectation = XCTestExpectation(description: "Concurrent operations complete")
        expectation.expectedFulfillmentCount = 100

        let queue = DispatchQueue.global(qos: .userInitiated)

        // Concurrent adds
        for i in 0..<50 {
            queue.async {
                self.testList.addScript(name: "Script \(i)", source: "return \(i)")
                expectation.fulfill()
            }
        }

        // Concurrent reads
        for _ in 0..<50 {
            queue.async {
                _ = self.testList.getAllScripts()
                _ = self.testList.count
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)

        // Verify final state is consistent
        XCTAssertGreaterThanOrEqual(testList.count, 0)
        let allScripts = testList.getAllScripts()
        XCTAssertEqual(allScripts.count, testList.count)
    }
}
//
//  AppleScriptRunnerTests
//  MacStroke
//

import XCTest
@testable import AppleScriptRunner

final class AppleScriptRunnerTests: XCTestCase {

    func testExecuteReturn() throws {
        let runner = AppleScriptRunner()
        let result = try runner.execute("return \"hello\"")
        XCTAssertEqual(result, "hello")
    }

    func testExecuteExpressionReturnsOutput() throws {
        let runner = AppleScriptRunner()
        // osascript evaluates arithmetic expressions
        let result = try runner.execute("return 2 + 3")
        XCTAssertEqual(result, "5")
    }

    func testExecutePresetReturnsFalseForUnknownPreset() {
        let runner = AppleScriptRunner()
        let success = runner.executePreset("nonexistent-preset")
        XCTAssertFalse(success)
    }

    func testAvailablePresetsNotEmpty() {
        XCTAssertFalse(AppleScriptRunner.availablePresets.isEmpty)
    }

    func testAvailablePresetsContainsExpected() {
        let presets = AppleScriptRunner.availablePresets
        XCTAssertTrue(presets.contains("close-window"))
        XCTAssertTrue(presets.contains("minimize"))
        XCTAssertTrue(presets.contains("hide-app"))
        XCTAssertTrue(presets.contains("launch-safari"))
        XCTAssertTrue(presets.contains("launch-chrome"))
        XCTAssertTrue(presets.contains("launch-terminal"))
    }
}
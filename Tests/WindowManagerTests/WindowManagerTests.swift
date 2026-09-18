//
//  WindowManagerTests
//  MacStroke
//

import XCTest
@testable import WindowManager
@testable import Preferences

final class WindowManagerTests: XCTestCase {

    func testWindowManagerSingleton() {
        let wm1 = WindowManager.shared
        let wm2 = WindowManager.shared
        XCTAssertTrue(wm1 === wm2)
    }

    func testUserPreferencesDefaults() {
        let prefs = UserPreferences()
        XCTAssertNotNil(prefs)
        XCTAssertEqual(prefs.minimumPoints, 10)
        XCTAssertEqual(prefs.minSimilarityScore, 85.0)
    }

    func testUserPreferencesSaveAndLoad() {
        let prefs = UserPreferences()
        prefs.isEnabled = false
        prefs.minimumPoints = 15
        prefs.save()

        let loadedPrefs = UserPreferences()
        XCTAssertEqual(loadedPrefs.isEnabled, false)
        XCTAssertEqual(loadedPrefs.minimumPoints, 15)

        // Reset
        let resetPrefs = UserPreferences()
        resetPrefs.isEnabled = true
        resetPrefs.minimumPoints = 10
        resetPrefs.save()
    }
}
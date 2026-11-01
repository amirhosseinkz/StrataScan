import XCTest

final class StrataScanUITests: XCTestCase {
    @MainActor
    func testEmptyLibraryOpensAndClosesFullScreenScanner() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = [
            "-uiTestingLibraryState", "empty",
            "-uiTestingScannerState", "unavailable"
        ]
        app.launch()

        let openScanner = app.buttons["library.openScanner"]
        XCTAssertTrue(openScanner.waitForExistence(timeout: 2))
        openScanner.tap()

        XCTAssertTrue(app.staticTexts["Capture adapter unavailable"].waitForExistence(timeout: 2))
        app.buttons["scanner.close"].tap()
        XCTAssertTrue(openScanner.waitForExistence(timeout: 2))
    }

    @MainActor
    func testScannerOffersExplicitSemanticRoomMode() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = [
            "-uiTestingLibraryState", "empty",
            "-uiTestingScannerState", "ready"
        ]
        app.launch()

        let openScanner = app.buttons["library.openScanner"]
        XCTAssertTrue(openScanner.waitForExistence(timeout: 2))
        openScanner.tap()

        let captureMode = app.segmentedControls["scanner.captureMode"]
        XCTAssertTrue(captureMode.waitForExistence(timeout: 2))
        captureMode.buttons["Room plan"].tap()
        XCTAssertTrue(
            app.staticTexts[
                "Creates a separate semantic USDZ with RoomPlan without collecting raw mesh or frame assets."
            ].waitForExistence(timeout: 2)
        )
    }

    @MainActor
    func testActiveRawCaptureUsesCaptureDockWithoutUnsupportedLocationControls() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = [
            "-uiTestingLibraryState", "empty",
            "-uiTestingScannerState", "ready"
        ]
        app.launch()

        let openScanner = app.buttons["library.openScanner"]
        XCTAssertTrue(openScanner.waitForExistence(timeout: 2))
        openScanner.tap()

        let startCapture = app.buttons["Preview capture flow"]
        XCTAssertTrue(startCapture.waitForExistence(timeout: 2))
        startCapture.tap()

        XCTAssertTrue(app.buttons["Pause demo"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Finish capture"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        XCTAssertFalse(app.staticTexts["GPS"].exists)
        XCTAssertFalse(app.staticTexts["RTK"].exists)
    }

    @MainActor
    func testLibraryFailureProvidesRetry() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-uiTestingLibraryState", "failure"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Could not load scans"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["library.retry"].exists)
    }

    @MainActor
    func testLibraryOffersGenericScanComparisonForTwoScans() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-uiTestingLibraryState", "content"]
        app.launch()

        let compare = app.buttons["Compare scans"]
        XCTAssertTrue(compare.waitForExistence(timeout: 2))
        XCTAssertTrue(compare.isEnabled)
        compare.tap()

        XCTAssertTrue(app.navigationBars["Compare scans"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Choose two scans"].exists)
        XCTAssertFalse(app.buttons["Save draft"].isEnabled)
    }

    @MainActor
    func testSavedWorkspaceDefaultsToProcessedSurfaceAndCanSelectRawDiagnosticMesh() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-uiTestingLibraryState", "content"]
        app.launch()

        let firstScanID = "1F2AE661-2C41-4D11-A3E0-B5B5CD024271"
        let scan = app.buttons["library.scan.\(firstScanID)"]
        XCTAssertTrue(scan.waitForExistence(timeout: 2))
        scan.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["scanDetail.processedSurface"]
                .waitForExistence(timeout: 2)
        )
        let picker = app.segmentedControls["scanDetail.surfacePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 2))
        picker.buttons["Diagnostic raw mesh"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["scanDetail.mesh"]
                .waitForExistence(timeout: 2)
        )
        picker.buttons["Processed surface"].tap()
        XCTAssertTrue(app.buttons["scanDetail.resetView"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testSettingsTabShowsLocalOnlyDescription() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 2))
        settingsTab.tap()

        XCTAssertTrue(
            app.staticTexts["Local demo data stays in memory and is never sent over the network."].waitForExistence(timeout: 2)
        )
    }

    @MainActor
    func testEnglishRootPlacesTrailingToolbarOnRightScreenEdge() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        app.launchArguments = ["-uiTestingLibraryState", "empty"]
        app.launch()

        let newScan = app.buttons["library.newScan"]
        XCTAssertTrue(newScan.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(newScan.frame.midX, app.frame.midX)
    }
}

import XCTest

/// Reproducible screenshots of injected, synthetic UI states; no sensor evidence.
final class PortfolioSnapshotTests: XCTestCase {
    @MainActor
    func testEnglishPortfolioSnapshots() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestingLibraryState", "content",
            "-uiTestingScannerState", "ready",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        let scan = app.buttons["library.scan.1F2AE661-2C41-4D11-A3E0-B5B5CD024271"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        capture("01-library", app: app)

        scan.tap()
        XCTAssertTrue(app.descendants(matching: .any)["scanDetail.processedSurface"].waitForExistence(timeout: 5))
        app.buttons["scanDetail.resetView"].tap()
        // SceneKit draws asynchronously after the SwiftUI surface appears.
        try await Task.sleep(for: .seconds(2))
        capture("02-workspace", app: app)

        app.terminate()
        app.launch()
        let compare = app.buttons["Compare scans"]
        XCTAssertTrue(compare.waitForExistence(timeout: 5))
        compare.tap()
        XCTAssertTrue(app.staticTexts["Choose two scans"].waitForExistence(timeout: 5))
        capture("03-comparison", app: app)
        app.buttons["Close"].tap()

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Local demo data stays in memory and is never sent over the network."].waitForExistence(timeout: 5))
        capture("04-settings", app: app)

        app.terminate()
        app.launchArguments = [
            "-uiTestingLibraryState", "empty",
            "-uiTestingScannerState", "ready",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        let openScanner = app.buttons["library.openScanner"]
        XCTAssertTrue(openScanner.waitForExistence(timeout: 5))
        capture("05-empty-library", app: app)
        openScanner.tap()
        XCTAssertTrue(app.segmentedControls["scanner.captureMode"].waitForExistence(timeout: 5))
        capture("06-scanner", app: app)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

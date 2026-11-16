import XCTest

final class FileImportUITests: XCTestCase {
    @MainActor
    func testLocalVideoPickerCanOpenAgainAfterCancellationAndOtherImports() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        func openAndCancel(_ identifier: String) {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
            button.tap()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 15), "File picker did not appear: \(app.debugDescription)")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = identifier + "-file-picker"
            attachment.lifetime = .keepAlways
            add(attachment)
            cancel.tap()
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertFalse(app.alerts.firstMatch.exists, "Cancelling must not display an error")
        }

        openAndCancel("openLocalVideo")
        openAndCancel("openLocalVideo")
        openAndCancel("importDanmaku")
        app.buttons["openNetworkVideo"].tap()
        XCTAssertTrue(app.buttons["closeNetworkVideo"].waitForExistence(timeout: 10))
        app.buttons["closeNetworkVideo"].tap()
        openAndCancel("openLocalVideo")
    }
}

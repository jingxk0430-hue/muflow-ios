import XCTest
import UIKit

final class FileImportUITests: XCTestCase {
    @MainActor
    func testDanmakuStylePreviewInBothOrientations() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["设置"].tap()
        let preview = app.descendants(matching: .any)["danmakuStylePreview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        defer { XCUIDevice.shared.orientation = .portrait }
        for (orientation, name) in [(UIDeviceOrientation.portrait, "danmaku-style-portrait"),
                                    (.landscapeLeft, "danmaku-style-landscape")] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(preview.isHittable)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func tapVisibleButton(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<4 {
            let passwordPrompt = app.sheets["Save Password?"].buttons["Not Now"]
            if passwordPrompt.exists && passwordPrompt.isHittable { passwordPrompt.tap() }
            if button.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(button.isHittable, app.debugDescription)
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: button)
        waitForExpectations(timeout: 10)
        button.tap()
    }

    @MainActor
    func testWebDAVLoginAndFolderNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["openWebDAV"].tap()
        let address = app.textFields["webdavAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap(); address.typeText("http://127.0.0.1:18765/dav/")
        let username = app.textFields["webdavUsername"]
        username.tap(); username.typeText("fixture-user")
        let password = app.secureTextFields["webdavPassword"]
        password.tap(); password.typeText("fixture-password")
        app.buttons["connectWebDAV"].tap()
        let folder = app.buttons["webdav-item-Series"]
        XCTAssertTrue(folder.waitForExistence(timeout: 20), app.debugDescription)
        folder.tap()
        XCTAssertTrue(app.buttons["webdav-item-Episode 01.mkv"].waitForExistence(timeout: 15), app.debugDescription)
        tapVisibleButton("webdavParent", in: app)
        XCTAssertTrue(app.buttons["webdav-item-Series"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["closeWebDAV"].tap()
        app.terminate()
        app.launch()
        app.buttons["openWebDAV"].tap()
        let restored = app.textFields["webdavAddress"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        XCTAssertEqual(restored.value as? String, "http://127.0.0.1:18765/dav/", "Login must survive an app restart in the Keychain")
        app.buttons["closeWebDAV"].tap()
        app.buttons["openLocalVideo"].tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Cancel"].firstMatch.tap()
    }

    @MainActor
    func testLocalVideoPickerCanOpenAgainAfterCancellationAndOtherImports() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        func openAndCancel(_ identifier: String) {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 15), app.debugDescription)
            tapVisibleButton(identifier, in: app)
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
        app.swipeDown()
        app.buttons["openNetworkVideo"].tap()
        XCTAssertTrue(app.buttons["closeNetworkVideo"].waitForExistence(timeout: 10))
        app.buttons["closeNetworkVideo"].tap()
        openAndCancel("openLocalVideo")
    }
}

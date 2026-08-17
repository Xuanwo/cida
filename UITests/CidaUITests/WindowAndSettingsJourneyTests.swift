import XCTest

@MainActor
final class WindowAndSettingsJourneyTests: CidaReleaseUITestCase {
  func testNativeWindowControlsResizeRestoreAndCloseSettings() {
    driver.launch()

    let initialFrame = driver.window.frame
    let zoomButton = driver.window.buttons[XCUIIdentifierZoomWindow]
    let minimizeButton = driver.window.buttons[XCUIIdentifierMinimizeWindow]
    let closeButton = driver.window.buttons[XCUIIdentifierCloseWindow]
    XCTAssertTrue(zoomButton.waitForExistence(timeout: 3))
    XCTAssertTrue(minimizeButton.exists)
    XCTAssertTrue(closeButton.exists)

    zoomButton.click()
    XCTAssertTrue(waitForWindowFrameChange(from: initialFrame, timeout: 5))
    zoomButton.click()
    XCTAssertTrue(waitForWindowFrame(near: initialFrame, timeout: 5))

    driver.app.buttons["model-settings-button"].click()
    let settingsWindow = driver.app.windows["设置"]
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
    XCTAssertTrue(settingsWindow.buttons[XCUIIdentifierZoomWindow].exists)
    XCTAssertTrue(settingsWindow.buttons[XCUIIdentifierMinimizeWindow].exists)
    let settingsClose = settingsWindow.buttons[XCUIIdentifierCloseWindow]
    XCTAssertTrue(settingsClose.exists)
    settingsClose.click()
    XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))

    closeButton.click()
    XCTAssertTrue(driver.window.waitForNonExistence(timeout: 3))
    driver.app.typeKey(.space, modifierFlags: .option)
    XCTAssertTrue(driver.window.waitForExistence(timeout: 5))
    XCTAssertTrue(driver.composer.waitForExistence(timeout: 3))
  }

  private func waitForWindowFrameChange(from frame: CGRect, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if abs(driver.window.frame.width - frame.width) > 20
        || abs(driver.window.frame.height - frame.height) > 20
      {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }

  private func waitForWindowFrame(near frame: CGRect, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let current = driver.window.frame
      if abs(current.width - frame.width) <= 3, abs(current.height - frame.height) <= 3 {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }
}

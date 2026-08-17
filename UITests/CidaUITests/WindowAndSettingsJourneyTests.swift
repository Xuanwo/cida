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

  func testProviderEndpointAndPromptEditingFollowTheSettingsStateMachine() {
    driver.launch(endpointOverride: false)
    driver.app.buttons["model-settings-button"].click()
    let settingsWindow = driver.app.windows["设置"]
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

    let providerMenu = driver.settingsProviderMenu(in: settingsWindow)
    XCTAssertEqual(providerMenu.label, "DeepSeek")
    XCTAssertFalse(driver.app.textFields["settings-openai-endpoint"].exists)
    XCTAssertTrue(driver.app.switches["settings-launch-at-login-toggle"].exists)

    let improveEditor = driver.app.textViews["settings-prompt-editor-improve"]
    XCTAssertTrue(improveEditor.waitForExistence(timeout: 3))
    let customPrompt = "Improve this text while preserving its source language."
    driver.replaceText(in: improveEditor, with: customPrompt)
    XCTAssertEqual(improveEditor.value as? String, customPrompt)

    settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))
    driver.app.buttons["model-settings-button"].click()
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
    XCTAssertEqual(
      driver.app.textViews["settings-prompt-editor-improve"].value as? String,
      customPrompt
    )

    let resetPrompt = driver.app.buttons["settings-prompt-reset-improve"]
    XCTAssertTrue(resetPrompt.waitForExistence(timeout: 3))
    resetPrompt.click()
    XCTAssertTrue(
      driver.waitForValue(
        "You are a writing assistant. Improve the user-provided text for clarity, grammar, "
          + "and natural tone. Keep the original language and meaning. Prefer precise technical "
          + "wording. Return only the improved text.",
        in: driver.app.textViews["settings-prompt-editor-improve"],
        timeout: 3
      )
    )

    providerMenu.click()
    let openAIItem = driver.app.menuItems["OpenAI"]
    XCTAssertTrue(openAIItem.waitForExistence(timeout: 3))
    openAIItem.click()
    XCTAssertEqual(driver.settingsProviderMenu(in: settingsWindow).label, "OpenAI")
    let endpoint = driver.app.textFields["settings-openai-endpoint"]
    XCTAssertTrue(endpoint.waitForExistence(timeout: 3))
    XCTAssertTrue(driver.app.textFields["settings-model"].exists)

    driver.replaceText(
      in: endpoint,
      with: "http://127.0.0.1:8080/v1/chat/completions"
    )
    XCTAssertTrue(settingsWindow.staticTexts["本地端点可留空"].waitForExistence(timeout: 3))
    let resetEndpoint = driver.app.buttons["settings-openai-endpoint-reset"]
    XCTAssertTrue(resetEndpoint.waitForExistence(timeout: 3))
    resetEndpoint.click()
    XCTAssertTrue(
      driver.waitForValue(
        "https://api.openai.com/v1/chat/completions",
        in: endpoint,
        timeout: 3
      )
    )
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

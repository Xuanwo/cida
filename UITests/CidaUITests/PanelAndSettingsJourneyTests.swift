import XCTest

@MainActor
final class PanelAndSettingsJourneyTests: CidaReleaseUITestCase {
  func testPanelHidesOnEscapeReturnsOnOptionSpaceAndKeepsItsState() {
    driver.launch()
    let frame = driver.panel.frame
    XCTAssertEqual(frame.width, 800, accuracy: 1)
    XCTAssertFalse(driver.panel.buttons[XCUIIdentifierCloseWindow].exists, "No title bar controls")
    XCTAssertFalse(driver.panel.buttons[XCUIIdentifierZoomWindow].exists)

    driver.submit("CIDA_E2E_POOL_PANEL")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_POOL_PANEL_COMPLETE").waitForExistence(timeout: 8))
    driver.waitForCompletion()
    driver.composer.click()
    driver.composer.typeKey(.tab, modifierFlags: [])
    XCTAssertTrue(driver.improveAction.isSelected)

    driver.hidePanel()
    driver.showPanel()
    XCTAssertEqual(driver.panel.frame.minY, frame.minY, accuracy: 1, "The top edge is fixed")
    XCTAssertEqual(driver.textValue(in: driver.composer), "CIDA_E2E_POOL_PANEL")
    XCTAssertTrue(driver.result(containing: "CIDA_E2E_POOL_PANEL_COMPLETE").exists)
    XCTAssertTrue(driver.translateAction.isSelected, "Every appearance starts from 翻译")

    driver.composer.typeText("X")
    XCTAssertEqual(
      driver.textValue(in: driver.composer), "X",
      "The source is fully selected on show, so typing replaces it")

    driver.openSettings()
    XCTAssertTrue(driver.panel.waitForNonExistence(timeout: 3), "Settings takes the panel away")
    XCTAssertTrue(driver.settingsWindow.buttons[XCUIIdentifierZoomWindow].exists)
    XCTAssertTrue(driver.settingsWindow.buttons[XCUIIdentifierMinimizeWindow].exists)
    let settingsClose = driver.settingsWindow.buttons[XCUIIdentifierCloseWindow]
    XCTAssertTrue(settingsClose.exists)
    settingsClose.click()
    XCTAssertTrue(driver.settingsWindow.waitForNonExistence(timeout: 3))
    driver.showPanel()
  }

  func testProviderEndpointAndPromptEditingFollowTheSettingsStateMachine() {
    driver.launch(endpointOverride: false)
    driver.openSettings()
    let settingsWindow = driver.settingsWindow

    let providerMenu = driver.settingsProviderMenu(in: settingsWindow)
    XCTAssertEqual(providerMenu.label, "DeepSeek")
    XCTAssertFalse(driver.app.textFields["settings-endpoint"].exists, "Presets hide the endpoint")
    XCTAssertTrue(
      driver.element(identifier: "settings-provider-endpoint-caption").exists,
      "Presets name the host requests go to")
    XCTAssertTrue(driver.readinessRow.waitForExistence(timeout: 3))
    XCTAssertTrue(
      driver.waitForValue("还差 API Key", in: driver.readinessRow, timeout: 3),
      "Readiness is derived from the empty key")
    let launchAtLogin = driver.element(identifier: "settings-launch-at-login-toggle")
    XCTAssertTrue(launchAtLogin.exists)
    XCTAssertEqual(launchAtLogin.elementType, .checkBox)

    XCTAssertFalse(driver.app.textViews["settings-prompt-editor-improve"].exists, "Prompts start collapsed")
    driver.app.buttons["settings-prompt-edit-improve"].click()
    let improveEditor = driver.app.textViews["settings-prompt-editor-improve"]
    XCTAssertTrue(improveEditor.waitForExistence(timeout: 3))
    let customPrompt = "Improve this text while preserving its source language."
    driver.replaceText(in: improveEditor, with: customPrompt)
    XCTAssertEqual(improveEditor.value as? String, customPrompt)

    settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))
    driver.showPanel()
    driver.openSettings()
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
    let customItem = driver.app.menuItems[CidaAppDriver.customProviderLabel]
    XCTAssertTrue(customItem.waitForExistence(timeout: 3))
    customItem.click()
    XCTAssertEqual(
      driver.settingsProviderMenu(in: settingsWindow).label, CidaAppDriver.customProviderLabel)
    let endpoint = driver.app.textFields["settings-endpoint"]
    XCTAssertTrue(endpoint.waitForExistence(timeout: 3), "Custom shows the endpoint field")
    XCTAssertTrue(driver.app.textFields["settings-model"].exists, "Custom takes a typed model")
    XCTAssertTrue(driver.waitForValue("端点无效", in: driver.readinessRow, timeout: 3))

    driver.replaceText(in: driver.app.textFields["settings-model"], with: "local-model")
    driver.replaceText(in: endpoint, with: "http://127.0.0.1:8080/v1/chat/completions")
    XCTAssertTrue(
      driver.waitForValue("本地端点 · 无需 API Key", in: driver.readinessRow, timeout: 3))
    XCTAssertEqual(
      driver.app.secureTextFields["settings-api-key-editor"].placeholderValue,
      "本地端点可留空"
    )
  }

  func testFreshAppInstancesDoNotShareSettingsOrCredentials() {
    driver.launch(endpointOverride: false)
    driver.configureCustomEndpoint(
      endpoint: e2eEnvironment.endpoint,
      model: "first-instance-model",
      apiKey: "sk-first-instance"
    )
    driver.terminate()

    let secondNamespace = e2eEnvironment.uniqueSettingsNamespace(for: name + "-second")
    let secondDriver = CidaAppDriver(
      environment: e2eEnvironment,
      settingsNamespace: secondNamespace
    )
    defer {
      secondDriver.terminate()
      e2eEnvironment.resetSettings(namespace: secondNamespace)
    }

    secondDriver.launch(endpointOverride: false)
    secondDriver.openSettings()
    let settingsWindow = secondDriver.settingsWindow
    XCTAssertEqual(secondDriver.settingsProviderMenu(in: settingsWindow).label, "DeepSeek")
    XCTAssertEqual(
      secondDriver.app.secureTextFields["settings-api-key-editor"].value as? String,
      ""
    )
  }
}

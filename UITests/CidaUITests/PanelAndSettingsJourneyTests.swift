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

  /// `Design/spec/panel.md` §一 带入选区, through the real Accessibility
  /// path: the guest grants Cida the permission, and the selection lives in
  /// the source application's editor.
  func testShortcutBringsInANewSelectionAndLeavesTheSameOneAlone() throws {
    driver.launch()
    driver.hidePanel()
    let source = SourceApplication()
    source.launch()
    addTeardownBlock { [source] in source.app.terminate() }

    source.select("  CIDA_E2E_SELECTION_A ")
    source.press(.space, modifierFlags: .option)
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5))
    XCTAssertTrue(
      driver.waitForTextValue("CIDA_E2E_SELECTION_A", in: driver.composer, timeout: 3),
      "A new selection replaces the source, trimmed")
    XCTAssertTrue(driver.translateAction.isSelected)
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_SELECTION_A_COMPLETE").waitForExistence(timeout: 8),
      "and is translated without ⏎")
    driver.waitForCompletion()

    driver.composer.typeText("CIDA_E2E_EDITED")
    driver.hidePanel()
    source.press(.space, modifierFlags: .option)
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5))
    XCTAssertEqual(
      driver.textValue(in: driver.composer), "CIDA_E2E_EDITED",
      "The selection brought in last time keeps the edited source")
    XCTAssertTrue(driver.result(containing: "CIDA_E2E_SELECTION_A_COMPLETE").exists)
    XCTAssertEqual(
      try scenarioServer.state().filter { $0.scenario == "CIDA_E2E_SELECTION_A" }.count, 1,
      "The same selection is not requested again")

    driver.hidePanel()
    source.clearSelection()
    source.press(.space, modifierFlags: .option)
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5))
    XCTAssertEqual(driver.textValue(in: driver.composer), "CIDA_E2E_EDITED", "No selection")

    driver.hidePanel()
    source.select("CIDA_E2E_SELECTION_GATED")
    source.press(.space, modifierFlags: .option)
    XCTAssertTrue(
      driver.waitForTextValue("CIDA_E2E_SELECTION_GATED", in: driver.composer, timeout: 5))
    XCTAssertNotNil(
      try scenarioServer.wait(for: "CIDA_E2E_SELECTION_GATED", status: "headers-sent", timeout: 5))
    XCTAssertTrue(driver.stopButton.waitForExistence(timeout: 3))

    driver.hidePanel()
    source.select("CIDA_E2E_SELECTION_B")
    source.press(.space, modifierFlags: .option)
    XCTAssertTrue(
      driver.waitForTextValue("CIDA_E2E_SELECTION_B", in: driver.composer, timeout: 5),
      "A new selection replaces a running request")
    let completed = driver.result(containing: "CIDA_E2E_SELECTION_B_COMPLETE")
    XCTAssertTrue(completed.waitForExistence(timeout: 8))
    driver.waitForCompletion()
    try scenarioServer.releaseFirstByte(for: "CIDA_E2E_SELECTION_GATED")
    XCTAssertNotNil(
      try scenarioServer.wait(
        for: "CIDA_E2E_SELECTION_GATED", status: "client-disconnected", timeout: 5),
      "The superseded request was cancelled")
    XCTAssertFalse((completed.value as? String)?.contains("SELECTION_GATED") ?? true)
  }

  /// `Design/spec/panel.md` §一 截图翻译, through the real ScreenCaptureKit
  /// path: the guest grants Cida Screen Recording, the capture shortcut
  /// freezes the guest's display, and Vision reads the source application's
  /// line of text. Vision's first recognition loads its models, which is why
  /// the first frame is given time.
  func testCaptureShortcutFramesTextOnTheFrozenScreenAndTranslatesIt() {
    driver.launch()
    driver.hidePanel()
    let source = SourceApplication()
    source.launch()
    addTeardownBlock { [source] in source.app.terminate() }
    let textFrame = source.captureText.frame.insetBy(dx: -16, dy: -12)
    let blankFrame = source.blankArea.frame.insetBy(dx: 24, dy: 24)

    source.press("s", modifierFlags: .option)
    XCTAssertTrue(driver.captureOverlay.waitForExistence(timeout: 5), "⌥S freezes the screen")
    driver.app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(driver.captureOverlay.waitForNonExistence(timeout: 3), "Escape cancels")
    XCTAssertFalse(driver.panel.exists, "A cancelled capture shows nothing")

    source.press("s", modifierFlags: .option)
    XCTAssertTrue(driver.captureOverlay.waitForExistence(timeout: 5))
    XCTAssertTrue(driver.element(identifier: "capture-overlay-hint").exists, "The hint pill names the task")
    let veiled = XCTAttachment(screenshot: driver.captureOverlay.screenshot())
    veiled.name = "capture-overlay-veiled"
    veiled.lifetime = .keepAlways
    add(veiled)
    driver.frameCapture(around: textFrame)
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 30), "The panel follows recognition")
    XCTAssertFalse(driver.captureOverlay.exists)
    XCTAssertTrue(
      driver.waitForTextValue("CIDA CAPTURE SCENARIO", in: driver.composer, timeout: 5),
      "The recognized text is the source")
    XCTAssertTrue(driver.translateAction.isSelected)
    XCTAssertTrue(
      driver.result(containing: "CIDA_CAPTURE_SCENARIO_COMPLETE").waitForExistence(timeout: 8),
      "and is translated without ⏎")
    driver.waitForCompletion()

    driver.hidePanel()
    source.press("s", modifierFlags: .option)
    XCTAssertTrue(driver.captureOverlay.waitForExistence(timeout: 5))
    driver.frameCapture(around: blankFrame)
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 10))
    XCTAssertTrue(
      driver.resultNote("unrecognized").waitForExistence(timeout: 3),
      "A frame without text says so")
    XCTAssertEqual(driver.textValue(in: driver.composer), "", "and clears the source")
    XCTAssertFalse(driver.stopButton.exists, "Nothing was requested")
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

  func testGlobalShortcutIsRecordedInSettingsAndSummonsThePanel() {
    driver.launch()
    driver.openSettings()
    let chip = driver.app.buttons["settings-shortcut"]
    XCTAssertTrue(chip.waitForExistence(timeout: 3))
    XCTAssertEqual(chip.label, "全局快捷键 ⌥ Space")
    XCTAssertFalse(
      driver.app.buttons["settings-shortcut-reset"].exists, "The default has nothing to restore")
    XCTAssertTrue(
      driver.element(identifier: "settings-selection-access-granted").exists,
      "The guest granted Accessibility, and the selection row reads it")
    let captureChip = driver.app.buttons["settings-capture-shortcut"]
    XCTAssertEqual(captureChip.label, "截图翻译快捷键 ⌥ S")
    XCTAssertFalse(
      driver.app.buttons["settings-capture-access-request"].exists,
      "The guest granted Screen Recording, so the capture row asks for nothing")

    chip.click()
    XCTAssertTrue(driver.waitForLabel("按下新的全局快捷键", in: chip, timeout: 3), "A click starts recording")
    driver.app.typeKey("t", modifierFlags: [.control, .option])
    XCTAssertTrue(driver.waitForLabel("全局快捷键 ⌃ ⌥ T", in: chip, timeout: 3), "The next combination is kept")
    let reset = driver.app.buttons["settings-shortcut-reset"]
    XCTAssertTrue(reset.waitForExistence(timeout: 3))

    driver.settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(driver.settingsWindow.waitForNonExistence(timeout: 3))
    driver.app.typeKey(.space, modifierFlags: .option)
    XCTAssertFalse(
      driver.waitForExistence(of: driver.panel, timeout: 1),
      "The previous combination no longer shows the panel")
    driver.app.typeKey("t", modifierFlags: [.control, .option])
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5), "The recorded combination shows the panel")
    XCTAssertTrue(driver.composer.waitForExistence(timeout: 3))

    driver.openSettings()
    XCTAssertTrue(reset.waitForExistence(timeout: 3))
    reset.click()
    XCTAssertTrue(driver.waitForLabel("全局快捷键 ⌥ Space", in: chip, timeout: 3))
    XCTAssertTrue(reset.waitForNonExistence(timeout: 3), "The default has nothing to restore")
    driver.settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(driver.settingsWindow.waitForNonExistence(timeout: 3))
    driver.showPanel()
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

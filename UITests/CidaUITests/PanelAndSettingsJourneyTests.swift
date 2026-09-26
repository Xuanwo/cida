import AppKit
import XCTest

@MainActor
final class PanelAndSettingsJourneyTests: CidaReleaseUITestCase {
  func testPanelHidesOnEscapeReturnsOnOptionSpaceAndKeepsItsState() throws {
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

    // A request keeps running behind the hidden panel, and the menu bar caret
    // breathes until it is done (Design/spec/brand.md §三).
    driver.submit("CIDA_E2E_BACKGROUND_GATED", expectsStreamingState: true)
    XCTAssertNotNil(
      try scenarioServer.wait(
        for: "CIDA_E2E_BACKGROUND_GATED", status: "headers-sent", timeout: 5))
    XCTAssertTrue(
      driver.waitForStatusItem(breathing: false), "The panel shows the request itself")
    driver.hidePanel()
    XCTAssertTrue(driver.waitForStatusItem(breathing: true), "The hidden request breathes")
    try scenarioServer.releaseFirstByte(for: "CIDA_E2E_BACKGROUND_GATED")
    XCTAssertTrue(
      driver.waitForStatusItem(breathing: false, timeout: 8), "A finished request rests")
    driver.showPanel()
    XCTAssertTrue(driver.result(containing: "CIDA_E2E_BACKGROUND_GATED_COMPLETE").exists)

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

  /// `Design/spec/translation-layer.md`: ⌥D shows the configuration over the screen; a click
  /// translates the paragraph under the pointer once, ⇧-click keeps translating the pane, which
  /// follows scrolling and is found again after Cida relaunches.
  func testTranslationLayerTranslatesAParagraphOnceAndKeepsAChosenPane() throws {
    driver.launch()
    driver.hidePanel()
    let source = SourceApplication()
    source.launch()
    addTeardownBlock { [source] in source.app.terminate() }
    let configuration = driver.app.dialogs["translation-layer-configuration"]
    let content = driver.element(identifier: "translation-layer-content")
    func paragraph(_ number: Int) -> XCUIElement {
      source.app.staticTexts.matching(
        NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@",
          "CIDA LAYER PARAGRAPH \(number).", "CIDA LAYER PARAGRAPH \(number).")
      ).firstMatch
    }
    func translations(timeout: TimeInterval, containing marker: String) -> String? {
      let deadline = Date().addingTimeInterval(timeout)
      repeat {
        if content.exists, let value = content.value as? String, value.contains(marker) { return value }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
      } while Date() < deadline
      return nil
    }
    func attach(_ name: String, movingPointerAway: Bool = true) {
      // A pointer resting on a translation shows the original (§四); the fade takes 150 ms.
      if movingPointerAway {
        source.captureText.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.6))
      let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      shot.name = name
      shot.lifetime = .keepAlways
      add(shot)
    }
    XCTAssertTrue(paragraph(2).waitForExistence(timeout: 5), "The source shows its article")

    // One paragraph, once.
    source.press("d", modifierFlags: .option)
    XCTAssertTrue(configuration.waitForExistence(timeout: 5), "⌥D shows the configuration")
    let second = paragraph(2).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
    second.hover()
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    attach("layer-configuration", movingPointerAway: false)
    second.click()
    XCTAssertTrue(configuration.waitForNonExistence(timeout: 5), "A click closes the configuration")
    let once = try XCTUnwrap(
      translations(timeout: 20, containing: "CIDA_LAYER_TRANSLATED_2"), "The paragraph is translated in place")
    XCTAssertFalse(once.contains("CIDA_LAYER_TRANSLATED_3"), "Only that paragraph")
    attach("layer-one-paragraph")
    source.app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(content.waitForNonExistence(timeout: 5), "Escape ends it")

    // A pane, kept.
    source.press("d", modifierFlags: .option)
    XCTAssertTrue(configuration.waitForExistence(timeout: 5))
    second.hover()
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    XCUIElement.perform(withKeyModifiers: .shift) { second.click() }
    let hint = driver.element(identifier: "translation-layer-hint")
    let chosen = NSPredicate(format: "label CONTAINS %@", "不再翻译这个区域")
    XCTAssertEqual(
      XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: chosen, object: hint)], timeout: 5),
      .completed, "⇧-click keeps the pane and offers to stop")
    attach("layer-configuration-lifted", movingPointerAway: false)
    driver.app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(configuration.waitForNonExistence(timeout: 5), "⏎ finishes")
    let kept = try XCTUnwrap(translations(timeout: 20, containing: "CIDA_LAYER_TRANSLATED_3"))
    XCTAssertTrue(kept.contains("CIDA_LAYER_TRANSLATED_1"), "Every visible paragraph of the pane")
    attach("layer-pane")

    // New paragraphs scrolled into view are translated too.
    let article = source.app.descendants(matching: .any).matching(identifier: "source-article").firstMatch
    let firstTop = paragraph(1).frame.minY
    article.scroll(byDeltaX: 0, deltaY: -600)
    if abs(paragraph(1).frame.minY - firstTop) < 1 { article.scroll(byDeltaX: 0, deltaY: 600) }
    XCTAssertNotNil(translations(timeout: 20, containing: "CIDA_LAYER_TRANSLATED_12"), "Scrolled-in paragraphs follow")
    attach("layer-after-scroll")

    // The pane is remembered.
    driver.terminate()
    driver.launch()
    driver.hidePanel()
    source.app.activate()
    XCTAssertNotNil(
      translations(timeout: 25, containing: "CIDA_LAYER_TRANSLATED_"), "The chosen pane comes back after a relaunch")
  }

  /// `Design/spec/configuration.md` §四: Settings starts with the onboarding card, copies the
  /// prompt, and follows what the artifact's own command line writes and checks while the
  /// window stays open. Prompts are still edited in Settings.
  func testModelServiceFollowsTheCommandLineAndPromptsEditInSettings() throws {
    driver.launch(endpointOverride: false)
    driver.openSettings()
    let settingsWindow = driver.settingsWindow

    XCTAssertTrue(driver.modelOnboarding.waitForExistence(timeout: 3), "No service yet")
    XCTAssertFalse(driver.modelStatus.exists)
    let copy = driver.copyConfigurationPromptButton
    XCTAssertEqual(copy.label, "复制配置提示词")
    copy.click()
    XCTAssertTrue(driver.waitForLabel("已复制", in: copy, timeout: 0.6), "✓ 已复制 right away")
    let prompt = NSPasteboard.general.string(forType: .string) ?? ""
    XCTAssertTrue(prompt.hasPrefix("帮我配置辞达（macOS 上的翻译与改写应用）使用的模型服务。"))
    XCTAssertTrue(prompt.contains("辞达的命令行：\(driver.executablePath)"), prompt)
    XCTAssertTrue(prompt.contains("当前配置：还没配置"))
    XCTAssertTrue(driver.waitForLabel("复制配置提示词", in: copy, timeout: 2), "…for 800 ms")
    XCTAssertTrue(
      driver.waitForText(
        containing: "已复制。粘贴给你的 AI 助手，配好后这里会自动更新。",
        in: driver.modelOnboardingCaption, timeout: 1),
      "The card says what comes next until a service arrives")

    // The assistant configures the service while Settings stays open.
    let set = try driver.runCommandLine([
      "config", "set", "endpoint=\(e2eEnvironment.endpoint)", "format=chat-completions",
      "model=cida-ui-mock-model",
    ])
    XCTAssertEqual(set.status, 0, set.errorOutput)
    XCTAssertEqual(set.output, "已更新 3 项：endpoint、format、model\n")
    let stored = try driver.runCommandLine(["config", "show", "--json"])
    XCTAssertTrue(stored.output.contains(#""complete": true"#), stored.output)
    XCTAssertTrue(
      driver.waitForExistence(of: driver.modelStatus, timeout: 3),
      "The open window refreshes at once")
    XCTAssertTrue(
      driver.waitForValue("已就绪 · 刚刚更新", in: driver.modelStatus, timeout: 3),
      "The open window refreshes at once")
    XCTAssertFalse(driver.modelOnboarding.exists)
    XCTAssertTrue(
      driver.waitForText(containing: "cida-ui-mock-model", in: driver.modelSummary, timeout: 1))
    XCTAssertTrue(
      driver.waitForText(containing: "127.0.0.1 · Chat Completions", in: driver.modelSummary, timeout: 1))
    XCTAssertTrue(
      driver.waitForValue("已就绪", in: driver.modelStatus, timeout: 5), "刚刚更新 lasts 3 s")

    // 检查 sends the same request as `Cida check`.
    driver.modelCheckButton.click()
    XCTAssertNotNil(try scenarioServer.wait(for: "hello", status: "completed", timeout: 10))
    XCTAssertTrue(driver.waitForValue("已就绪", in: driver.modelStatus, timeout: 5))
    XCTAssertFalse(driver.modelFailure.exists)

    // A failing command-line check shows up with its reason and the remedy.
    let unreachable = try driver.runCommandLine([
      "config", "set", "endpoint=http://127.0.0.1:9/v1/chat/completions",
    ])
    XCTAssertEqual(unreachable.status, 0)
    let check = try driver.runCommandLine(["check"])
    XCTAssertEqual(check.status, 69, check.output)
    XCTAssertTrue(check.output.hasPrefix("✗ 检查失败 · 连不上服务"), check.output)
    XCTAssertTrue(
      driver.waitForValue("检查失败 · 刚刚更新", in: driver.modelStatus, timeout: 3))
    XCTAssertTrue(
      driver.waitForText(
        containing: "连不上服务。复制配置提示词，让 AI 助手修好。", in: driver.modelFailure, timeout: 2))
    try driver.configureModelService()
    XCTAssertTrue(
      driver.waitForValue("已就绪 · 刚刚更新", in: driver.modelStatus, timeout: 3),
      "A changed configuration is 已就绪 until it is checked")
    XCTAssertFalse(driver.modelFailure.exists)

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
    let show = try driver.runCommandLine(["config", "show", "--json"])
    XCTAssertTrue(show.output.contains(customPrompt), "Settings and the command line share one store")
    XCTAssertTrue(show.output.contains(#""model": "cida-ui-mock-model""#), "and Settings kept it")

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
    let launchAtLogin = driver.element(identifier: "settings-launch-at-login-toggle")
    XCTAssertTrue(launchAtLogin.exists)
    XCTAssertEqual(launchAtLogin.elementType, .checkBox)
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

  func testFreshAppInstancesDoNotShareSettingsOrCredentials() throws {
    try driver.configureModelService(model: "first-instance-model")
    let key = try driver.runCommandLine(
      ["config", "set", "api-key", "--stdin"], standardInput: "sk-first-instance")
    XCTAssertEqual(key.status, 0, key.errorOutput)
    XCTAssertEqual(key.output, "已把 API Key 存进钥匙串\n")
    let refused = try driver.runCommandLine(["config", "set", "api-key=sk-first-instance"])
    XCTAssertEqual(refused.status, 64, "A key written in the command is refused")
    XCTAssertFalse(refused.errorOutput.contains("sk-first-instance"))
    driver.launch(endpointOverride: false)
    driver.openSettings()
    XCTAssertTrue(driver.waitForExistence(of: driver.modelStatus, timeout: 3))
    XCTAssertTrue(driver.waitForValue("已就绪", in: driver.modelStatus, timeout: 3))
    XCTAssertTrue(
      driver.waitForText(containing: "first-instance-model", in: driver.modelSummary, timeout: 1))
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
    XCTAssertTrue(secondDriver.modelOnboarding.waitForExistence(timeout: 3))
    let show = try secondDriver.runCommandLine(["config", "show", "--json"])
    XCTAssertTrue(show.output.contains(#""api-key": "unset""#), show.output)
    XCTAssertFalse(show.output.contains("first-instance-model"))
  }
}

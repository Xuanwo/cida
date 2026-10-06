import AppKit
import XCTest

@MainActor
final class PanelAndSettingsJourneyTests: CidaReleaseUITestCase {
  func testSettingsKeyboardFocusAndSelectionRemainIndependent() throws {
    driver.launch(additionalArguments: ["-AppleKeyboardUIMode", "3"])
    driver.openSettings()
    driver.showSettingsTab("general", title: "通用")

    func capture(_ name: String) {
      let attachment = XCTAttachment(screenshot: driver.settingsWindow.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    capture("settings-general-keyboard-focus")
    driver.settingsWindow.typeKey(.tab, modifierFlags: [])
    XCTAssertTrue(driver.settingsWindow.buttons["settings-tab-general"].isSelected)
    capture("settings-keyboard-focus-actions")
    driver.settingsWindow.typeKey(" ", modifierFlags: [])
    XCTAssertTrue(driver.waitForTitle("动作", of: driver.settingsWindow, timeout: 3))
    XCTAssertTrue(driver.settingsWindow.buttons["settings-tab-translation"].isSelected)
    capture("settings-keyboard-activated-actions")

    driver.settingsWindow.typeKey(.tab, modifierFlags: .shift)
    XCTAssertTrue(driver.settingsWindow.buttons["settings-tab-translation"].isSelected)
    driver.settingsWindow.typeKey(" ", modifierFlags: [])
    XCTAssertTrue(driver.waitForTitle("模型", of: driver.settingsWindow, timeout: 3))
    XCTAssertTrue(driver.settingsWindow.buttons["settings-tab-model"].isSelected)

    driver.settingsWindow.typeKey(.tab, modifierFlags: [])
    driver.settingsWindow.typeKey(.tab, modifierFlags: [])
    driver.settingsWindow.typeKey(.tab, modifierFlags: [])
    driver.settingsWindow.typeKey(" ", modifierFlags: [])
    XCTAssertTrue(driver.waitForTitle("通用", of: driver.settingsWindow, timeout: 3))
    capture("settings-general-selected-focus")
    driver.settingsWindow.typeKey(.tab, modifierFlags: [])
    capture("settings-keyboard-focus-leaves-tabs")
  }

  func testSettingsControlsShowKeyboardFocusAcrossPages() throws {
    try inspectSettingsControlFocus(dark: false)
  }

  func testSettingsControlsShowKeyboardFocusInDarkAppearance() throws {
    try inspectSettingsControlFocus(dark: true)
  }

  private func inspectSettingsControlFocus(dark: Bool) throws {
    var arguments = ["-AppleKeyboardUIMode", "3", "--automation-permissions", "denied"]
    if dark { arguments += ["--design-state", "dark-empty"] }
    driver.launch(additionalArguments: arguments)
    try driver.configureModelService()
    driver.openSettings()
    let prefix = dark ? "dark-" : ""

    func capture(_ name: String) {
      let attachment = XCTAttachment(screenshot: driver.settingsWindow.screenshot())
      attachment.name = prefix + name
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    func focus(_ element: XCUIElement, _ name: String) {
      XCTAssertTrue(element.exists, name)
      for _ in 0..<24 {
        if element.debugDescription.components(separatedBy: "\n").first?
          .contains("Keyboard Focused") == true {
          capture(name)
          return
        }
        driver.settingsWindow.typeKey(.tab, modifierFlags: [])
      }
      XCTFail("Keyboard navigation did not reach \(name)")
    }

    focus(driver.modelCheckButton, "focus-model-check")
    focus(driver.app.buttons["settings-copy-configuration-prompt"], "focus-model-copy")
    driver.settingsWindow.typeKey(" ", modifierFlags: [])
    XCTAssertTrue(driver.app.buttons["settings-copy-configuration-prompt"].exists)

    driver.showSettingsTab("general", title: "通用")
    let toggle = driver.element(identifier: "settings-launch-at-login-toggle")
    focus(toggle, "focus-general-toggle-off")
    let value = String(describing: toggle.value ?? "")
    driver.settingsWindow.typeKey(" ", modifierFlags: [])
    XCTAssertNotEqual(String(describing: toggle.value ?? ""), value)
    capture("focus-general-toggle-on")
    driver.settingsWindow.typeKey(" ", modifierFlags: [])
    XCTAssertEqual(String(describing: toggle.value ?? ""), value)
    focus(driver.app.buttons["settings-check-for-updates"], "focus-general-update")
    focus(driver.app.buttons["settings-feedback"], "focus-general-feedback")

    driver.showSettingsTab("shortcuts", title: "快捷键")
    for identifier in ["settings-shortcut", "settings-capture-shortcut",
                       "settings-layer-shortcut", "settings-improvement-shortcut"] {
      focus(driver.app.buttons[identifier], "focus-" + identifier)
    }
    focus(driver.app.buttons["settings-selection-access-request"], "focus-accessibility-permission")
    focus(driver.app.buttons["settings-capture-access-request"], "focus-screen-permission")
    driver.app.buttons["settings-shortcut"].click()
    capture("focus-shortcut-recording")
    driver.settingsWindow.typeKey(.delete, modifierFlags: [])
    focus(driver.app.buttons["settings-shortcut-reset"], "focus-shortcut-reset")
    driver.settingsWindow.typeKey(" ", modifierFlags: [])
    XCTAssertFalse(driver.app.buttons["settings-shortcut-reset"].exists)

    driver.showSettingsTab("translation", title: "动作")
    focus(driver.app.textFields["settings-my-language-editor"], "focus-my-language")
    for identifier in ["settings-action-translate", "settings-action-improve",
                       "settings-action-add", "settings-action-edit"] {
      let button = driver.app.buttons[identifier]
      focus(button, "focus-" + identifier)
      if identifier == "settings-action-translate" || identifier == "settings-action-improve" {
        driver.settingsWindow.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(button.isSelected)
      }
    }
    driver.app.buttons["settings-action-improve"].click()
    driver.app.buttons["settings-action-edit"].click()
    driver.app.textFields["settings-action-name"].click()
    capture("focus-action-name")
    let prompt = driver.app.textViews["settings-action-prompt"]
    prompt.click()
    prompt.typeText(" Additional instruction.")
    capture("focus-action-prompt")
    driver.showSettingsTab("general", title: "通用")
    driver.showSettingsTab("translation", title: "动作")
    focus(driver.app.buttons["settings-action-done"], "focus-action-done")
    focus(driver.app.buttons["settings-action-reset"], "focus-action-reset")
    focus(driver.app.buttons["settings-action-delete"], "focus-action-delete")
    prompt.click()
    driver.settingsWindow.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(driver.app.buttons["settings-action-edit"].waitForExistence(timeout: 3))
  }

  func testImprovementShortcutReplacesSelectionPreservesClipboardAndUndoes() throws {
    driver.launch()
    driver.hidePanel()
    let source = SourceApplication()
    source.launch()
    addTeardownBlock { [source] in source.app.terminate() }
    let original = "  CIDA_E2E_IMPROVEMENT_OK\n"
    source.select(original)
    XCTAssertEqual(source.editor.value as? String, original, "The native editor accepted the fixture verbatim")
    let before = XCTAttachment(screenshot: source.app.screenshot())
    before.name = "improvement-before"
    before.lifetime = .keepAlways
    add(before)
    let board = NSPasteboard.general
    let custom = NSPasteboard.PasteboardType("cida.improvement.test")
    board.clearContents()
    board.setString("User clipboard", forType: .string)
    board.setData(Data([4, 5]), forType: custom)
    source.press("f", modifierFlags: .option)
    XCTAssertTrue(driver.waitForTextValue("  Improved writing.\n", in: source.editor, timeout: 10))
    XCTAssertFalse(driver.panel.exists, "Normal improvement never opens the main panel")
    XCTAssertEqual(board.string(forType: .string), "User clipboard")
    XCTAssertEqual(board.data(forType: custom), Data([4, 5]))
    let after = XCTAttachment(screenshot: source.app.screenshot())
    after.name = "improvement-after"
    after.lifetime = .keepAlways
    add(after)
    source.press("z", modifierFlags: .command)
    XCTAssertTrue(driver.waitForTextValue(original, in: source.editor, timeout: 3))
  }

  func testImprovementShortcutCancelsAndKeepsChangedTargetForManualCopy() throws {
    driver.launch()
    driver.hidePanel()
    let source = SourceApplication()
    source.launch()
    addTeardownBlock { [source] in source.app.terminate() }
    let cancelled = "CIDA_E2E_IMPROVEMENT_CANCEL_GATED"
    source.select(cancelled)
    source.press("f", modifierFlags: .option)
    XCTAssertNotNil(try scenarioServer.wait(for: cancelled, status: "headers-sent", timeout: 5))
    source.press("f", modifierFlags: .option)
    try scenarioServer.releaseFirstByte(for: cancelled)
    XCTAssertNotNil(try scenarioServer.wait(for: cancelled, status: "client-disconnected", timeout: 5))
    XCTAssertEqual(source.editor.value as? String, cancelled)

    let changed = "CIDA_E2E_IMPROVEMENT_EDIT_GATED"
    source.select(changed)
    source.press("f", modifierFlags: .option)
    XCTAssertNotNil(try scenarioServer.wait(for: changed, status: "headers-sent", timeout: 5))
    source.editor.typeText("User edit")
    try scenarioServer.releaseFirstByte(for: changed)
    let view = driver.app.buttons["hint-action"]
    XCTAssertTrue(view.waitForExistence(timeout: 8))
    // The generation's cancel button becomes the result's view button.
    XCTAssertTrue(NSPredicate(format: "label == %@", "查看结果").evaluate(with: view)
      || XCTWaiter.wait(for: [XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label == %@", "查看结果"), object: view)], timeout: 8) == .completed)
    XCTAssertEqual(source.editor.value as? String, "User edit")
    let fallback = XCTAttachment(screenshot: driver.app.screenshot())
    fallback.name = "improvement-not-replaced"
    fallback.lifetime = .keepAlways
    add(fallback)
    view.click()
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5))
    XCTAssertTrue(driver.improveAction.isSelected)
    XCTAssertEqual(driver.textValue(in: driver.composer), changed)
    XCTAssertTrue(driver.result(containing: "Improved writing.").waitForExistence(timeout: 5))
    XCTAssertTrue(driver.resultNote("replacement").exists)
    driver.copyButton.click()
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Improved writing.")
  }

  func testImprovementShortcutDoesNotFollowAChangedSelectionOrApplication() throws {
    driver.launch()
    driver.hidePanel()
    let source = SourceApplication()
    source.launch()
    addTeardownBlock { [source] in source.app.terminate() }
    for change in ["MOVE", "SWITCH"] {
      let original = "CIDA_E2E_IMPROVEMENT_\(change)_GATED"
      source.select(original)
      source.press("f", modifierFlags: .option)
      XCTAssertNotNil(try scenarioServer.wait(for: original, status: "headers-sent", timeout: 5))
      if change == "MOVE" {
        source.press(.rightArrow, modifierFlags: [])
        // Restoring the same range must not reauthorize an invalidated operation.
        source.press("a", modifierFlags: .command)
      } else {
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        source.app.activate()
      }
      try scenarioServer.releaseFirstByte(for: original)
      let view = driver.app.buttons["hint-action"]
      let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == true AND label == %@", "查看结果"), object: view)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
      XCTAssertEqual(source.editor.value as? String, original)
    }
    source.clearSelection()
    let requests = try scenarioServer.state().count
    source.press("f", modifierFlags: .option)
    XCTAssertEqual(try scenarioServer.state().count, requests, "An empty selection starts no request")
  }

  func testPanelHidesOnEscapeReturnsOnOptionAAndKeepsItsState() throws {
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
    driver.composer.typeKey(.rightArrow, modifierFlags: .command)
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
      driver.textValue(in: driver.composer), "CIDA_E2E_POOL_PANELX",
      "Reopening keeps the caret, so typing continues instead of replacing the source")

    driver.composer.typeKey("a", modifierFlags: .command)
    driver.hidePanel()
    driver.showPanel()
    driver.composer.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(
      driver.waitForPasteboard("CIDA_E2E_POOL_PANELX", timeout: 2),
      "Reopening also preserves an explicit source selection")

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
    source.press("a", modifierFlags: .option)
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5))
    XCTAssertTrue(
      driver.waitForTextValue("CIDA_E2E_SELECTION_A", in: driver.composer, timeout: 3),
      "A new selection replaces the source, trimmed")
    XCTAssertTrue(driver.translateAction.isSelected)
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_SELECTION_A_COMPLETE").waitForExistence(timeout: 8),
      "and is translated without ⏎")
    driver.waitForCompletion()

    let resultValue = driver.result(containing: "CIDA_E2E_SELECTION_A_COMPLETE").value as? String ?? ""
    driver.composer.typeKey("c", modifierFlags: .command)
    let copied = driver.waitForPasteboard(resultValue, timeout: 2)
    let copyShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    copyShot.name = "Command-C after Option-A translation"
    copyShot.lifetime = .keepAlways
    add(copyShot)
    XCTAssertTrue(copied, "Command-C after importing a selection copies the result")

    driver.composer.typeKey("a", modifierFlags: .command)
    driver.composer.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(
      driver.waitForPasteboard("CIDA_E2E_SELECTION_A", timeout: 2),
      "Explicit Select All copies the source")

    driver.composer.typeText("CIDA_E2E_EDITED")
    driver.hidePanel()
    source.press("a", modifierFlags: .option)
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5))
    XCTAssertEqual(
      driver.textValue(in: driver.composer), "CIDA_E2E_EDITED",
      "The selection brought in last time keeps the edited source")
    XCTAssertTrue(driver.result(containing: "CIDA_E2E_SELECTION_A_COMPLETE").exists)
    driver.composer.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(
      driver.waitForPasteboard(resultValue, timeout: 2),
      "Reopening the panel also leaves Command-C available for the retained result")
    XCTAssertEqual(
      try scenarioServer.state().filter { $0.scenario == "CIDA_E2E_SELECTION_A" }.count, 1,
      "The same selection is not requested again")

    driver.hidePanel()
    source.clearSelection()
    source.press("a", modifierFlags: .option)
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5))
    XCTAssertEqual(driver.textValue(in: driver.composer), "CIDA_E2E_EDITED", "No selection")

    driver.hidePanel()
    source.select("CIDA_E2E_SELECTION_GATED")
    source.press("a", modifierFlags: .option)
    XCTAssertTrue(
      driver.waitForTextValue("CIDA_E2E_SELECTION_GATED", in: driver.composer, timeout: 5))
    XCTAssertNotNil(
      try scenarioServer.wait(for: "CIDA_E2E_SELECTION_GATED", status: "headers-sent", timeout: 5))
    XCTAssertTrue(driver.stopButton.waitForExistence(timeout: 3))

    driver.hidePanel()
    source.select("CIDA_E2E_SELECTION_B")
    source.press("a", modifierFlags: .option)
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

  /// `Design/spec/panel.md` §一 复制兜底: a selection the focused element
  /// cannot give is copied with ⌘C, and the clipboard the user had is put
  /// back. A copy of the focused element's own line is no selection.
  func testShortcutCopiesASelectionAccessibilityCannotGiveAndPutsTheClipboardBack() throws {
    driver.launch()
    driver.hidePanel()
    let source = SourceApplication()
    source.launch()
    addTeardownBlock { [source] in source.app.terminate() }
    let pasteboard = NSPasteboard.general
    let custom = NSPasteboard.PasteboardType("io.xuanwo.cida.e2e.clipboard")
    let clipboard = NSPasteboardItem()
    clipboard.setString("CIDA_E2E_CLIPBOARD", forType: .string)
    clipboard.setData(Data([7, 7, 7]), forType: custom)
    pasteboard.clearContents()
    pasteboard.writeObjects([clipboard])

    source.drawnText.click()
    source.press("a", modifierFlags: .option)
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5))
    let broughtIn = driver.waitForTextValue(
      "CIDA_E2E_SELECTION_DRAWN", in: driver.composer, timeout: 3)
    let translated = driver.result(containing: "CIDA_E2E_SELECTION_DRAWN_COMPLETE")
      .waitForExistence(timeout: 8)
    // Taken before the assertions, so a run without the fallback shows its empty panel too.
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "Copied selection of a custom-drawn view"
    shot.lifetime = .keepAlways
    add(shot)
    XCTAssertTrue(broughtIn, "The copied selection replaces the source")
    XCTAssertTrue(translated, "and is translated without ⏎")
    XCTAssertEqual(pasteboard.string(forType: .string), "CIDA_E2E_CLIPBOARD")
    XCTAssertEqual(pasteboard.data(forType: custom), Data([7, 7, 7]), "Every type is put back")
    driver.waitForCompletion()

    // Telegram Desktop: the focused field answers "nothing selected" while
    // the selection is elsewhere.
    driver.hidePanel()
    source.besideText.click()
    source.press("a", modifierFlags: .option)
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5))
    let besideBroughtIn = driver.waitForTextValue(
      "CIDA_E2E_SELECTION_BESIDE", in: driver.composer, timeout: 3)
    let besideTranslated = driver.result(containing: "CIDA_E2E_SELECTION_BESIDE_COMPLETE")
      .waitForExistence(timeout: 8)
    let besideShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    besideShot.name = "Copied selection beside a focused empty field"
    besideShot.lifetime = .keepAlways
    add(besideShot)
    XCTAssertTrue(besideBroughtIn, "A selection outside the focused field is copied")
    XCTAssertTrue(besideTranslated)
    XCTAssertEqual(pasteboard.string(forType: .string), "CIDA_E2E_CLIPBOARD")
    driver.waitForCompletion()

    driver.hidePanel()
    source.lineCopyField.click()
    source.press("a", modifierFlags: .option)
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5))
    XCTAssertFalse(
      driver.textValue(in: driver.composer).contains("CIDA_E2E_LINE"),
      "The whole line an editor copies with nothing selected is not brought in")
    XCTAssertEqual(pasteboard.string(forType: .string), "CIDA_E2E_CLIPBOARD")
    XCTAssertEqual(pasteboard.data(forType: custom), Data([7, 7, 7]), "Every type is put back")
  }

  /// `Design/spec/panel.md` §一 截图翻译, through the real ScreenCaptureKit
  /// path: the guest grants Cida Screen Recording, the capture shortcut
  /// freezes the guest's display, and Vision reads the source application's
  /// line of text. Vision's first recognition loads its models, which is why
  /// the first frame is given time.
  func testCaptureShortcutFramesTextOnTheFrozenScreenAndTranslatesIt() {
    driver.launch()
    driver.openSettings()
    driver.showSettingsTab("translation", title: "动作")
    driver.app.buttons["settings-action-improve"].click()
    driver.settingsWindow.typeKey(.leftArrow, modifierFlags: .option)
    driver.settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    driver.showPanel()
    XCTAssertTrue(driver.improveAction.isSelected, "The generic entry uses the reordered first action")
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

    let captureResult = driver.result(containing: "CIDA_CAPTURE_SCENARIO_COMPLETE").value as? String ?? ""
    driver.composer.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(
      driver.waitForPasteboard(captureResult, timeout: 2),
      "Capture translation leaves Command-C available for the result")

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

  /// `Design/spec/translation-layer.md`: ⌥D turns the paragraph under the pointer into its
  /// translation and back, a paragraph at a time; ⌥⇧D translates the whole window, follows
  /// scrolling, is kept across a relaunch, and stops on a second press.
  func testTranslationLayerTogglesParagraphsAndTheWholeWindow() throws {
    driver.launch()
    driver.hidePanel()
    let source = SourceApplication()
    source.launch()
    addTeardownBlock { [source] in source.app.terminate() }
    let layer = TranslationLayerProbe(cida: driver.app, source: source)
    func attach(_ name: String) {
      // Out of the way of the paragraphs, so the shot shows them whole.
      source.captureText.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
      RunLoop.current.run(until: Date().addingTimeInterval(0.6))
      let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      shot.name = name
      shot.lifetime = .keepAlways
      add(shot)
    }
    XCTAssertTrue(layer.paragraph(2).waitForExistence(timeout: 5), "The source shows its article")

    // ⌥D: this paragraph, then another; the rest stay original. The model takes ten seconds
    // over paragraph 2, and the paragraph shows it is waiting meanwhile (§二 等待). A screenshot
    // of the guest's screen can take seconds, so this checks that it waits visibly; the lifecycle
    // log's `layer-drawn` right after `layer-paragraph-shortcut` shows how soon.
    XCTAssertNil(layer.screenshotShowingWaiting(on: 2, within: 0), "The page is plain before ⌥D")
    layer.press(on: 2)
    let waiting = XCTAttachment(
      screenshot: try XCTUnwrap(layer.screenshotShowingWaiting(on: 2, within: 4), "⌥D shows the paragraph waiting"))
    waiting.name = "layer-waiting"
    waiting.lifetime = .keepAlways
    add(waiting)
    let one = try XCTUnwrap(layer.wait(timeout: 20) { $0.contains("CIDA_LAYER_TRANSLATED_2") }, "⌥D translates it in place")
    XCTAssertFalse(one.contains("CIDA_LAYER_TRANSLATED_3"), "Only that paragraph")
    attach("layer-one-paragraph")
    layer.press(on: 3)
    XCTAssertNotNil(
      layer.wait(timeout: 20) { $0.contains("CIDA_LAYER_TRANSLATED_2") && $0.contains("CIDA_LAYER_TRANSLATED_3") },
      "A second paragraph joins the first")
    attach("layer-two-paragraphs")

    // ⌥D on a translation turns it back.
    layer.press(on: 2)
    XCTAssertNotNil(
      layer.wait(timeout: 10) { !$0.contains("CIDA_LAYER_TRANSLATED_2") && $0.contains("CIDA_LAYER_TRANSLATED_3") },
      "Only the paragraph pressed on turns back")

    // ⌥D on a paragraph in my language translates it into the foreign one, as ⌥A would.
    layer.press(on: 17)
    let foreign = try XCTUnwrap(
      layer.wait(timeout: 20) { $0.contains("CIDA_LAYER_TRANSLATED_17") }, "⌥D translates my language too")
    XCTAssertTrue(foreign.contains("Paragraph 17 in English"), foreign)
    attach("layer-into-foreign-language")
    layer.press(on: 17)
    XCTAssertNotNil(
      layer.wait(timeout: 10) { !$0.contains("CIDA_LAYER_TRANSLATED_17") }, "and turns it back")

    // ⌥⇧D: the whole window. (Its hint lasts 2 s, shorter than a synthesized key press takes
    // to return here while the host's caret blinks; TranslationLayerTests places the pill.)
    layer.press(on: 2, wholeWindow: true)
    let whole = try XCTUnwrap(
      layer.wait(timeout: 25) { $0.contains("CIDA_LAYER_TRANSLATED_1") && $0.contains("CIDA_LAYER_TRANSLATED_2") },
      "Every paragraph of the window")
    XCTAssertFalse(whole.contains("CIDA_LAYER_TRANSLATED_17"), "but the one already in my language")
    attach("layer-whole-window")

    let article = source.app.descendants(matching: .any).matching(identifier: "source-article").firstMatch
    // A wheel scrolls what is under the pointer.
    article.hover()
    let motionLog = driver.environment.lifecycleLogDirectory + "/" + driver.settingsNamespace + ".log"
    XCTAssertNotNil(layer.wait(timeout: 10) { _ in
      (try? String(contentsOfFile: motionLog, encoding: .utf8).contains("layer-motion-ready")) == true
    }, "The source-window stream starts before testing scrolling")
    article.scroll(byDeltaX: 0, deltaY: -40)
    XCTAssertNotNil(layer.wait(timeout: 10) { _ in
      (try? String(contentsOfFile: motionLog, encoding: .utf8).contains("layer-motion-tracked")) == true
    }, "Captured source pixels move visible translations, rather than only using the settled fallback")
    attach("layer-tracked-scroll")
    // New paragraphs scrolled into view are translated too.
    let firstTop = layer.paragraph(1).frame.minY
    article.scroll(byDeltaX: 0, deltaY: -600)
    if abs(layer.paragraph(1).frame.minY - firstTop) < 1 { article.scroll(byDeltaX: 0, deltaY: 600) }
    XCTAssertNotNil(layer.wait(timeout: 20) { $0.contains("CIDA_LAYER_TRANSLATED_12") }, "Scrolled-in paragraphs follow")
    attach("layer-after-scroll")

    // The window is remembered, and a second ⌥⇧D stops it.
    driver.terminate()
    driver.launch()
    driver.hidePanel()
    source.app.activate()
    XCTAssertNotNil(
      layer.wait(timeout: 25) { $0.contains("CIDA_LAYER_TRANSLATED_") }, "The whole window comes back after a relaunch")
    source.captureText.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    source.press("d", modifierFlags: [.option, .shift])
    XCTAssertNotNil(layer.wait(timeout: 10) { !$0.contains("CIDA_LAYER_TRANSLATED_") }, "⌥⇧D again stops it")
  }

  /// `Design/spec/translation-layer.md` §二: clearing 原处翻译's shortcut turns the layer off,
  /// since nothing else could stop a window translated whole; the remembered window comes back
  /// once a shortcut is set again.
  func testClearingTheLayerShortcutStopsTheLayerUntilItIsSetAgain() throws {
    driver.launch()
    driver.hidePanel()
    let source = SourceApplication()
    source.launch()
    addTeardownBlock { [source] in source.app.terminate() }
    let layer = TranslationLayerProbe(cida: driver.app, source: source)
    XCTAssertTrue(layer.paragraph(2).waitForExistence(timeout: 5), "The source shows its article")
    layer.press(on: 2, wholeWindow: true)
    XCTAssertNotNil(
      layer.wait(timeout: 25) { $0.contains("CIDA_LAYER_TRANSLATED_2") }, "⌥⇧D translates the window")

    driver.showPanel()
    driver.openSettings()
    driver.showSettingsTab("shortcuts", title: "快捷键")
    let chip = driver.app.buttons["settings-layer-shortcut"]
    XCTAssertTrue(chip.waitForExistence(timeout: 3))
    chip.click()
    XCTAssertTrue(driver.waitForLabel("按下新的原处翻译快捷键", in: chip, timeout: 3))
    driver.app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
    XCTAssertTrue(driver.waitForLabel("原处翻译快捷键 未设置", in: chip, timeout: 3))
    driver.settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(driver.settingsWindow.waitForNonExistence(timeout: 3))
    // A running layer draws the window again within a second of it coming back to the front.
    source.app.activate()
    XCTAssertNil(
      layer.wait(timeout: 5) { $0.contains("CIDA_LAYER_TRANSLATED_") },
      "With the source in front again, no translation comes back")

    // 恢复默认 brings the shortcut and the remembered window back.
    driver.showPanel()
    driver.openSettings()
    let reset = driver.app.buttons["settings-layer-shortcut-reset"]
    XCTAssertTrue(reset.waitForExistence(timeout: 3))
    reset.click()
    XCTAssertTrue(driver.waitForLabel("原处翻译快捷键 ⌥ D", in: chip, timeout: 3))
    driver.settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(driver.settingsWindow.waitForNonExistence(timeout: 3))
    source.app.activate()
    XCTAssertNotNil(
      layer.wait(timeout: 25) { $0.contains("CIDA_LAYER_TRANSLATED_2") },
      "The window translated whole is still remembered")
    source.captureText.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    source.press("d", modifierFlags: [.option, .shift])
    XCTAssertNotNil(
      layer.wait(timeout: 10) { !$0.contains("CIDA_LAYER_TRANSLATED_") }, "and ⌥⇧D stops it again")
  }

  func testFirstUseConnectsThenOffersAnExplicitTrial() throws {
    driver.launch(endpointOverride: false)
    XCTAssertFalse(driver.composer.exists)
    XCTAssertFalse(driver.translateAction.exists)
    attachWelcome("welcome-before-configuration")
    driver.app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(driver.settingsWindow.waitForExistence(timeout: 5))
    try driver.configureModelService()
    driver.settingsWindow.typeKey("w", modifierFlags: .command)
    driver.app.typeKey("a", modifierFlags: .option)
    let trial = driver.app.buttons["welcome-try-translation"]
    XCTAssertTrue(trial.waitForExistence(timeout: 5))
    XCTAssertFalse(driver.resultPane.exists, "Connecting does not send the sample")
    attachWelcome("welcome-ready-for-trial")
    trial.click()
    XCTAssertTrue(driver.composer.waitForExistence(timeout: 5))
    XCTAssertEqual(driver.composer.value as? String, "Good tools leave room for thought.")
    XCTAssertTrue(driver.resultPane.waitForExistence(timeout: 10))
    XCTAssertTrue(driver.copyButton.waitForExistence(timeout: 15))
    attachWelcome("welcome-trial-completed")
  }

  private func attachWelcome(_ name: String) {
    let attachment = XCTAttachment(screenshot: driver.panel.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// `Design/spec/configuration.md` §四: Settings starts with the onboarding card, copies the
  /// prompt, and follows what the artifact's own command line writes and checks while the
  /// window stays open. Prompts are still edited in Settings.
  func testModelServiceFollowsTheCommandLineAndPromptsEditInSettings() throws {
    driver.launch(endpointOverride: false)
    driver.openSettings()
    let settingsWindow = driver.settingsWindow
    func attachConfiguration(_ name: String) {
      let shot = XCTAttachment(screenshot: settingsWindow.screenshot())
      shot.name = "agent-configuration-" + name
      shot.lifetime = .keepAlways
      add(shot)
    }

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

    // Partial writes preserve the chosen service and only ask for the missing input.
    let partial = try driver.runCommandLine([
      "config", "set", "endpoint=https://api.deepseek.com/chat/completions", "model=deepseek-chat",
    ])
    XCTAssertEqual(partial.status, 0, partial.errorOutput)
    XCTAssertTrue(driver.waitForValue("还没配好", in: driver.modelStatus, timeout: 3))
    XCTAssertFalse(driver.modelCheckButton.isEnabled)
    XCTAssertTrue(driver.waitForText(containing: "还差 API Key",
      in: driver.element(identifier: "settings-model-guidance"), timeout: 3))
    attachConfiguration("missing-key")
    copy.click()
    XCTAssertTrue(driver.waitForLabel("已复制", in: copy, timeout: 0.6))
    XCTAssertTrue((NSPasteboard.general.string(forType: .string) ?? "").contains("继续配置："))

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
      driver.waitForValue("已配置 · 未检查", in: driver.modelStatus, timeout: 3),
      "The open window refreshes at once")
    XCTAssertFalse(driver.modelOnboarding.exists)
    XCTAssertTrue(
      driver.waitForText(containing: "cida-ui-mock-model", in: driver.modelSummary, timeout: 1))
    XCTAssertTrue(
      driver.waitForText(containing: "127.0.0.1", in: driver.modelSummary, timeout: 1))
    XCTAssertTrue(
      driver.waitForValue("已配置 · 未检查", in: driver.modelStatus, timeout: 5),
      "Complete configuration is immediately usable")

    attachConfiguration("configured-unchecked")
    let detail = driver.element(identifier: "settings-model-check-detail")
    XCTAssertTrue(detail.waitForNonExistence(timeout: 5), "The update hint expires")
    copy.click()
    XCTAssertTrue(driver.waitForLabel("已复制", in: copy, timeout: 0.6))
    XCTAssertTrue((NSPasteboard.general.string(forType: .string) ?? "").contains("调整配置："))
    driver.app.buttons["settings-return-to-panel"].click()
    XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))
    XCTAssertTrue(driver.app.buttons["welcome-skip-trial"].waitForExistence(timeout: 3))
    driver.openSettings()

    // 检查 sends the same request as `Cida check`.
    driver.modelCheckButton.click()
    XCTAssertNotNil(try scenarioServer.wait(for: "hello", status: "completed", timeout: 10))
    XCTAssertTrue(driver.waitForValue("检查通过", in: driver.modelStatus, timeout: 5))
    attachConfiguration("check-passed")
    XCTAssertFalse(driver.modelFailure.exists)

    // A failing command-line check shows its outcome; diagnosis belongs to the agent.
    let unreachable = try driver.runCommandLine([
      "config", "set", "endpoint=http://127.0.0.1:9/v1/chat/completions",
    ])
    XCTAssertEqual(unreachable.status, 0)
    let check = try driver.runCommandLine(["check"])
    XCTAssertEqual(check.status, 69, check.output)
    XCTAssertTrue(check.output.hasPrefix("✗ 检查失败 · 连不上服务"), check.output)
    XCTAssertTrue(
      driver.waitForValue("检查未通过", in: driver.modelStatus, timeout: 3))
    XCTAssertTrue(
      driver.waitForText(
        containing: "复制配置提示词，交给 AI 助手继续检查。", in: driver.modelFailure, timeout: 2))
    let visibleText = driver.app.staticTexts.allElementsBoundByIndex.map {
      ($0.value as? String ?? "") + $0.label
    }.joined(separator: "\n")
    XCTAssertFalse(visibleText.contains("连不上服务"))
    attachConfiguration("check-failed")
    copy.click()
    XCTAssertTrue(driver.waitForLabel("已复制", in: copy, timeout: 0.6))
    let repairPrompt = NSPasteboard.general.string(forType: .string) ?? ""
    XCTAssertTrue(repairPrompt.contains("继续检查：最近一次检查未通过"))
    XCTAssertTrue(repairPrompt.contains("Cida check --verbose"))
    XCTAssertFalse(repairPrompt.contains("连不上服务"))
    try driver.configureModelService()
    XCTAssertTrue(
      driver.waitForValue("已配置 · 未检查", in: driver.modelStatus, timeout: 3),
      "A changed configuration is unchecked until a new check finishes")
    XCTAssertFalse(driver.modelFailure.exists)
    XCTAssertTrue(driver.waitForText(containing: "之前的检查结果不再适用",
      in: driver.element(identifier: "settings-model-guidance"), timeout: 3))
    attachConfiguration("configuration-invalidates-check")

    driver.showSettingsTab("translation", title: "动作")
    XCTAssertFalse(driver.app.textViews["settings-action-prompt"].exists, "Prompts start collapsed")
    driver.app.buttons["settings-action-improve"].click()
    driver.app.buttons["settings-action-edit"].click()
    let improveEditor = driver.app.textViews["settings-action-prompt"]
    XCTAssertTrue(improveEditor.waitForExistence(timeout: 3))
    let customPrompt = "Improve this text while preserving its source language."
    driver.replaceText(in: improveEditor, with: customPrompt)
    XCTAssertEqual(improveEditor.value as? String, customPrompt)

    settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))
    driver.app.typeKey("a", modifierFlags: .option)
    let skipTrial = driver.app.buttons["welcome-skip-trial"]
    XCTAssertTrue(skipTrial.waitForExistence(timeout: 5))
    skipTrial.click()
    XCTAssertTrue(driver.composer.waitForExistence(timeout: 3))
    driver.openSettings()
    XCTAssertTrue(
      driver.waitForTitle("动作", of: settingsWindow, timeout: 3), "Settings reopens on the last tab")
    XCTAssertEqual(
      driver.app.textViews["settings-action-prompt"].value as? String,
      customPrompt
    )
    driver.app.buttons["settings-action-done"].click()
    XCTAssertTrue(driver.app.buttons["settings-action-edit"].waitForExistence(timeout: 10))
    let show = try driver.runCommandLine(["config", "show", "--json"])
    XCTAssertTrue(show.output.contains(customPrompt), "Settings and the command line share one store")
    XCTAssertTrue(show.output.contains(#""model": "cida-ui-mock-model""#), "and Settings kept it")

    driver.app.buttons["settings-action-edit"].click()
    let resetPrompt = driver.app.buttons["settings-action-reset"]
    XCTAssertTrue(resetPrompt.waitForExistence(timeout: 3))
    resetPrompt.click()
    XCTAssertTrue(
      driver.waitForValue(
        "You are a writing assistant. Improve the user-provided text for clarity, grammar, "
          + "and natural tone. Keep the original language and meaning. Prefer precise technical "
          + "wording. Return only the improved text.",
        in: driver.app.textViews["settings-action-prompt"],
        timeout: 3
      )
    )
    driver.showSettingsTab("general", title: "通用")
    let launchAtLogin = driver.element(identifier: "settings-launch-at-login-toggle")
    XCTAssertTrue(launchAtLogin.waitForExistence(timeout: 3))
    XCTAssertEqual(launchAtLogin.elementType, .checkBox)
    let feedback = driver.app.buttons["settings-feedback"]
    XCTAssertTrue(feedback.exists, "反馈 lives in Settings, not in the menu bar menu")
    XCTAssertEqual(feedback.label, "去反馈")
  }

  func testCustomActionsEditPreviewReorderAndRunInThePanel() throws {
    driver.launch()
    driver.openSettings()
    driver.showSettingsTab("translation", title: "动作")
    func shot(_ name: String) {
      let attachment = XCTAttachment(screenshot: driver.settingsWindow.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    shot("actions-browse")
    let sample = driver.element(identifier: "settings-action-sample")
    let sampleFrame = sample.frame
    let editFrame = driver.app.buttons["settings-action-edit"].frame
    let adjacentActionFrame = driver.app.buttons["settings-action-improve"].frame
    driver.app.buttons["settings-action-edit"].click()
    XCTAssertTrue(driver.app.textViews["settings-action-prompt"].waitForExistence(timeout: 3))
    XCTAssertFalse(driver.element(identifier: "settings-action-preview").exists,
      "Editing without an old result has no empty output pane")
    XCTAssertFalse(driver.app.buttons["settings-action-delete"].exists,
      "The required translation action does not offer deletion")
    XCTAssertEqual(sample.frame.minY, sampleFrame.minY, accuracy: 1)
    XCTAssertEqual(driver.app.buttons["settings-action-improve"].frame, adjacentActionFrame,
      "Turning the selected label into a name field must not shift adjacent actions")
    XCTAssertEqual(driver.app.buttons["settings-action-done"].frame, editFrame,
      "Editing keeps the action bar and its button in place")
    shot("actions-editing-without-result")
    driver.settingsWindow.typeKey(.escape, modifierFlags: [])
    driver.app.buttons["settings-action-add"].click()
    let name = driver.app.textFields["settings-action-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 3))
    driver.replaceText(in: name, with: "Summary")
    let prompt = driver.app.textViews["settings-action-prompt"]
    driver.replaceText(in: prompt, with: "Temporary wording")
    prompt.typeKey(.leftArrow, modifierFlags: .option)
    prompt.typeKey(.delete, modifierFlags: .command)
    XCTAssertTrue(prompt.exists, "Text editing shortcuts must not reorder or delete the action")
    driver.replaceText(in: prompt, with: "Summarize the source in French.")
    shot("actions-editing")
    XCTAssertFalse(driver.app.buttons["settings-action-add"].isEnabled)
    driver.app.buttons["settings-action-done"].click()
    let preview = driver.element(identifier: "settings-action-preview")
    XCTAssertTrue(driver.waitForText(containing: "CIDA_ACTION_SAMPLE_COMPLETE", in: preview, timeout: 10))
    shot("actions-preview")
    let requests = try scenarioServer.state().count
    driver.app.buttons["settings-action-edit"].click()
    XCTAssertTrue(driver.waitForText(containing: "CIDA_ACTION_SAMPLE_COMPLETE", in: preview, timeout: 3),
      "A real previous result stays available while editing")
    shot("actions-editing-with-result")
    driver.replaceText(in: name, with: "Concise")
    driver.app.buttons["settings-action-done"].click()
    XCTAssertEqual(try scenarioServer.state().count, requests, "Renaming keeps the cached preview")
    let custom = driver.app.buttons.matching(NSPredicate(format: "label == %@", "Concise")).firstMatch
    let target = driver.app.buttons["settings-action-translate"]
    custom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.2, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
    XCTAssertLessThan(custom.frame.minX, target.frame.minX)
    driver.settingsWindow.typeKey(.rightArrow, modifierFlags: .option)
    XCTAssertGreaterThan(custom.frame.minX, target.frame.minX)
    driver.settingsWindow.typeKey(.leftArrow, modifierFlags: .option)
    XCTAssertLessThan(custom.frame.minX, target.frame.minX)
    shot("actions-reordered")
    driver.settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    driver.showPanel()
    let selected = driver.app.buttons.matching(NSPredicate(format: "label == %@", "Concise")).firstMatch
    XCTAssertTrue(selected.waitForExistence(timeout: 3))
    XCTAssertTrue(selected.isSelected)
    driver.submit("CIDA_E2E_POOL_CUSTOM_ACTION")
    XCTAssertTrue(driver.result(containing: "CIDA_E2E_POOL_CUSTOM_ACTION_COMPLETE").waitForExistence(timeout: 10))
    driver.waitForCompletion()
    let result = XCTAttachment(screenshot: driver.panel.screenshot())
    result.name = "actions-panel"
    result.lifetime = .keepAlways
    add(result)
    driver.openSettings()
    driver.app.buttons["settings-action-edit"].click()
    driver.app.buttons["settings-action-delete"].click()
    XCTAssertTrue(driver.app.buttons["settings-action-undo"].waitForExistence(timeout: 3))
    driver.app.buttons["settings-action-undo"].click()
    XCTAssertTrue(driver.app.buttons.matching(NSPredicate(format: "label == %@", "Concise")).firstMatch.exists)
  }

  func testActionPreviewFailureRetryAndStopKeepThePreviousResult() throws {
    driver.launch()
    driver.openSettings()
    driver.showSettingsTab("translation", title: "动作")
    let preview = driver.element(identifier: "settings-action-preview")
    let status = driver.element(identifier: "settings-action-preview-status")
    func apply(_ policy: String) {
      driver.app.buttons["settings-action-edit"].click()
      driver.replaceText(in: driver.app.textViews["settings-action-prompt"], with: policy)
      driver.settingsWindow.typeKey(.return, modifierFlags: .command)
    }
    apply("Translate the sample.")
    XCTAssertTrue(driver.waitForText(containing: "CIDA_ACTION_SAMPLE_COMPLETE", in: preview, timeout: 10))
    apply("Translate the sample. CIDA_ACTION_RETRY")
    XCTAssertNotNil(try scenarioServer.wait(for: "CIDA_ACTION_RETRY", status: "failed"))
    XCTAssertTrue(driver.app.buttons["settings-action-edit"].waitForExistence(timeout: 5))
    XCTAssertTrue(driver.waitForText(containing: "CIDA_ACTION_SAMPLE_COMPLETE", in: preview, timeout: 3))
    XCTAssertTrue(driver.waitForText(containing: "503", in: status, timeout: 3))
    let failure = XCTAttachment(screenshot: driver.settingsWindow.screenshot())
    failure.name = "actions-preview-failed"
    failure.lifetime = .keepAlways
    add(failure)
    driver.app.buttons["settings-action-edit"].click()
    driver.app.buttons["settings-action-done"].click()
    XCTAssertTrue(driver.waitForText(containing: "CIDA_ACTION_RECOVERED", in: preview, timeout: 10))
    XCTAssertEqual(try scenarioServer.state().filter { $0.scenario == "CIDA_ACTION_RETRY" }.count, 2)
    apply("Translate the sample. CIDA_ACTION_STOP")
    XCTAssertNotNil(try scenarioServer.wait(for: "CIDA_ACTION_STOP", status: "headers-sent"))
    XCTAssertTrue(driver.app.buttons["settings-action-stop"].waitForExistence(timeout: 3))
    driver.app.buttons["settings-action-stop"].click()
    XCTAssertTrue(driver.waitForText(containing: "已停止", in: status, timeout: 3))
    try scenarioServer.releaseFirstByte(for: "CIDA_ACTION_STOP")
    XCTAssertTrue(driver.waitForText(containing: "CIDA_ACTION_RECOVERED", in: preview, timeout: 3))
    XCTAssertFalse(driver.waitForText(containing: "CIDA_ACTION_STOPPED_LATE", in: preview, timeout: 1))
    let stopped = XCTAttachment(screenshot: driver.settingsWindow.screenshot())
    stopped.name = "actions-preview-stopped"
    stopped.lifetime = .keepAlways
    add(stopped)
  }

  func testActionDraftSurvivesSettingsClosureAndOnlyAppliedChangesSurviveRelaunch() throws {
    driver.launch()
    driver.openSettings()
    driver.showSettingsTab("translation", title: "动作")
    driver.app.buttons["settings-action-add"].click()
    let name = driver.app.textFields["settings-action-name"]
    let prompt = driver.app.textViews["settings-action-prompt"]
    driver.replaceText(in: name, with: "Persistent summary")
    driver.replaceText(in: prompt, with: "Summarize the source in French.")
    driver.showSettingsTab("model", title: "模型")
    driver.showSettingsTab("translation", title: "动作")
    XCTAssertEqual(name.value as? String, "Persistent summary")
    XCTAssertEqual(prompt.value as? String, "Summarize the source in French.")
    driver.settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    driver.showPanel()
    driver.openSettings()
    XCTAssertEqual(name.value as? String, "Persistent summary")
    XCTAssertEqual(prompt.value as? String, "Summarize the source in French.")
    driver.app.buttons["settings-action-done"].click()
    XCTAssertTrue(driver.waitForText(containing: "CIDA_ACTION_SAMPLE_COMPLETE",
      in: driver.element(identifier: "settings-action-preview"), timeout: 10))
    driver.settingsWindow.typeKey(.leftArrow, modifierFlags: .option)
    driver.settingsWindow.typeKey(.leftArrow, modifierFlags: .option)
    driver.app.buttons["settings-action-edit"].click()
    driver.replaceText(in: name, with: "Unsaved rename")
    driver.replaceText(in: prompt, with: "Unsaved policy")
    driver.terminate()
    driver.launch()
    let saved = driver.app.buttons.matching(NSPredicate(format: "label == %@", "Persistent summary")).firstMatch
    XCTAssertTrue(saved.waitForExistence(timeout: 3))
    XCTAssertTrue(saved.isSelected, "The reordered default survives a process restart")
    driver.openSettings()
    driver.showSettingsTab("translation", title: "动作")
    XCTAssertFalse(driver.app.textViews["settings-action-prompt"].exists)
    XCTAssertFalse(driver.waitForText(containing: "CIDA_ACTION_SAMPLE_COMPLETE",
      in: driver.element(identifier: "settings-action-preview"), timeout: 1), "Previews are session-only")
    driver.app.buttons["settings-action-edit"].click()
    XCTAssertEqual(driver.app.textFields["settings-action-name"].value as? String, "Persistent summary")
    XCTAssertEqual(driver.app.textViews["settings-action-prompt"].value as? String, "Summarize the source in French.")
  }

  func testActionValidationAndOverflowKeepCreationReachable() throws {
    driver.launch()
    driver.openSettings()
    driver.showSettingsTab("translation", title: "动作")
    let initialWidth = driver.settingsWindow.frame.width
    driver.app.buttons["settings-action-add"].click()
    let name = driver.app.textFields["settings-action-name"]
    let prompt = driver.app.textViews["settings-action-prompt"]
    driver.replaceText(in: name, with: " ")
    driver.app.buttons["settings-action-done"].click()
    XCTAssertTrue(driver.waitForText(containing: "给动作起一个名字",
      in: driver.element(identifier: "settings-action-validation"), timeout: 3))
    driver.replaceText(in: name, with: "Long action name that exceeds the visible segment width")
    driver.app.buttons["settings-action-done"].click()
    XCTAssertTrue(driver.waitForText(containing: "写下你希望这个动作做什么",
      in: driver.element(identifier: "settings-action-validation"), timeout: 3))
    XCTAssertEqual(try scenarioServer.state().count, 0, "Invalid drafts send no model requests")
    for index in 0..<6 {
      if index > 0 {
        let add = driver.app.buttons["settings-action-add"]
        XCTAssertTrue(add.isHittable, "Creation stays reachable when the action rail overflows")
        add.click()
      }
      driver.replaceText(in: name, with: "Long action name \(index) that exceeds the visible segment width")
      driver.replaceText(in: prompt, with: "Summarize the source in French.")
      driver.app.buttons["settings-action-done"].click()
      XCTAssertTrue(driver.waitForText(containing: "CIDA_ACTION_SAMPLE_COMPLETE",
        in: driver.element(identifier: "settings-action-preview"), timeout: 10))
      XCTAssertEqual(driver.settingsWindow.frame.width, initialWidth, accuracy: 1)
    }
    let overflow = XCTAttachment(screenshot: driver.settingsWindow.screenshot())
    overflow.name = "actions-overflow"
    overflow.lifetime = .keepAlways
    add(overflow)
    driver.settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    driver.showPanel()
    for _ in 0..<7 { driver.composer.typeKey(.tab, modifierFlags: []) }
    let last = driver.app.buttons.matching(NSPredicate(format: "label == %@",
      "Long action name 5 that exceeds the visible segment width")).firstMatch
    XCTAssertTrue(last.isSelected)
    XCTAssertTrue(last.isHittable, "Tab scrolls the selected action into the production panel")
    XCTAssertEqual(driver.panel.frame.width, 800, accuracy: 1)
  }

  func testGlobalShortcutIsRecordedInSettingsAndSummonsThePanel() {
    driver.launch()
    driver.openSettings()
    XCTAssertTrue(driver.waitForTitle("模型", of: driver.settingsWindow, timeout: 3), "Settings opens on 模型")
    driver.showSettingsTab("shortcuts", title: "快捷键")
    let chip = driver.app.buttons["settings-shortcut"]
    XCTAssertTrue(chip.waitForExistence(timeout: 3))
    XCTAssertEqual(chip.label, "显示辞达快捷键 ⌥ A")
    XCTAssertFalse(
      driver.app.buttons["settings-shortcut-reset"].exists, "The default has nothing to restore")
    let captureChip = driver.app.buttons["settings-capture-shortcut"]
    XCTAssertEqual(captureChip.label, "截图翻译快捷键 ⌥ S")
    XCTAssertEqual(driver.app.buttons["settings-layer-shortcut"].label, "原处翻译快捷键 ⌥ D")
    XCTAssertTrue(
      driver.element(identifier: "settings-selection-access-granted").exists,
      "The guest granted Accessibility, and the 权限 group reads it")
    XCTAssertTrue(
      driver.element(identifier: "settings-capture-access-granted").exists,
      "The guest granted Screen Recording, and the 权限 group reads it")
    XCTAssertFalse(driver.app.buttons["settings-capture-access-request"].exists)

    chip.click()
    XCTAssertTrue(driver.waitForLabel("按下新的显示辞达快捷键", in: chip, timeout: 3), "A click starts recording")
    driver.app.typeKey("t", modifierFlags: [.control, .option])
    XCTAssertTrue(driver.waitForLabel("显示辞达快捷键 ⌃ ⌥ T", in: chip, timeout: 3), "The next combination is kept")
    let reset = driver.app.buttons["settings-shortcut-reset"]
    XCTAssertTrue(reset.waitForExistence(timeout: 3))

    driver.settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(driver.settingsWindow.waitForNonExistence(timeout: 3))
    driver.app.typeKey("a", modifierFlags: .option)
    XCTAssertFalse(
      driver.waitForExistence(of: driver.panel, timeout: 1),
      "The previous combination no longer shows the panel")
    driver.app.typeKey("t", modifierFlags: [.control, .option])
    XCTAssertTrue(driver.panel.waitForExistence(timeout: 5), "The recorded combination shows the panel")
    XCTAssertTrue(driver.composer.waitForExistence(timeout: 3))

    driver.openSettings()
    XCTAssertTrue(reset.waitForExistence(timeout: 3))
    reset.click()
    XCTAssertTrue(driver.waitForLabel("显示辞达快捷键 ⌥ A", in: chip, timeout: 3))
    XCTAssertTrue(reset.waitForNonExistence(timeout: 3), "The default has nothing to restore")

    // ⌫ while recording leaves the action without a shortcut.
    chip.click()
    XCTAssertTrue(driver.waitForLabel("按下新的显示辞达快捷键", in: chip, timeout: 3))
    driver.app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
    XCTAssertTrue(driver.waitForLabel("显示辞达快捷键 未设置", in: chip, timeout: 3), "⌫ clears it")
    XCTAssertTrue(reset.waitForExistence(timeout: 3), "未设置 goes back to the default in one click")
    // A registered hot key answers while Settings is in front too, so this shows it is gone.
    driver.app.typeKey("a", modifierFlags: .option)
    XCTAssertFalse(
      driver.waitForExistence(of: driver.panel, timeout: 1), "Without a shortcut ⌥A does nothing")
    reset.click()
    XCTAssertTrue(driver.waitForLabel("显示辞达快捷键 ⌥ A", in: chip, timeout: 3))
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
    driver.launch(endpointOverride: false, configuredBeforeLaunch: true)
    driver.openSettings()
    XCTAssertTrue(driver.waitForExistence(of: driver.modelStatus, timeout: 3))
    XCTAssertTrue(driver.waitForValue("已配置 · 未检查", in: driver.modelStatus, timeout: 3))
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

/// The translation layer as the journeys see it: the source's article paragraphs, and what Cida
/// draws over them, read from its overlays.
@MainActor
private struct TranslationLayerProbe {
  let cida: XCUIApplication
  let source: SourceApplication

  func paragraph(_ number: Int) -> XCUIElement {
    source.app.staticTexts.matching(
      NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@",
        "CIDA LAYER PARAGRAPH \(number).", "CIDA LAYER PARAGRAPH \(number).")
    ).firstMatch
  }

  /// A screenshot, taken within `timeout`, in which paragraph `number` shows the accent underlay
  /// of a paragraph waiting for its translation (§二 等待): on the source's white page, most of
  /// its pixels turn green, the accent's hue, even at the breath's faintest 10 %. The screen, not
  /// the element: an element's screenshot is its own window's, without Cida's overlay above it.
  func screenshotShowingWaiting(on number: Int, within timeout: TimeInterval) -> XCUIScreenshot? {
    let frame = paragraph(number).frame
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let screenshot = XCUIScreen.main.screenshot()
      if let (tinted, sampled) = Self.greenPixels(in: screenshot.image, within: frame), sampled > 0,
        tinted * 2 > sampled
      {
        return screenshot
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return nil
  }

  /// Samples `frame` (screen points, top-left origin) of a full-screen image, drawn into a
  /// context of known layout: the first row in memory is the screen's top.
  private static func greenPixels(in image: NSImage, within frame: CGRect) -> (Int, Int)? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let screen = NSScreen.screens.first,
      let context = CGContext(
        data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
        bytesPerRow: cgImage.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    guard let data = context.data else { return nil }
    let pixels = data.bindMemory(to: UInt8.self, capacity: cgImage.width * cgImage.height * 4)
    let scale = CGFloat(cgImage.width) / screen.frame.width
    var tinted = 0, sampled = 0
    for y in stride(from: frame.minY + 2, to: frame.maxY - 2, by: 2) {
      for x in stride(from: frame.minX + 2, to: frame.maxX - 2, by: 4) {
        let column = Int(x * scale), row = Int(y * scale)
        guard column < cgImage.width, row < cgImage.height else { continue }
        let offset = (row * cgImage.width + column) * 4
        sampled += 1
        if Int(pixels[offset + 1]) - Int(pixels[offset]) >= 3 { tinted += 1 }
      }
    }
    return (tinted, sampled)
  }

  /// Everything the layer draws now, across its panes.
  func shown() -> String {
    cida.descendants(matching: .any).matching(identifier: "translation-layer-content")
      .allElementsBoundByIndex.compactMap { $0.value as? String }.joined(separator: "\n")
  }

  func wait(timeout: TimeInterval, until condition: (String) -> Bool) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let text = shown()
      if condition(text) { return text }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } while Date() < deadline
    return nil
  }

  /// ⌥D, or ⌥⇧D, with the pointer on a paragraph.
  func press(on number: Int, wholeWindow: Bool = false) {
    paragraph(number).coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).hover()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    source.press("d", modifierFlags: wholeWindow ? [.option, .shift] : .option)
  }
}

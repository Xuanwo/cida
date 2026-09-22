import XCTest

@MainActor
final class VisualAndAccessibilityJourneyTests: CidaReleaseUITestCase {
  /// The empty panel is the one main state every launch can reproduce
  /// deterministically; it pins the Pencil `空态` pixels.
  func testEmptyPanelMatchesTheApprovedPencilBaseline() throws {
    driver.launch()
    XCTAssertEqual(driver.panel.frame.width, 800, accuracy: 1)
    XCTAssertEqual(driver.panel.frame.height, 113, accuracy: 1)

    let manifest = try VisualBaselineManifest.load(from: e2eEnvironment.sourceRoot)
    XCTAssertEqual(manifest.namespace, "macos-26.4-xcode-26.5-retina-light-v2")
    let baseline = try manifest.baseline(named: "panel-empty")
    try XCTContext.runActivity(named: "Pencil visual baseline: empty panel") { activity in
      try PixelDiff.assertScreenshot(
        driver.panel.screenshot(),
        matches: baseline,
        sourceRoot: e2eEnvironment.sourceRoot,
        activity: activity
      )
    }
  }

  func testSettingsMatchesTheApprovedPencilBaseline() throws {
    driver.launch(endpointOverride: false)
    driver.openSettings()
    let settingsWindow = driver.settingsWindow

    let apiKey = driver.app.secureTextFields["settings-api-key-editor"]
    driver.replaceText(in: apiKey, with: "sk-preview-key-3f2a")
    settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))
    driver.showPanel()
    driver.openSettings()
    XCTAssertEqual(settingsWindow.frame.width, 560, accuracy: 1)
    XCTAssertEqual(settingsWindow.frame.height, 660, accuracy: 1)

    let manifest = try VisualBaselineManifest.load(from: e2eEnvironment.sourceRoot)
    let baseline = try manifest.baseline(named: "settings")
    try XCTContext.runActivity(named: "Pencil visual baseline: settings") { activity in
      try PixelDiff.assertScreenshot(
        settingsWindow.screenshot(),
        matches: baseline,
        sourceRoot: e2eEnvironment.sourceRoot,
        activity: activity
      )
    }
  }

  func testPanelPassesTheNativeSemanticAccessibilityAudit() throws {
    driver.launch()
    driver.submit("CIDA_E2E_POOL_AUDIT")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_POOL_AUDIT_COMPLETE").waitForExistence(timeout: 8))
    driver.waitForCompletion()

    let semanticAuditTypes: XCUIAccessibilityAuditType = [
      .elementDetection,
      .hitRegion,
      .sufficientElementDescription,
      .action,
      .parentChild,
    ]
    try driver.app.performAccessibilityAudit(for: semanticAuditTypes) { issue in
      let element = issue.element
      let diagnostic = """
        type: \(issue.auditType.rawValue)
        summary: \(issue.compactDescription)
        detail: \(issue.detailedDescription)
        identifier: \(element?.identifier ?? "<none>")
        label: \(element?.label ?? "<none>")
        frame: \(String(describing: element?.frame))
        element: \(element?.debugDescription ?? "<none>")
        """
      let attachment = XCTAttachment(string: diagnostic)
      attachment.name = "Accessibility audit diagnostic"
      attachment.lifetime = .keepAlways
      self.add(attachment)
      // The audit covers the panel; the system Touch Bar proxy and menu bar
      // chrome the guest adds around it are not Cida's elements.
      let isOutsideThePanel =
        element.map { !$0.frame.intersects(self.driver.panel.frame) } ?? false
      let isSystemTouchBarProxy =
        issue.auditType == .sufficientElementDescription
        && element?.identifier.isEmpty == true
        && element?.elementType == .touchBar
      return isOutsideThePanel || isSystemTouchBarProxy
    }
  }
}

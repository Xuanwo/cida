import XCTest

@MainActor
final class VisualAndAccessibilityJourneyTests: CidaReleaseUITestCase {
  func testMainTranslateMatchesTheApprovedPencilBaseline() throws {
    try seedDesignTranslateHistory()
    driver.launch()
    XCTAssertEqual(driver.window.frame.width, 860, accuracy: 1)
    XCTAssertEqual(driver.window.frame.height, 640, accuracy: 1)

    let manifest = try VisualBaselineManifest.load(from: e2eEnvironment.sourceRoot)
    XCTAssertEqual(manifest.namespace, "macos-26.4-xcode-26.5-retina-light-v1")
    let baseline = try manifest.baseline(named: "main-translate")
    try XCTContext.runActivity(named: "Pencil visual baseline: main translate") { activity in
      try PixelDiff.assertScreenshot(
        driver.window.screenshot(),
        matches: baseline,
        sourceRoot: e2eEnvironment.sourceRoot,
        activity: activity
      )
    }
  }

  func testSettingsMatchesTheApprovedPencilBaseline() throws {
    driver.launch(endpointOverride: false)
    driver.app.buttons["model-settings-button"].click()
    let settingsWindow = driver.app.windows["设置"]
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

    let apiKey = driver.app.secureTextFields["settings-api-key-editor"]
    driver.replaceText(in: apiKey, with: "sk-preview-key-3f2a")
    settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))
    driver.app.buttons["model-settings-button"].click()
    XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
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

  func testMainWindowPassesTheNativeSemanticAccessibilityAudit() throws {
    try seedDesignTranslateHistory()
    driver.launch()
    let foldedEntryID = "51000000-0000-0000-0000-000000000001"
    let foldedEntry = driver.element(identifier: "history-entry-\(foldedEntryID)")
    XCTAssertTrue(foldedEntry.waitForExistence(timeout: 3))
    foldedEntry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    XCTAssertTrue(
      driver.app.buttons["history-action-redo-\(foldedEntryID)"].waitForExistence(timeout: 3)
    )
    XCTAssertTrue(
      driver.app.buttons["history-action-copy-result-\(foldedEntryID)"].waitForExistence(
        timeout: 3
      )
    )
    let semanticAuditTypes: XCUIAccessibilityAuditType = [
      .elementDetection,
      .hitRegion,
      .sufficientElementDescription,
      .action,
      .parentChild,
    ]
    let nativeWindowControlFrames = [
      XCUIIdentifierCloseWindow,
      XCUIIdentifierMinimizeWindow,
      XCUIIdentifierZoomWindow,
    ].compactMap { identifier -> CGRect? in
      let button = driver.window.buttons[identifier]
      return button.exists ? button.frame : nil
    }
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
      // macOS 26.4 exposes a private decoration group inside each standard
      // window control that fails its own parent/child audit. Keep this
      // exception constrained to that system-owned frame and audit type.
      let isStandardWindowControlDecoration =
        issue.auditType == .parentChild
        && element?.identifier.isEmpty == true
        && nativeWindowControlFrames.contains { $0.contains(element?.frame ?? .null) }
      let isSystemTouchBarProxy =
        issue.auditType == .sufficientElementDescription
        && element?.identifier.isEmpty == true
        && element?.elementType == .touchBar
      return isStandardWindowControlDecoration || isSystemTouchBarProxy
    }
  }

  private func seedDesignTranslateHistory() throws {
    try SQLiteHistoryFixture.seed(
      [
        HistoryFixtureEntry(
          id: UUID(uuidString: "51000000-0000-0000-0000-000000000001")!,
          sortOrder: 0,
          mode: "improve",
          source:
            "This feature are very useful for user, it can makes the process more faster and easy "
            + "to use.",
          result:
            "This feature is very useful — it makes the whole process faster and easier to use.",
          detail: "English · 语气与语法",
          timestamp: "11:32"
        ),
        HistoryFixtureEntry(
          id: UUID(uuidString: "51000000-0000-0000-0000-000000000002")!,
          sortOrder: 1,
          source: "缓存失效是计算机科学中的两大难题之一。",
          result: "Cache invalidation is one of the two hard problems in computer science.",
          detail: "中文 → English",
          timestamp: "14:02"
        ),
        HistoryFixtureEntry(
          id: UUID(uuidString: "51000000-0000-0000-0000-000000000003")!,
          sortOrder: 2,
          source: "我们的系统采用了全新的存储引擎,在保证数据一致性的前提下,显著提升了读写性能。",
          result:
            "Our system adopts a brand-new storage engine that significantly improves read and "
            + "write performance while preserving data consistency.",
          detail: "中文 → English",
          timestamp: "14:05"
        ),
      ],
      at: driver.databasePath,
      controlBaseURL: e2eEnvironment.controlBaseURL
    )
  }
}

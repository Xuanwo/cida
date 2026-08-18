import XCTest

@MainActor
final class HistoryPresentationJourneyTests: CidaReleaseUITestCase {
  func testFoldedRowsExpandIndependentlyCopyFullResultsAndMatchPencilGeometry() throws {
    let firstID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    let secondID = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
    let latestID = UUID(uuidString: "40000000-0000-0000-0000-000000000003")!
    let fullFirstResult =
      "FOLDING_FIRST_RESULT line one remains visible. Line two remains visible. "
      + "Line three must be clipped until expansion."
    try seed(
      [
        HistoryFixtureEntry(
          id: firstID,
          sortOrder: 0,
          mode: "improve",
          source: "FOLDING_FIRST_SOURCE_MUST_START_HIDDEN",
          result: fullFirstResult,
          detail: "English",
          timestamp: "16:11"
        ),
        HistoryFixtureEntry(
          id: secondID,
          sortOrder: 1,
          source: "FOLDING_SECOND_SOURCE_MUST_START_HIDDEN",
          result:
            "FOLDING_SECOND_RESULT line one remains visible. Line two remains visible. "
            + "Line three must be clipped until expansion.",
          detail: "中文 → English",
          timestamp: "16:12"
        ),
        HistoryFixtureEntry(
          id: latestID,
          sortOrder: 2,
          source: "FOLDING_LATEST_SOURCE_STAYS_EXPANDED",
          result: "FOLDING_LATEST_RESULT_STAYS_EXPANDED",
          detail: "中文 → English",
          timestamp: "16:13"
        ),
      ]
    )
    driver.launch()

    let firstSuffix = firstID.uuidString.lowercased()
    let secondSuffix = secondID.uuidString.lowercased()
    let latestSuffix = latestID.uuidString.lowercased()
    let entry = driver.element(identifier: "history-entry-\(firstSuffix)")
    let card = driver.element(identifier: "history-expand-\(firstSuffix)")
    let preview = driver.element(identifier: "history-collapsed-result-\(firstSuffix)")
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    XCTAssertTrue(card.waitForExistence(timeout: 3))
    XCTAssertTrue(preview.waitForExistence(timeout: 3))
    XCTAssertFalse(driver.element(identifier: "history-source-\(firstSuffix)").exists)
    XCTAssertFalse(driver.element(identifier: "history-expand-\(latestSuffix)").exists)
    XCTAssertEqual(card.frame.height, 96, accuracy: 1)
    XCTAssertEqual(preview.frame.minX, card.frame.minX, accuracy: 1)
    XCTAssertEqual(preview.frame.height, 52, accuracy: 1)
    let latestResult = driver.app.textViews["history-result-\(latestID.uuidString)"]
    XCTAssertTrue(latestResult.waitForExistence(timeout: 3))
    XCTAssertEqual(preview.frame.minX, latestResult.frame.minX, accuracy: 1)

    card.click()
    let firstSource = driver.element(identifier: "history-source-\(firstSuffix)")
    let firstResult = driver.app.textViews["history-result-\(firstID.uuidString)"]
    XCTAssertTrue(firstSource.waitForExistence(timeout: 3))
    XCTAssertTrue(firstResult.waitForExistence(timeout: 3))
    XCTAssertEqual(firstSource.frame.minX, entry.frame.minX, accuracy: 2)
    XCTAssertEqual(entry.frame.maxX - firstSource.frame.maxX, 24, accuracy: 2)
    XCTAssertEqual(firstSource.frame.height, 21, accuracy: 1)
    XCTAssertEqual(firstResult.frame.minY - firstSource.frame.maxY, 8, accuracy: 2)
    XCTAssertEqual(firstResult.frame.minX, entry.frame.minX, accuracy: 2)
    XCTAssertEqual(entry.frame.maxX - firstResult.frame.maxX, 24, accuracy: 2)
    XCTAssertLessThanOrEqual(firstResult.frame.maxY, entry.frame.maxY - 15)
    firstResult.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    XCTAssertTrue(
      driver.app.buttons["history-action-redo-\(firstSuffix)"].waitForExistence(timeout: 3)
    )
    XCTAssertTrue(
      driver.app.buttons["history-action-copy-result-\(firstSuffix)"].waitForExistence(timeout: 3)
    )
    let copyFirstSource = driver.app.buttons["history-action-copy-source-\(firstSuffix)"]
    XCTAssertTrue(copyFirstSource.waitForExistence(timeout: 3))
    copyFirstSource.click()
    XCTAssertTrue(driver.waitForPasteboard("FOLDING_FIRST_SOURCE_MUST_START_HIDDEN", timeout: 2))
    let secondExpand = driver.element(identifier: "history-expand-\(secondSuffix)")
    XCTAssertTrue(secondExpand.waitForExistence(timeout: 3))
    secondExpand.click()
    XCTAssertTrue(firstResult.exists)
    XCTAssertTrue(driver.app.textViews["history-result-\(secondID.uuidString)"].exists)
    XCTAssertTrue(
      driver.element(identifier: "history-source-\(secondSuffix)").waitForExistence(timeout: 3)
    )
    driver.element(identifier: "history-collapse-\(firstSuffix)").click()
    XCTAssertTrue(card.waitForExistence(timeout: 3))
    XCTAssertTrue(firstSource.waitForNonExistence(timeout: 3))
    XCTAssertTrue(firstResult.waitForNonExistence(timeout: 3))

    card.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).hover()
    let redo = driver.app.buttons["history-action-redo-\(firstSuffix)"]
    let copy = driver.app.buttons["history-action-copy-result-\(firstSuffix)"]
    XCTAssertTrue(redo.waitForExistence(timeout: 3))
    XCTAssertTrue(copy.waitForExistence(timeout: 3))
    for action in [redo, copy] {
      XCTAssertGreaterThanOrEqual(action.frame.width, 12)
      XCTAssertLessThanOrEqual(action.frame.width, 14)
      XCTAssertGreaterThanOrEqual(action.frame.height, 12)
      XCTAssertLessThanOrEqual(action.frame.height, 14)
      XCTAssertEqual(card.frame.maxX, action.frame.maxX, accuracy: 2)
    }
    XCTAssertEqual(redo.frame.minY - card.frame.minY, 12, accuracy: 2)
    XCTAssertEqual(copy.frame.minY - card.frame.minY, 38, accuracy: 2)
    XCTAssertGreaterThanOrEqual(copy.frame.minX - preview.frame.maxX, 11)

    let screenshot = driver.window.screenshot()
    VisualOracle.assertActionIconInkFitsPencilBounds(
      redo, in: driver.window, screenshot: screenshot)
    VisualOracle.assertActionIconInkFitsPencilBounds(
      copy, in: driver.window, screenshot: screenshot)
    let copyCoordinate = copy.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    copyCoordinate.hover()
    copyCoordinate.click()
    XCTAssertTrue(driver.waitForPasteboard(fullFirstResult, timeout: 2))
  }

  func testExpandedActionsReserveTheirColumnAndNeverLeakIntoAnActiveStream() throws {
    let olderID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let latestID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let latestResultText =
      "Our system adopts a brand-new storage engine that significantly improves read and write "
      + "performance."
    try seed(
      [
        HistoryFixtureEntry(
          id: olderID,
          sortOrder: 0,
          mode: "improve",
          source: "OLDER_SOURCE_SELECTION",
          result: "OLDER_SELECTED_RESULT",
          detail: "English",
          timestamp: "16:01"
        ),
        HistoryFixtureEntry(
          id: latestID,
          sortOrder: 1,
          source: "我们的系统采用了全新的存储引擎,显著提升了读写性能。",
          result: latestResultText,
          detail: "中文 → English",
          timestamp: "14:05"
        ),
      ]
    )
    driver.launch()

    let suffix = latestID.uuidString.lowercased()
    let entry = driver.element(identifier: "history-entry-\(suffix)")
    let source = driver.element(identifier: "history-source-\(suffix)")
    let result = driver.app.textViews["history-result-\(latestID.uuidString)"]
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    XCTAssertTrue(source.waitForExistence(timeout: 3))
    XCTAssertTrue(result.waitForExistence(timeout: 3))
    XCTAssertEqual(source.frame.minX, entry.frame.minX, accuracy: 2)
    XCTAssertEqual(result.frame.minX, entry.frame.minX, accuracy: 2)
    XCTAssertEqual(entry.frame.maxX - source.frame.maxX, 24, accuracy: 2)
    XCTAssertEqual(entry.frame.maxX - result.frame.maxX, 24, accuracy: 2)
    XCTAssertEqual(source.frame.height, 21, accuracy: 1)
    XCTAssertEqual(result.frame.minY - source.frame.maxY, 8, accuracy: 2)
    XCTAssertLessThanOrEqual(result.frame.maxY, entry.frame.maxY - 15)
    result.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()

    let redo = driver.app.buttons["history-action-redo-\(suffix)"]
    let copySource = driver.app.buttons["history-action-copy-source-\(suffix)"]
    let copyResult = driver.app.buttons["history-action-copy-result-\(suffix)"]
    for action in [redo, copySource, copyResult] {
      XCTAssertTrue(action.waitForExistence(timeout: 3))
      XCTAssertGreaterThanOrEqual(action.frame.width, 12)
      XCTAssertLessThanOrEqual(action.frame.width, 14)
      XCTAssertEqual(action.frame.maxX, entry.frame.maxX, accuracy: 2)
    }
    XCTAssertGreaterThanOrEqual(copySource.frame.minX - source.frame.maxX, 11)
    XCTAssertGreaterThanOrEqual(copyResult.frame.minX - result.frame.maxX, 11)
    copyResult.click()
    XCTAssertTrue(driver.waitForPasteboard(latestResultText, timeout: 2))
    XCTAssertEqual(copyResult.value as? String, "copied")
    XCTAssertTrue(driver.waitForValue("idle", in: copyResult, timeout: 2))

    let activeID = driver.submit("CIDA_E2E_CANCEL", expectsStreamingState: true)
    let activeResult = driver.result(containing: "Partial result before cancellation.")
    XCTAssertTrue(activeResult.waitForExistence(timeout: 5))
    XCTAssertTrue(driver.element(identifier: "history-expand-\(suffix)").exists)
    XCTAssertTrue(result.waitForNonExistence(timeout: 3))
    hoverVisibleIntersection(of: activeResult, inside: driver.history)
    for prefix in [
      "history-action-redo-", "history-action-copy-source-", "history-action-copy-result-",
    ] {
      XCTAssertFalse(driver.app.buttons["\(prefix)\(activeID.lowercased())"].exists)
    }
    driver.submitButton.click()
    XCTAssertTrue(driver.waitForLabel("翻译", in: driver.submitButton, timeout: 5))
  }

  func testFoldedResultAlwaysFadesAndLatestMediumSourceCannotHideItsResult() throws {
    let foldedID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
    let latestID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
    let foldedLine = String(repeating: "M", count: 32)
    let sourceLine = String(repeating: "W", count: 28)
    let latestSource = Array(repeating: sourceLine, count: 6).joined(separator: "\n")
    let latestResult = "LATEST_MEDIUM_SOURCE_RESULT_MUST_REMAIN_VISIBLE"
    XCTAssertLessThan(latestSource.count, 800)
    XCTAssertLessThan("\(foldedLine)\n\(foldedLine)".count, 120)

    try seed(
      [
        HistoryFixtureEntry(
          id: foldedID,
          sortOrder: 0,
          source: "The folded source stays hidden.",
          result: "\(foldedLine)\n\(foldedLine)",
          detail: "English",
          timestamp: "09:14"
        ),
        HistoryFixtureEntry(
          id: latestID,
          sortOrder: 1,
          source: latestSource,
          result: latestResult,
          detail: "English",
          timestamp: "09:15"
        ),
      ]
    )
    driver.launch()

    let foldedSuffix = foldedID.uuidString.lowercased()
    let latestSuffix = latestID.uuidString.lowercased()
    let foldedCard = driver.element(identifier: "history-expand-\(foldedSuffix)")
    let foldedPreview = driver.element(identifier: "history-collapsed-result-\(foldedSuffix)")
    let source = driver.element(identifier: "history-source-\(latestSuffix)")
    let result = driver.app.textViews["history-result-\(latestID.uuidString)"]
    XCTAssertTrue(foldedCard.waitForExistence(timeout: 5))
    XCTAssertTrue(foldedPreview.waitForExistence(timeout: 3))
    XCTAssertTrue(source.waitForExistence(timeout: 3))
    XCTAssertTrue(result.waitForExistence(timeout: 3))

    XCTAssertEqual(foldedCard.frame.height, 96, accuracy: 1)
    XCTAssertEqual(foldedPreview.frame.height, 52, accuracy: 1)
    XCTAssertLessThanOrEqual(foldedPreview.frame.maxY, foldedCard.frame.maxY - 9)
    XCTAssertGreaterThanOrEqual(source.frame.height, 35)
    XCTAssertLessThanOrEqual(source.frame.height, 41)
    XCTAssertLessThanOrEqual(result.frame.minY - source.frame.maxY, 30)
    XCTAssertGreaterThan(result.frame.intersection(driver.history.frame).height, 20)
    VisualOracle.assertSecondLineUsesPencilFade(
      foldedPreview,
      attachmentName: "Folded result Pencil fade"
    )
    VisualOracle.assertSecondLineUsesPencilFade(
      source,
      attachmentName: "Latest source Pencil fade"
    )
  }

  func testLongResultUsesTheOuterHistoryScrollAndKeepsItsCopyActionSticky() throws {
    let longID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    let paragraph =
      "Designing distributed systems has never been a matter of simply picking technologies. "
      + "Trade-offs express how much failure a business can tolerate. "
    try seed(
      [
        HistoryFixtureEntry(
          id: longID,
          sortOrder: 0,
          source: String(repeating: "分布式系统需要明确取舍。", count: 80),
          result: String(repeating: paragraph, count: 35),
          detail: "中文 → English",
          timestamp: "15:12",
          sourceCharacterCount: 1_846,
          resultCharacterCount: 3_214
        )
      ]
    )
    driver.launch()

    let result = driver.app.textViews["history-result-\(longID.uuidString)"]
    let copy = driver.app.buttons[
      "history-action-copy-result-\(longID.uuidString.lowercased())"
    ]
    XCTAssertTrue(result.waitForExistence(timeout: 5))
    XCTAssertEqual(driver.history.descendants(matching: .scrollView).count, 0)
    hoverVisibleIntersection(of: result, inside: driver.history)
    XCTAssertTrue(copy.waitForExistence(timeout: 3))
    assertSticky(copy, follows: result, inside: driver.history)

    driver.history.swipeDown()
    hoverVisibleIntersection(of: result, inside: driver.history)
    XCTAssertTrue(copy.waitForExistence(timeout: 3))
    assertSticky(copy, follows: result, inside: driver.history)
  }

  private func seed(_ entries: [HistoryFixtureEntry]) throws {
    try SQLiteHistoryFixture.seed(
      entries,
      at: driver.databasePath,
      controlBaseURL: e2eEnvironment.controlBaseURL
    )
  }

  private func hoverVisibleIntersection(of element: XCUIElement, inside container: XCUIElement) {
    let visibleFrame = element.frame.intersection(container.frame)
    XCTAssertGreaterThan(visibleFrame.height, 20)
    let normalizedY = min(
      0.95,
      max(0.05, (visibleFrame.minY + 16 - container.frame.minY) / container.frame.height)
    )
    container.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: normalizedY)).hover()
  }

  private func assertSticky(
    _ action: XCUIElement,
    follows result: XCUIElement,
    inside history: XCUIElement
  ) {
    let visibleFrame = result.frame.intersection(history.frame)
    XCTAssertGreaterThan(visibleFrame.height, 20)
    XCTAssertGreaterThanOrEqual(action.frame.minY, visibleFrame.minY)
    XCTAssertLessThanOrEqual(action.frame.minY - visibleFrame.minY, 10)
    XCTAssertLessThanOrEqual(action.frame.maxY, visibleFrame.maxY)
  }
}

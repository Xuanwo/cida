import XCTest

@MainActor
final class CoreTranslationJourneyTests: CidaReleaseUITestCase {
  func testUnevenStreamingFollowsFromDetachedHistoryThroughCompletion() throws {
    let entries = (0..<80).map { index in
      HistoryFixtureEntry(
        sortOrder: index,
        source: "Persisted source \(index)",
        result: "Persisted result \(index) with enough content to keep history scrollable."
      )
    }
    try SQLiteHistoryFixture.seed(
      entries,
      at: driver.databasePath,
      controlBaseURL: e2eEnvironment.controlBaseURL
    )
    driver.launch()

    driver.history.swipeDown()
    driver.history.swipeDown()
    XCTAssertTrue(driver.waitForValue("detached", in: driver.history, timeout: 5))

    _ = driver.submit("CIDA_E2E_UNEVEN_STREAM", expectsStreamingState: true)
    XCTAssertNotNil(try scenarioServer.wait(for: "CIDA_E2E_UNEVEN_STREAM"))
    XCTAssertTrue(driver.waitForValue("bottom", in: driver.history, timeout: 8))

    let firstChunk = driver.result(containing: "Uneven response begins.")
    XCTAssertTrue(firstChunk.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(firstChunk.frame.intersection(driver.history.frame).height, 20)

    let completed = driver.result(containing: "CIDA_E2E_UNEVEN_COMPLETE")
    XCTAssertTrue(completed.waitForExistence(timeout: 20))
    XCTAssertTrue(driver.waitForLabel("翻译", in: driver.submitButton, timeout: 5))
    XCTAssertTrue(driver.waitForValue("bottom", in: driver.history, timeout: 5))
    XCTAssertGreaterThan(completed.frame.intersection(driver.history.frame).height, 20)

    XCTContext.runActivity(named: "Uneven stream remains followed") { activity in
      driver.attachWindowScreenshot(named: "CIDA-E2E-011 uneven stream complete", to: activity)
    }
  }

  func testNewSubmissionIsVisiblyEmptyUntilItsControlledFirstByte() throws {
    try SQLiteHistoryFixture.seed(
      [
        HistoryFixtureEntry(
          sortOrder: 0,
          source: "Persisted source",
          result: "Persisted result glyphs that must not leak into a recycled layer."
        )
      ],
      at: driver.databasePath,
      controlBaseURL: e2eEnvironment.controlBaseURL
    )
    driver.launch()

    let firstID = driver.submit("CIDA_E2E_RESULT_A")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_RESULT_A_COMPLETE").waitForExistence(timeout: 8))
    XCTAssertTrue(driver.waitForLabel("翻译", in: driver.submitButton, timeout: 3))
    let firstEntry = driver.element(identifier: "history-entry-\(firstID.lowercased())")
    XCTAssertTrue(
      driver.waitForCurrentExpandedEntry(firstEntry.identifier, timeout: 2)
    )

    let secondID = driver.submit("CIDA_E2E_DELAYED_RESULT_B", expectsStreamingState: true)
    XCTAssertNotNil(
      try scenarioServer.wait(
        for: "CIDA_E2E_DELAYED_RESULT_B",
        status: "headers-sent",
        timeout: 5
      )
    )
    let secondResult = driver.app.textViews["history-result-\(secondID.uppercased())"]
    XCTAssertTrue(secondResult.waitForExistence(timeout: 3))
    XCTAssertEqual(secondResult.value as? String, "")
    XCTAssertEqual(driver.textValue(in: driver.composer), "")
    XCTAssertTrue(driver.waitForFoldedEntry(firstEntry.identifier, timeout: 2))
    XCTAssertTrue(
      driver.waitForCurrentExpandedEntry(
        "history-entry-\(secondID.lowercased())",
        timeout: 2
      )
    )
    XCTAssertEqual(driver.history.value as? String, "bottom")

    XCTContext.runActivity(named: "No old result pixels before the first byte") { activity in
      let screenshot = secondResult.screenshot()
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = "CIDA-E2E-010 controlled pre-byte result"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
      XCTAssertLessThanOrEqual(
        VisualOracle.neutralDarkPixelCount(
          in: screenshot,
          logicalWidth: secondResult.frame.width,
          topPoints: 64
        ),
        24
      )
    }

    try scenarioServer.releaseFirstByte(for: "CIDA_E2E_DELAYED_RESULT_B")
    let completed = driver.result(containing: "CIDA_E2E_RESULT_B_COMPLETE")
    XCTAssertTrue(completed.waitForExistence(timeout: 8))
    XCTAssertFalse((completed.value as? String)?.contains("RESULT_A") ?? true)
    XCTAssertTrue(driver.waitForLabel("翻译", in: driver.submitButton, timeout: 3))
  }

  func testResultContainerPoolRemainsCorrectBeyondItsPrewarmedCapacity() throws {
    driver.launch()

    for index in 0..<5 {
      let scenario = "CIDA_E2E_POOL_\(index)"
      let entryID = driver.submit(scenario)
      let completed = driver.result(containing: "\(scenario)_COMPLETE")
      XCTAssertTrue(completed.waitForExistence(timeout: 8))
      XCTAssertEqual(completed.identifier, "history-result-\(entryID.uppercased())")
      XCTAssertFalse((completed.value as? String)?.contains("POOL_\(index - 1)") ?? false)
      XCTAssertTrue(driver.waitForLabel("翻译", in: driver.submitButton, timeout: 3))
    }

    let gatedID = driver.submit("CIDA_E2E_POOL_GATED", expectsStreamingState: true)
    XCTAssertNotNil(
      try scenarioServer.wait(for: "CIDA_E2E_POOL_GATED", status: "headers-sent", timeout: 5)
    )
    let gatedResult = driver.app.textViews["history-result-\(gatedID.uppercased())"]
    XCTAssertTrue(gatedResult.waitForExistence(timeout: 3))
    XCTAssertEqual(gatedResult.value as? String, "")
    let preByteScreenshot = gatedResult.screenshot()
    XCTAssertLessThanOrEqual(
      VisualOracle.neutralDarkPixelCount(
        in: preByteScreenshot,
        logicalWidth: gatedResult.frame.width,
        topPoints: 64
      ),
      24,
      "A result container reused beyond pool capacity leaked old compositor pixels"
    )

    try scenarioServer.releaseFirstByte(for: "CIDA_E2E_POOL_GATED")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_POOL_GATED_COMPLETE").waitForExistence(timeout: 8)
    )
    XCTAssertEqual(driver.historyEntryCount(), 6)
  }

  func testCancellationFailureAndRecoveryKeepTheJourneyUsable() throws {
    driver.launch()

    _ = driver.submit("CIDA_E2E_CANCEL", expectsStreamingState: true)
    let partial = driver.result(containing: "Partial result before cancellation.")
    XCTAssertTrue(partial.waitForExistence(timeout: 5))
    XCTAssertNotNil(
      try scenarioServer.wait(
        for: "CIDA_E2E_CANCEL",
        minimumChunks: 1,
        timeout: 5
      )
    )
    driver.submitButton.click()
    XCTAssertTrue(driver.waitForLabel("翻译", in: driver.submitButton, timeout: 5))
    XCTAssertTrue(partial.exists)
    XCTAssertFalse((partial.value as? String)?.contains("UNEXPECTED_AFTER_CANCEL") ?? true)

    _ = driver.submit("CIDA_E2E_ERROR")
    XCTAssertNotNil(
      try scenarioServer.wait(for: "CIDA_E2E_ERROR", status: "failed", timeout: 5)
    )
    XCTAssertTrue(driver.waitForLabel("翻译", in: driver.submitButton, timeout: 5))
    let errorSheet = driver.app.sheets["警告"]
    XCTAssertTrue(errorSheet.waitForExistence(timeout: 5))
    XCTAssertTrue(errorSheet.staticTexts["处理失败"].exists)
    let acknowledge = errorSheet.buttons["好"]
    XCTAssertTrue(acknowledge.waitForExistence(timeout: 3))
    acknowledge.click()
    XCTAssertTrue(errorSheet.waitForNonExistence(timeout: 3))

    _ = driver.submit("CIDA_E2E_POOL_RECOVERY")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_POOL_RECOVERY_COMPLETE")
        .waitForExistence(timeout: 8)
    )
    XCTAssertTrue(driver.waitForLabel("翻译", in: driver.submitButton, timeout: 3))
  }
}

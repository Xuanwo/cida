import XCTest

@MainActor
final class CoreTranslationJourneyTests: CidaReleaseUITestCase {
  func testUnevenStreamingGrowsThePanelAndFollowsToCompletion() throws {
    driver.launch()
    let emptyHeight = driver.panel.frame.height

    driver.submit("CIDA_E2E_UNEVEN_STREAM", expectsStreamingState: true)
    XCTAssertNotNil(try scenarioServer.wait(for: "CIDA_E2E_UNEVEN_STREAM"))

    let firstChunk = driver.result(containing: "Uneven response begins.")
    XCTAssertTrue(firstChunk.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(firstChunk.frame.intersection(driver.resultPane.frame).height, 20)

    let completed = driver.result(containing: "CIDA_E2E_UNEVEN_COMPLETE")
    XCTAssertTrue(completed.waitForExistence(timeout: 20))
    driver.waitForCompletion()
    XCTAssertGreaterThan(driver.panel.frame.height, emptyHeight + 40, "The panel grew downward")
    XCTAssertEqual(driver.panel.frame.width, 800, accuracy: 1)
    XCTAssertGreaterThan(completed.frame.intersection(driver.resultPane.frame).height, 20)

    XCTContext.runActivity(named: "Uneven stream completes in the result pane") { activity in
      driver.attachPanelScreenshot(named: "CIDA-E2E-011 uneven stream complete", to: activity)
    }
  }

  func testNewSubmissionIsVisiblyEmptyUntilItsControlledFirstByte() throws {
    driver.launch()

    driver.submit("CIDA_E2E_RESULT_A")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_RESULT_A_COMPLETE").waitForExistence(timeout: 8))
    driver.waitForCompletion()
    assertResultIsPainted("CIDA-E2E-010 completed result A")

    driver.submit("CIDA_E2E_DELAYED_RESULT_B", expectsStreamingState: true)
    XCTAssertNotNil(
      try scenarioServer.wait(
        for: "CIDA_E2E_DELAYED_RESULT_B",
        status: "headers-sent",
        timeout: 5
      )
    )
    XCTAssertTrue(driver.resultText.waitForExistence(timeout: 3))
    XCTAssertEqual(driver.resultText.value as? String, "")
    XCTAssertFalse(driver.copyButton.exists, "No copy while the new request runs")
    XCTAssertEqual(driver.textValue(in: driver.composer), "CIDA_E2E_DELAYED_RESULT_B")

    XCTContext.runActivity(named: "No old result pixels before the first byte") { activity in
      // The pane, not the text view: the text view's accessibility frame is
      // its full document height and would screenshot the desktop below. The
      // bottom 16 pt hold the panel's rounded corners, where the desktop shows,
      // and the leading 34 pt hold the breathing caret, whose faded edge
      // pixels are neutral enough to count as ink.
      let pane = driver.resultPane
      let screenshot = pane.screenshot()
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = "CIDA-E2E-010 controlled pre-byte result"
      attachment.lifetime = .keepAlways
      activity.add(attachment)
      XCTAssertLessThanOrEqual(
        VisualOracle.neutralDarkPixelCount(
          in: screenshot,
          logicalWidth: pane.frame.width,
          topPoints: pane.frame.height - 16,
          ignoringLeadingPoints: 34
        ),
        24
      )
    }

    try scenarioServer.releaseFirstByte(for: "CIDA_E2E_DELAYED_RESULT_B")
    let completed = driver.result(containing: "CIDA_E2E_RESULT_B_COMPLETE")
    XCTAssertTrue(completed.waitForExistence(timeout: 8))
    XCTAssertFalse((completed.value as? String)?.contains("RESULT_A") ?? true)
    driver.waitForCompletion()
    assertResultIsPainted("CIDA-E2E-010 completed result B")
  }

  /// A completed result has to reach the screen, not only the accessibility tree: a result layer
  /// that stops redrawing keeps the right value while the pane stays blank. Painted text leaves
  /// thousands of ink pixels in the pane; an empty pane leaves none. Glyphs are committed to the
  /// layer once their reveal ends, so the pane is sampled until they appear.
  private func assertResultIsPainted(_ name: String) {
    XCTContext.runActivity(named: "\(name) is painted") { activity in
      let pane = driver.resultPane
      var screenshot = pane.screenshot()
      var inkPixels = 0
      let deadline = Date().addingTimeInterval(2)
      repeat {
        screenshot = pane.screenshot()
        inkPixels = VisualOracle.neutralDarkPixelCount(
          in: screenshot,
          logicalWidth: pane.frame.width,
          topPoints: pane.frame.height - 16
        )
        if inkPixels >= 1_000 { break }
        Thread.sleep(forTimeInterval: 0.2)
      } while Date() < deadline
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = name
      attachment.lifetime = .keepAlways
      activity.add(attachment)
      XCTAssertGreaterThanOrEqual(inkPixels, 1_000, "\(name) is not painted in the result pane")
    }
  }

  func testConsecutiveSubmissionsReplaceTheResultWithoutLeakingText() throws {
    driver.launch()

    for index in 0..<5 {
      let scenario = "CIDA_E2E_POOL_\(index)"
      driver.submit(scenario)
      let completed = driver.result(containing: "\(scenario)_COMPLETE")
      XCTAssertTrue(completed.waitForExistence(timeout: 8))
      XCTAssertFalse((completed.value as? String)?.contains("POOL_\(index - 1)") ?? false)
      driver.waitForCompletion()
      XCTAssertEqual(driver.app.textViews.matching(identifier: "result-text").count, 1)
    }

    driver.submit("CIDA_E2E_POOL_GATED", expectsStreamingState: true)
    XCTAssertNotNil(
      try scenarioServer.wait(for: "CIDA_E2E_POOL_GATED", status: "headers-sent", timeout: 5)
    )
    XCTAssertTrue(driver.resultText.waitForExistence(timeout: 3))
    XCTAssertEqual(driver.resultText.value as? String, "")
    let pane = driver.resultPane
    let preByteScreenshot = pane.screenshot()
    XCTAssertLessThanOrEqual(
      VisualOracle.neutralDarkPixelCount(
        in: preByteScreenshot,
        logicalWidth: pane.frame.width,
        topPoints: pane.frame.height - 16,
        ignoringLeadingPoints: 34
      ),
      24,
      "A replaced result leaked old compositor pixels"
    )

    try scenarioServer.releaseFirstByte(for: "CIDA_E2E_POOL_GATED")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_POOL_GATED_COMPLETE").waitForExistence(timeout: 8)
    )
    driver.waitForCompletion()
  }

  func testStopFailureAndRecoveryKeepTheJourneyUsable() throws {
    driver.launch()

    driver.submit("CIDA_E2E_CANCEL", expectsStreamingState: true)
    let partial = driver.result(containing: "Partial result before cancellation.")
    XCTAssertTrue(partial.waitForExistence(timeout: 5))
    XCTAssertNotNil(
      try scenarioServer.wait(
        for: "CIDA_E2E_CANCEL",
        minimumChunks: 1,
        timeout: 5
      )
    )
    driver.stopButton.click()
    XCTAssertTrue(driver.resultNote("stopped").waitForExistence(timeout: 5))
    driver.waitForCompletion()
    XCTAssertTrue(partial.exists, "The partial text stays after 停止")
    XCTAssertFalse((partial.value as? String)?.contains("UNEXPECTED_AFTER_CANCEL") ?? true)

    driver.submit("CIDA_E2E_ERROR")
    XCTAssertNotNil(
      try scenarioServer.wait(for: "CIDA_E2E_ERROR", status: "failed", timeout: 5)
    )
    let failedNote = driver.resultNote("failed")
    XCTAssertTrue(failedNote.waitForExistence(timeout: 5), "Failures explain themselves inline")
    // The combined note row is a static text whose text is its value.
    XCTAssertTrue(
      (failedNote.value as? String ?? "").contains("请求失败"),
      failedNote.debugDescription)
    XCTAssertFalse(driver.app.sheets.firstMatch.exists, "No alert sheet for a request failure")
    XCTAssertFalse(driver.copyButton.exists, "Nothing to copy after a failure without text")

    driver.submit("CIDA_E2E_POOL_RECOVERY")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_POOL_RECOVERY_COMPLETE")
        .waitForExistence(timeout: 8)
    )
    driver.waitForCompletion()
    XCTAssertFalse(driver.resultNote("failed").exists)
  }
}

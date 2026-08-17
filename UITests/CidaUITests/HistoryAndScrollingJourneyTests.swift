import XCTest

@MainActor
final class HistoryAndScrollingJourneyTests: CidaReleaseUITestCase {
  func testHistoryUsesOneOuterScrollSurfaceAndThePencilThumbMovesInTheRightDirection() throws {
    let entries = (0..<100).map { index in
      HistoryFixtureEntry(
        sortOrder: index,
        source: "History source \(index)",
        result: "History result \(index). A second sentence keeps every folded row realistic."
      )
    }
    try SQLiteHistoryFixture.seed(
      entries,
      at: driver.databasePath,
      controlBaseURL: e2eEnvironment.controlBaseURL
    )
    driver.launch()

    XCTAssertEqual(driver.history.descendants(matching: .scrollView).count, 0)
    XCTAssertEqual(driver.history.scrollBars.count, 0)
    XCTAssertTrue(driver.waitForValue("bottom", in: driver.history, timeout: 5))

    let bottomCenter = XCTContext.runActivity(named: "Thumb at newest history") { activity in
      VisualOracle.pencilScrollThumbCenterY(
        in: driver.history,
        activity: activity,
        attachmentName: "CIDA-E2E-022 history thumb at bottom"
      )
    }

    driver.history.swipeDown()
    driver.history.swipeDown()
    XCTAssertTrue(driver.waitForValue("detached", in: driver.history, timeout: 5))
    let olderCenter = XCTContext.runActivity(named: "Thumb after scrolling to older history") {
      activity in
      VisualOracle.pencilScrollThumbCenterY(
        in: driver.history,
        activity: activity,
        attachmentName: "CIDA-E2E-022 history thumb toward older records"
      )
    }
    XCTAssertLessThan(olderCenter, bottomCenter - 2)

    for _ in 0..<8 where driver.history.value as? String != "bottom" {
      driver.history.swipeUp()
    }
    XCTAssertTrue(driver.waitForValue("bottom", in: driver.history, timeout: 5))
  }

  func testDetachingDuringAStreamPausesFollowAndTheNextSubmissionReattaches() throws {
    let entries = (0..<60).map { index in
      HistoryFixtureEntry(
        sortOrder: index,
        source: "Seed source \(index)",
        result: "Seed result \(index)"
      )
    }
    try SQLiteHistoryFixture.seed(
      entries,
      at: driver.databasePath,
      controlBaseURL: e2eEnvironment.controlBaseURL
    )
    driver.launch()

    _ = driver.submit("CIDA_E2E_UNEVEN_STREAM", expectsStreamingState: true)
    XCTAssertTrue(driver.result(containing: "Uneven response begins.").waitForExistence(timeout: 5))
    driver.history.swipeDown()
    driver.history.swipeDown()
    XCTAssertTrue(driver.waitForValue("detached", in: driver.history, timeout: 5))

    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_UNEVEN_COMPLETE").waitForExistence(timeout: 20)
    )
    XCTAssertTrue(driver.waitForLabel("翻译", in: driver.submitButton, timeout: 5))
    XCTAssertEqual(driver.history.value as? String, "detached")

    _ = driver.submit("CIDA_E2E_POOL_REATTACH")
    XCTAssertTrue(driver.waitForValue("bottom", in: driver.history, timeout: 8))
    let completed = driver.result(containing: "CIDA_E2E_POOL_REATTACH_COMPLETE")
    XCTAssertTrue(completed.waitForExistence(timeout: 8))
    XCTAssertGreaterThan(completed.frame.intersection(driver.history.frame).height, 20)
  }
}

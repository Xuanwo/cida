import XCTest

@MainActor
final class TranslationStateMachineJourneyTests: CidaReleaseUITestCase {
  func testSharedStateMachineSmokeSurvivesConsecutiveSubmissionsAndRelaunch() {
    driver.launch()
    var oracle = TranslationJourneyModel()
    var submittedEntryIDs: [String] = []

    for command in TranslationJourneyModel.releaseUISmokeCommands {
      switch command {
      case .paste(let value):
        driver.replaceText(in: driver.composer, with: "")
        driver.paste(value)
        XCTAssertEqual(driver.composer.value as? String, value)
        XCTAssertTrue(oracle.apply(command))
      case .submit:
        let existingEntries = driver.historyEntryIdentifiers()
        XCTAssertTrue(driver.submitButton.isEnabled)
        driver.submitButton.click()
        let entryIdentifier = try! XCTUnwrap(
          driver.waitForNewHistoryEntry(excluding: existingEntries, timeout: 5)
        )
        let entryID = String(entryIdentifier.dropFirst("history-entry-".count))
        submittedEntryIDs.append(entryID)
        XCTAssertTrue(oracle.apply(command))
      case .releaseChunk:
        XCTAssertTrue(oracle.apply(command))
      case .complete:
        XCTAssertTrue(oracle.apply(command))
        let expected = try! XCTUnwrap(oracle.currentEntry)
        let result = driver.app.textViews["history-result-\(submittedEntryIDs.last!.uppercased())"]
        XCTAssertTrue(driver.waitForValue(expected.result, in: result, timeout: 8))
        XCTAssertTrue(driver.waitForLabel("翻译", in: driver.submitButton, timeout: 3))
      case .scrollUp:
        driver.history.swipeDown()
        _ = oracle.apply(command)
      case .scrollBottom:
        for _ in 0..<8 where driver.history.value as? String != "bottom" {
          driver.history.swipeUp()
        }
        _ = oracle.apply(command)
      case .relaunch:
        driver.terminate()
        XCTAssertTrue(oracle.apply(command))
        driver.launch()
      case .type, .deleteAll, .pauseStream, .cancel, .fail, .expand, .collapse, .resize,
        .closeSettings:
        XCTFail("Unsupported Release smoke command: \(command)")
      }
      XCTAssertTrue(oracle.invariantViolations().isEmpty)
    }

    XCTAssertEqual(driver.historyEntryIdentifiers().count, oracle.entries.count)
    let expected = try! XCTUnwrap(oracle.currentEntry)
    let latestID = try! XCTUnwrap(submittedEntryIDs.last)
    let latestResult = driver.app.textViews["history-result-\(latestID.uppercased())"]
    XCTAssertTrue(latestResult.waitForExistence(timeout: 5))
    XCTAssertEqual(latestResult.value as? String, expected.result)
    XCTAssertFalse((latestResult.value as? String)?.contains("STATE_MACHINE_A_COMPLETE") ?? true)
  }
}

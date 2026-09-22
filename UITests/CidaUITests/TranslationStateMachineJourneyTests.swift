import XCTest

@MainActor
final class TranslationStateMachineJourneyTests: CidaReleaseUITestCase {
  func testSharedStateMachineSmokeSurvivesConsecutiveSubmissionsAndHiding() {
    driver.launch()
    var oracle = TranslationJourneyModel()

    for command in TranslationJourneyModel.releaseUISmokeCommands {
      switch command {
      case .paste(let value):
        driver.replaceSource(with: value)
        XCTAssertTrue(oracle.apply(command))
      case .submit:
        driver.submitCurrentSource()
        XCTAssertTrue(oracle.apply(command))
      case .releaseChunk:
        XCTAssertTrue(oracle.apply(command))
      case .complete:
        XCTAssertTrue(oracle.apply(command))
        let expected = try! XCTUnwrap(oracle.result)
        XCTAssertTrue(driver.waitForValue(expected.text, in: driver.resultText, timeout: 8))
        driver.waitForCompletion()
      case .hide:
        driver.hidePanel()
        XCTAssertTrue(oracle.apply(command))
      case .show:
        driver.showPanel()
        XCTAssertTrue(oracle.apply(command))
        XCTAssertTrue(driver.translateAction.isSelected, "Showing resets the action to 翻译")
        let expected = try! XCTUnwrap(oracle.result)
        XCTAssertEqual(driver.resultText.value as? String, expected.text, "Hiding keeps the result")
        XCTAssertEqual(driver.textValue(in: driver.composer), expected.source, "Hiding keeps the source")
      case .type, .deleteAll, .toggleAction, .pauseStream, .cancel, .fail:
        XCTFail("Unsupported Release smoke command: \(command)")
      }
      XCTAssertTrue(oracle.invariantViolations().isEmpty)
    }

    let expected = try! XCTUnwrap(oracle.result)
    XCTAssertEqual(driver.resultText.value as? String, expected.text)
    XCTAssertFalse((driver.resultText.value as? String)?.contains("STATE_MACHINE_A_COMPLETE") ?? true)
    XCTAssertEqual(driver.app.textViews.matching(identifier: "result-text").count, 1)
  }
}

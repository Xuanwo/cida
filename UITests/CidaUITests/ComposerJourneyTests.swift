import XCTest

@MainActor
final class ComposerJourneyTests: CidaReleaseUITestCase {
  func testImprovementPreservesEnglishAndChineseSourceLanguages() {
    driver.launch()

    let improveMode = driver.app.buttons["改进"]
    XCTAssertTrue(improveMode.waitForExistence(timeout: 3))
    improveMode.click()
    let outputHint = driver.element(identifier: "improvement-output-hint")
    XCTAssertTrue(outputHint.waitForExistence(timeout: 3))
    XCTAssertEqual(outputHint.label, "输出跟随原文")

    let englishSource =
      "This sentence are unclear and too wordy. CIDA_E2E_IMPROVE_ENGLISH"
    driver.replaceText(in: driver.composer, with: englishSource)
    XCTAssertTrue(driver.waitForLabel("English · 输出跟随原文", in: outputHint, timeout: 3))
    let englishID = driver.submitCurrentComposer()
    let englishResult = driver.result(containing: "CIDA_E2E_IMPROVE_ENGLISH_COMPLETE")
    XCTAssertTrue(englishResult.waitForExistence(timeout: 8))
    XCTAssertEqual(englishResult.identifier, "history-result-\(englishID.uppercased())")
    XCTAssertTrue(driver.waitForLabel("改进", in: driver.submitButton, timeout: 3))

    let englishEntry = driver.element(identifier: "history-entry-\(englishID.lowercased())")
    XCTAssertTrue(englishEntry.waitForExistence(timeout: 3))
    XCTAssertTrue(englishEntry.label.contains("English · 语气与语法"))
    XCTAssertFalse(englishEntry.label.contains("中文"))

    let chineseSource = "这句话不太清楚也有一点啰嗦。CIDA_E2E_IMPROVE_CHINESE"
    driver.replaceText(in: driver.composer, with: chineseSource)
    XCTAssertTrue(driver.waitForLabel("中文 · 输出跟随原文", in: outputHint, timeout: 3))
    let chineseID = driver.submitCurrentComposer()
    let chineseResult = driver.result(containing: "CIDA_E2E_IMPROVE_CHINESE_COMPLETE")
    XCTAssertTrue(chineseResult.waitForExistence(timeout: 8))
    XCTAssertEqual(chineseResult.identifier, "history-result-\(chineseID.uppercased())")
    XCTAssertTrue(driver.waitForLabel("改进", in: driver.submitButton, timeout: 3))
    let chineseEntry = driver.element(identifier: "history-entry-\(chineseID.lowercased())")
    XCTAssertTrue(chineseEntry.waitForExistence(timeout: 3))
    XCTAssertTrue(chineseEntry.label.contains("中文 · 语气与语法"))
  }

  func testRealTypingPasteGrowthDeletionShrinkAndSubmission() {
    driver.launch()

    driver.composer.click()
    driver.composer.typeText("Typed through the real responder chain")
    XCTAssertEqual(driver.composer.value as? String, "Typed through the real responder chain")

    driver.composer.typeKey("a", modifierFlags: .command)
    driver.composer.typeKey(.delete, modifierFlags: [])
    let multiline = String(
      repeating: "A pasted paragraph should keep a comfortable multiline composer.\n",
      count: 24
    )
    driver.paste(multiline)
    XCTAssertTrue(driver.waitForFrameHeight(atLeast: 150, in: driver.composer, timeout: 5))
    XCTAssertEqual(driver.composer.value as? String, multiline)

    driver.composer.typeKey("a", modifierFlags: .command)
    driver.composer.typeKey(.delete, modifierFlags: [])
    XCTAssertTrue(driver.waitForFrameHeight(atMost: 30, in: driver.composer, timeout: 5))
    XCTAssertEqual(driver.composer.value as? String, "")

    _ = driver.submit("CIDA_E2E_POOL_COMPOSER")
    XCTAssertTrue(driver.waitForFrameHeight(atMost: 30, in: driver.composer, timeout: 5))
    XCTAssertEqual(driver.composer.value as? String, "")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_POOL_COMPOSER_COMPLETE")
        .waitForExistence(timeout: 8)
    )
  }

  func testCommandCCopyPrecedenceCoversComposerSelectionAndLatestResult() throws {
    let olderID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let latestID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    try SQLiteHistoryFixture.seed(
      [
        HistoryFixtureEntry(
          id: olderID,
          sortOrder: 0,
          source: "OLDER_SOURCE",
          result: "OLDER_SELECTED_RESULT"
        ),
        HistoryFixtureEntry(
          id: latestID,
          sortOrder: 1,
          source: "LATEST_SOURCE",
          result: "LATEST_COPYABLE_RESULT"
        ),
      ],
      at: driver.databasePath,
      controlBaseURL: e2eEnvironment.controlBaseURL
    )
    driver.launch()

    driver.composer.click()
    driver.composer.typeText("COMPOSER_SELECTED_TEXT")
    driver.composer.typeKey("a", modifierFlags: .command)
    driver.composer.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(driver.waitForPasteboard("COMPOSER_SELECTED_TEXT", timeout: 2))

    let latestResult = driver.app.textViews["history-result-\(latestID.uuidString)"]
    XCTAssertTrue(latestResult.waitForExistence(timeout: 3))
    latestResult.click()
    latestResult.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(driver.waitForPasteboard("LATEST_COPYABLE_RESULT", timeout: 2))

    let olderSuffix = olderID.uuidString.lowercased()
    let olderExpand = driver.element(identifier: "history-expand-\(olderSuffix)")
    XCTAssertTrue(olderExpand.waitForExistence(timeout: 3))
    olderExpand.click()
    let olderResult = driver.app.textViews["history-result-\(olderID.uuidString)"]
    XCTAssertTrue(olderResult.waitForExistence(timeout: 3))
    olderResult.click()
    olderResult.typeKey("a", modifierFlags: .command)
    olderResult.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(driver.waitForPasteboard("OLDER_SELECTED_RESULT", timeout: 2))
  }
}

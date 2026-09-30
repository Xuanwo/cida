import XCTest

@MainActor
final class ComposerJourneyTests: CidaReleaseUITestCase {
  func testImprovementPreservesEnglishAndChineseSourceLanguages() {
    driver.launch()

    XCTAssertTrue(driver.improveAction.waitForExistence(timeout: 3))
    driver.composer.click()
    driver.composer.typeKey(.tab, modifierFlags: [])
    XCTAssertTrue(driver.improveAction.isSelected, "Tab switches the action to 改进")

    let englishSource =
      "This sentence are unclear and too wordy. CIDA_E2E_IMPROVE_ENGLISH"
    driver.replaceSource(with: englishSource)
    driver.submitCurrentSource()
    let englishResult = driver.result(containing: "CIDA_E2E_IMPROVE_ENGLISH_COMPLETE")
    XCTAssertTrue(englishResult.waitForExistence(timeout: 8))
    driver.waitForCompletion()
    XCTAssertTrue(driver.improveAction.isSelected, "The action stays until the panel hides")

    let chineseSource = "这句话不太清楚也有一点啰嗦。CIDA_E2E_IMPROVE_CHINESE"
    driver.replaceSource(with: chineseSource)
    XCTAssertTrue(driver.resultNote("stale").waitForExistence(timeout: 3), "An edited source marks the result stale")
    driver.submitCurrentSource()
    let chineseResult = driver.result(containing: "CIDA_E2E_IMPROVE_CHINESE_COMPLETE")
    XCTAssertTrue(chineseResult.waitForExistence(timeout: 8))
    driver.waitForCompletion()
    XCTAssertFalse(driver.resultNote("stale").exists)
  }

  func testRealTypingPasteGrowthDeletionShrinkAndSubmission() {
    driver.launch()
    let emptyHeight = driver.panel.frame.height

    driver.composer.click()
    driver.composer.typeText("Typed through the real responder chain")
    XCTAssertEqual(driver.textValue(in: driver.composer), "Typed through the real responder chain")

    driver.composer.typeKey("a", modifierFlags: .command)
    driver.composer.typeKey(.delete, modifierFlags: [])
    let multiline = String(
      repeating: "A pasted paragraph should keep a comfortable multiline composer.\n",
      count: 24
    )
    driver.paste(multiline)
    XCTAssertTrue(driver.waitForFrameHeight(atLeast: 150, in: driver.composer, timeout: 5))
    XCTAssertEqual(driver.textValue(in: driver.composer), multiline)
    // The panel's frame follows the source over motion-height-ms.
    XCTAssertTrue(
      driver.waitForFrameHeight(atLeast: emptyHeight + 100, in: driver.panel, timeout: 2),
      "The panel grows with the source")

    driver.composer.typeKey("a", modifierFlags: .command)
    driver.composer.typeKey(.delete, modifierFlags: [])
    XCTAssertTrue(driver.waitForFrameHeight(atMost: 30, in: driver.composer, timeout: 5))
    XCTAssertEqual(driver.textValue(in: driver.composer), "")
    XCTAssertTrue(
      driver.waitForFrameHeight(atMost: emptyHeight + 2, in: driver.panel, timeout: 2),
      "The panel shrinks back")
    XCTAssertEqual(driver.panel.frame.height, emptyHeight, accuracy: 2)

    driver.submit("CIDA_E2E_POOL_COMPOSER")
    XCTAssertTrue(
      driver.result(containing: "CIDA_E2E_POOL_COMPOSER_COMPLETE")
        .waitForExistence(timeout: 8)
    )
    driver.waitForCompletion()
    XCTAssertEqual(driver.textValue(in: driver.composer), "CIDA_E2E_POOL_COMPOSER")
    XCTAssertTrue(driver.waitForFrameHeight(atMost: 30, in: driver.composer, timeout: 5))
  }

  func testCommandCCopiesTheSelectionOrTheResult() {
    driver.launch()

    driver.submit("CIDA_E2E_POOL_COPY")
    let completed = driver.result(containing: "CIDA_E2E_POOL_COPY_COMPLETE")
    XCTAssertTrue(completed.waitForExistence(timeout: 8))
    driver.waitForCompletion()
    let resultValue = completed.value as? String ?? ""

    driver.composer.click()
    driver.composer.typeKey("a", modifierFlags: .command)
    driver.composer.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(
      driver.waitForPasteboard("CIDA_E2E_POOL_COPY", timeout: 2),
      "A selection in the source keeps the native copy")

    driver.composer.typeKey(.rightArrow, modifierFlags: [])
    driver.composer.typeKey("c", modifierFlags: .command)
    XCTAssertTrue(
      driver.waitForPasteboard(resultValue, timeout: 2),
      "⌘C without a selection copies the result")
    XCTAssertTrue(
      driver.waitForExistence(of: driver.copiedButton, timeout: 2),
      "✓ 已复制 shows for 800 ms")
    XCTAssertTrue(driver.copyButton.waitForExistence(timeout: 3), "✓ 已复制 reverts")

    NSPasteboard.general.clearContents()
    driver.copyButton.click()
    XCTAssertTrue(driver.waitForPasteboard(resultValue, timeout: 2))
  }

  /// ⇧⌘C and the copy menu put the share card on the pasteboard as an image
  /// and nothing else. ⌄ opens and closes the menu on every click, and a click
  /// elsewhere or Escape closes only the menu (`Design/spec/panel.md` §八).
  func testShiftCommandCCopiesTheSourceAndResultAsAnImage() {
    driver.launch()

    driver.submit("CIDA_E2E_POOL_COPY")
    let completed = driver.result(containing: "CIDA_E2E_POOL_COPY_COMPLETE")
    XCTAssertTrue(completed.waitForExistence(timeout: 8))
    driver.waitForCompletion()
    let resultValue = completed.value as? String ?? ""

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("CIDA_E2E_BEFORE_IMAGE", forType: .string)
    driver.composer.typeKey("c", modifierFlags: [.command, .shift])
    XCTAssertTrue(
      driver.waitForExistence(of: driver.imageCopiedButton, timeout: 2), "✓ 已复制图片 shows")
    let image = pasteboard.data(forType: .png).flatMap(NSBitmapImageRep.init(data:))
    XCTAssertEqual(image?.pixelsWide, 1_500, "The 500 pt card at 3x")
    XCTAssertNil(pasteboard.string(forType: .string), "Only the image")
    XCTAssertTrue(driver.copyButton.waitForExistence(timeout: 3), "✓ 已复制图片 reverts")

    driver.copyMenuButton.click()
    XCTAssertTrue(driver.copyMenuImageItem.waitForExistence(timeout: 2), "⌄ opens the copy menu")
    driver.copyMenuButton.click()
    XCTAssertTrue(driver.copyMenuImageItem.waitForNonExistence(timeout: 2), "⌄ closes it again")

    driver.copyMenuButton.click()
    XCTAssertTrue(driver.copyMenuImageItem.waitForExistence(timeout: 2), "⌄ answers every click")
    driver.composer.click()
    XCTAssertTrue(driver.copyMenuImageItem.waitForNonExistence(timeout: 2), "A click elsewhere closes it")

    driver.copyMenuButton.click()
    XCTAssertTrue(driver.copyMenuImageItem.waitForExistence(timeout: 2))
    driver.composer.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(driver.copyMenuImageItem.waitForNonExistence(timeout: 2), "Escape closes it")
    XCTAssertTrue(driver.panel.exists, "Escape closes only the menu")

    pasteboard.clearContents()
    driver.copyMenuButton.click()
    XCTAssertTrue(driver.copyMenuImageItem.waitForExistence(timeout: 2))
    driver.copyMenuImageItem.click()
    XCTAssertTrue(driver.waitForExistence(of: driver.imageCopiedButton, timeout: 2))
    XCTAssertNotNil(pasteboard.data(forType: .png))
    XCTAssertFalse(driver.copyMenuImageItem.exists, "Choosing closes the menu")

    XCTAssertTrue(driver.copyButton.waitForExistence(timeout: 3))
    pasteboard.clearContents()
    driver.copyMenuButton.click()
    XCTAssertTrue(driver.copyMenuResultItem.waitForExistence(timeout: 2))
    driver.copyMenuResultItem.click()
    XCTAssertTrue(driver.waitForPasteboard(resultValue, timeout: 2), "复制结果 in the menu copies the text")
  }
}

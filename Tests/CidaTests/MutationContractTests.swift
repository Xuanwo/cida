import AppKit
import XCTest

@testable import Cida

/// Kill tests named by `scripts/e2e/mutation-catalog.json`. Each one pins the
/// exact behaviour its mutation breaks.
@MainActor
final class MutationContractTests: XCTestCase {
  func testStreamingRendererUsesInvalidatingLayerPolicy() throws {
    let container = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 320, height: 80)
    )
    container.setResultAccessibilityIdentifier("mutation-streaming-renderer")
    let renderer = try XCTUnwrap(
      container.subviews.first(where: {
        $0.accessibilityIdentifier() == "mutation-streaming-renderer"
      })
    )

    XCTAssertEqual(container.accessibilityRole(), .group)
    XCTAssertEqual(renderer.accessibilityRole(), .textArea)
    XCTAssertTrue(renderer.wantsLayer)
    XCTAssertEqual(renderer.layerContentsRedrawPolicy, .onSetNeedsDisplay)
  }

  func testReplacingTheResultClearsTheRenderedText() {
    let container = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 320, height: 80)
    )
    container.replaceText("OLD_RESULT_MUST_NOT_SURVIVE_REPLACEMENT")
    XCTAssertEqual(container.renderedString, "OLD_RESULT_MUST_NOT_SURVIVE_REPLACEMENT")

    container.replaceText("")

    XCTAssertEqual(container.renderedString, "")
  }

  func testSubmitReplacesTheResultAndKeepsTheSource() async throws {
    let model = AppModel(
      inputText: "Kept source",
      service: DelayedStreamingService(chunks: ["Result"], delay: .milliseconds(10))
    )
    XCTAssertTrue(model.submit())
    let first = try XCTUnwrap(model.result)
    XCTAssertEqual(model.inputText, "Kept source")
    XCTAssertEqual(first.source, "Kept source")
    XCTAssertEqual(model.generationState, .waiting(entryID: first.id))

    try await waitUntil { model.result?.phase == .completed }
    XCTAssertTrue(model.submit())
    XCTAssertFalse(model.result === first)
    XCTAssertEqual(model.inputText, "Kept source")
    model.cancelProcessing()
    try await waitUntil { !model.isProcessing }
  }

  func testEditedSourceMarksTheResultStale() {
    let model = AppModel(inputText: "Original")
    model.setResultForTesting(
      ResultRecord(
        mode: .translate,
        source: "Original",
        outputLanguage: .english,
        result: "Result",
        phase: .completed
      )
    )
    XCTAssertFalse(model.isResultStale)
    XCTAssertNil(model.resultNote)

    model.inputText = "Original edited"
    XCTAssertTrue(model.isResultStale)
    XCTAssertEqual(model.resultNote, .stale)

    model.inputText = "Original"
    model.setMode(.improve)
    XCTAssertTrue(model.isResultStale, "Changing the action also invalidates the result")
  }

  func testEveryPanelAppearanceResetsTheActionToTranslate() {
    let model = AppModel(mode: .improve)
    model.resetModeToDefault()
    XCTAssertEqual(model.mode, .translate)
    model.toggleMode()
    XCTAssertEqual(model.mode, .improve)
    model.resetModeToDefault()
    XCTAssertEqual(model.mode, .translate)
  }

  func testPanelStyleMaskNeverActivatesTheApplication() {
    let panel = CidaPanel(width: 800)
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
  }

  private func waitUntil(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      if clock.now >= deadline {
        XCTFail("Timed out waiting for condition")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

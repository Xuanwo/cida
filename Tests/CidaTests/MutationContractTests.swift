import AppKit
import XCTest

@testable import Cida

@MainActor
final class MutationContractTests: XCTestCase {
  func testStreamingRendererUsesInvalidatingLayerPolicy() throws {
    let container = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 320, height: 80)
    )
    container.setResultAccessibilityIdentifier("mutation-streaming-renderer")
    let renderer = try XCTUnwrap(
      container.subviews.first(where: {
        $0.accessibilityIdentifier() == "mutation-streaming-renderer"
      })
    )

    XCTAssertEqual(renderer.accessibilityRole(), .staticText)
    XCTAssertTrue(renderer.wantsLayer)
    XCTAssertEqual(renderer.layerContentsRedrawPolicy, .onSetNeedsDisplay)
  }

  func testResultContainerPoolClearsRenderedTextBeforeReuse() {
    let pool = HistoryResultTextContainerPool.shared
    let firstLease = pool.acquire()
    firstLease.replaceText("OLD_RESULT_MUST_NOT_SURVIVE_REUSE")
    XCTAssertEqual(firstLease.renderedString, "OLD_RESULT_MUST_NOT_SURVIVE_REUSE")

    pool.release(firstLease)
    let secondLease = pool.acquire()
    defer { pool.release(secondLease) }

    XCTAssertTrue(firstLease === secondLease)
    XCTAssertEqual(secondLease.renderedString, "")
    XCTAssertEqual(secondLease.naturalTextHeight, HistoryResultTextContainer.minimumHeight)
  }

  func testAppendingNewEntryTransfersTheCurrentMarker() {
    let previous = HistoryEntry(
      mode: .translate,
      source: "Previous",
      result: "Previous result",
      detail: "中文 → English",
      timestamp: "18:00"
    )
    let model = AppModel(entries: [previous])
    let current = HistoryEntry(
      mode: .translate,
      source: "Current",
      result: "",
      detail: "中文 → English",
      timestamp: "18:01",
      state: .streaming
    )

    model.entries.append(current)

    XCTAssertFalse(previous.isLatestInHistory)
    XCTAssertTrue(current.isLatestInHistory)
    XCTAssertFalse(model.isHistoryEntryExpanded(previous))
    XCTAssertTrue(model.isHistoryEntryExpanded(current))
  }
}

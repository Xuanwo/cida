import AppKit
import XCTest

@testable import Cida

@MainActor
final class HistoryRendererLifecycleTests: XCTestCase {
  func testDeinitializingExpandedEntryReturnsItsResultContainerLease() {
    let pool = HistoryResultTextContainerPool.shared
    let initialLeaseCount = pool.leasedContainerCountForTesting
    weak var releasedRow: HistoryEntryNSView?
    autoreleasepool {
      let row = HistoryEntryNSView()
      releasedRow = row
      row.configureExpanded(
        entryID: UUID(),
        mode: .translate,
        metadata: "中文 → English · 09:14",
        source: "Source",
        preview: "Result",
        resultStorage: HistoryResultStorage("Result"),
        presentationRevision: 0,
        latestPresentationDelta: nil,
        state: .completed,
        presentation: .manuallyExpanded,
        isLongEntry: false,
        showsSeparator: false,
        onCollapse: {},
        onRedo: {},
        onCopySource: {},
        onCopyResult: {}
      )

      XCTAssertEqual(pool.leasedContainerCountForTesting, initialLeaseCount + 1)
    }
    XCTAssertNil(releasedRow)
    XCTAssertEqual(pool.leasedContainerCountForTesting, initialLeaseCount)
  }
}

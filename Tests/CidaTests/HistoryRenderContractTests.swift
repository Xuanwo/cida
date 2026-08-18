import XCTest

@testable import Cida

final class HistoryRenderContractTests: XCTestCase {
  func testPresentationMatrixHasOneContentAndDisclosureContractPerState() {
    let folded = HistoryRenderContract(presentation: .folded)
    XCTAssertEqual(folded.content, .foldedPreview)
    XCTAssertEqual(folded.disclosureAction, .expand)
    XCTAssertEqual(folded.accessibilityLabelPrefix, "历史记录")
    XCTAssertEqual(folded.accessibilityValue, "collapsed")

    let current = HistoryRenderContract(presentation: .current)
    XCTAssertEqual(current.content, .sourceAndResult)
    XCTAssertEqual(current.disclosureAction, .none)
    XCTAssertEqual(current.accessibilityLabelPrefix, "当前历史记录")
    XCTAssertEqual(current.accessibilityValue, "expanded")

    let manuallyExpanded = HistoryRenderContract(presentation: .manuallyExpanded)
    XCTAssertEqual(manuallyExpanded.content, .sourceAndResult)
    XCTAssertEqual(manuallyExpanded.disclosureAction, .collapse)
    XCTAssertEqual(manuallyExpanded.accessibilityLabelPrefix, "展开的历史记录")
    XCTAssertEqual(manuallyExpanded.accessibilityValue, "expanded")
  }

  func testEveryExpandedPresentationAlwaysShowsSourceAndResult() {
    XCTAssertFalse(HistoryRenderContract(presentation: .folded).showsSourceAndResult)
    XCTAssertTrue(HistoryRenderContract(presentation: .current).showsSourceAndResult)
    XCTAssertTrue(
      HistoryRenderContract(presentation: .manuallyExpanded).showsSourceAndResult
    )
  }
}

import AppKit
import XCTest
@testable import Cida

final class TranslationLayerMotionTests: XCTestCase {
  private let frame = CGRect(x: 24, y: 100, width: 192, height: 24)

  private func image(at rows: [Int], horizontalOffset: Int = 0, altered: Bool = false) -> LayerMotionImage {
    let width = 256, height = 400
    var pixels = [UInt8](repeating: 240, count: width * height)
    // Fixed textured content with a unique fingerprint; duplicate it to model repeated messages.
    for top in rows {
      for y in 0..<24 {
        for x in 0..<192 {
          let value = (x * 31 + y * 73 + x * y * 17) % 197
          pixels[(top + y) * width + 24 + x + horizontalOffset] = UInt8(altered ? 255 - value : value)
        }
      }
    }
    return LayerMotionImage(width: width, height: height, pixels: pixels)
  }

  func testAbsolutePositionSurvivesReversalAndSkippedFramesWithoutDrift() throws {
    let anchor = try XCTUnwrap(LayerImageAnchor(image: image(at: [100]), frame: frame))
    for row in [103, 140, 280, 70, 100] {
      XCTAssertEqual(anchor.displacement(in: image(at: [row])), CGFloat(row - 100))
    }
  }

  func testRepeatedMessagesAreAmbiguousEvenWhenOneIsAtTheOldPosition() throws {
    let anchor = try XCTUnwrap(LayerImageAnchor(image: image(at: [100]), frame: frame))
    XCTAssertNil(anchor.displacement(in: image(at: [100, 152])))
    XCTAssertNil(anchor.displacement(in: image(at: [48, 100])))
  }

  func testDisappearanceReflowAndHorizontalMovementDoNotReuseAnOldOffset() throws {
    let anchor = try XCTUnwrap(LayerImageAnchor(image: image(at: [100]), frame: frame))
    XCTAssertNil(anchor.displacement(in: image(at: [])))
    XCTAssertNil(anchor.displacement(in: image(at: [100], altered: true)))
    XCTAssertNil(anchor.displacement(in: image(at: [100], horizontalOffset: 12)))
    XCTAssertEqual(anchor.displacement(in: image(at: [150])), 50, "Reappearance is independently located")
  }

  func testBlankAndClippedReferencesCannotEstablishAnAnchor() {
    XCTAssertNil(LayerImageAnchor(image: image(at: []), frame: frame))
    XCTAssertNil(LayerImageAnchor(image: image(at: [100]), frame: frame.offsetBy(dx: 0, dy: -110)))
  }

  func testLostIdentityAndFrameGapsRequireANewReference() {
    var reference = LayerMotionReference(image: image(at: [100]), frames: [frame], time: 1)
    reference.update(image: image(at: [120]), time: 1.02, unchanged: false)
    XCTAssertEqual(reference.offsets, [20])
    reference.update(image: image(at: []), time: 1.04, unchanged: false)
    reference.update(image: image(at: [140]), time: 1.06, unchanged: false)
    XCTAssertEqual(reference.offsets, [nil], "A similar paragraph cannot reclaim a lost identity")
    reference = LayerMotionReference(image: image(at: [100]), frames: [frame], time: 2)
    reference.update(image: image(at: [110]), time: 2.2, unchanged: false)
    XCTAssertEqual(reference.offsets, [nil], "Old imagery cannot bridge a long capture gap")
  }

  func testAnExplicitIdleFrameKeepsTheReferenceReadyWithoutRevivingALostParagraph() {
    var reference = LayerMotionReference(image: image(at: [100]), frames: [frame], time: 1)
    reference.confirmUnchanged(at: 3)
    reference.update(image: image(at: [120]), time: 3.02, unchanged: false)
    XCTAssertEqual(reference.offsets, [20])
    reference.update(image: image(at: []), time: 3.04, unchanged: false)
    reference.confirmUnchanged(at: 5)
    reference.update(image: image(at: [130]), time: 5.02, unchanged: false)
    XCTAssertEqual(reference.offsets, [nil])
  }

  func testAmbiguousBaselineCannotAcquireIdentityLaterAndLargeJumpsInvalidateIt() {
    var reference = LayerMotionReference(image: image(at: [100, 152]), frames: [frame], time: 1)
    reference.update(image: image(at: [120]), time: 1.02, unchanged: false)
    XCTAssertEqual(reference.offsets, [nil])
    reference = LayerMotionReference(image: image(at: [100]), frames: [frame], time: 2)
    reference.update(image: image(at: [280]), time: 2.02, unchanged: false)
    XCTAssertEqual(reference.offsets, [nil])
  }

  @MainActor
  func testOnlyUnmatchedParagraphIsHiddenAndResetRestoresOriginalGeometry() {
    let view = LayerOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
    let drawings = [50.0, 120.0].map { y in
      LayerDrawing(frame: CGRect(x: 30, y: y, width: 200, height: 24), text: "Translated text",
                   lineHeight: 24, style: .paper(darkAppearance: false))
    }
    view.show(drawings, scale: 1)
    view.setPending([CGRect(x: 30, y: 190, width: 200, height: 24)])
    view.setMotion([30, nil], pending: [30])
    let content = view.layer!.sublayers![0]
    let paragraphs = Array(content.sublayers!.dropFirst())
    XCTAssertFalse(paragraphs[0].isHidden)
    XCTAssertEqual(paragraphs[0].affineTransform().ty, 30)
    XCTAssertTrue(paragraphs[1].isHidden)
    XCTAssertEqual(content.sublayers![0].sublayers![0].affineTransform().ty, 30)
    XCTAssertTrue(view.layer!.masksToBounds)
    view.setMotion(nil)
    XCTAssertTrue(paragraphs.allSatisfy { !$0.isHidden && $0.affineTransform() == .identity })
  }
}

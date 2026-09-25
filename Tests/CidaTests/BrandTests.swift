import AppKit
import XCTest

@testable import Cida

/// The menu bar mark (`Design/spec/brand.md` §三). The button is never put in the menu bar.
@MainActor
final class BrandTests: XCTestCase {
  func testStatusItemMarkIsABundledTemplateImage() throws {
    let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    _ = try XCTUnwrap(StatusItemMark(button: button))
    let image = try XCTUnwrap(button.image)
    XCTAssertTrue(image.isTemplate)
    XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    XCTAssertGreaterThan(Self.caretAlpha(in: image), 0.95)
  }

  func testTheCaretBreathesLikeTheResultPaneCaret() {
    let minimum = CGFloat(CidaMotion.cursorMinimumOpacity)
    let half = CidaMotion.breatheHalfCycleSeconds
    XCTAssertEqual(StatusItemMark.caretOpacity(after: 0), minimum, accuracy: 0.001)
    XCTAssertEqual(StatusItemMark.caretOpacity(after: half), 1, accuracy: 0.001)
    XCTAssertEqual(StatusItemMark.caretOpacity(after: 2 * half), minimum, accuracy: 0.001)
    XCTAssertEqual(
      StatusItemMark.caretOpacity(after: half / 2), (minimum + 1) / 2, accuracy: 0.001)
    XCTAssertEqual(
      StatusItemMark.caretOpacity(after: half * 0.3),
      StatusItemMark.caretOpacity(after: half * 1.7), accuracy: 0.001)
  }

  func testOnlyTheCaretDimsAndTheButtonSaysARequestIsRunning() throws {
    let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    let mark = try XCTUnwrap(StatusItemMark(button: button))

    let dim = mark.image(caretOpacity: CGFloat(CidaMotion.cursorMinimumOpacity))
    XCTAssertEqual(Self.caretAlpha(in: dim), 0.3, accuracy: 0.05)
    XCTAssertEqual(
      Self.glyphInk(in: dim), Self.glyphInk(in: mark.image(caretOpacity: 1)), accuracy: 0.001)

    mark.isBreathing = true
    XCTAssertEqual(button.accessibilityValue() as? String, "正在生成")
    mark.isBreathing = false
    XCTAssertNil(button.accessibilityValue())
    XCTAssertGreaterThan(Self.caretAlpha(in: try XCTUnwrap(button.image)), 0.95)
  }

  /// Alpha at the middle of the caret, which sits in the rightmost two points of the mark.
  private static func caretAlpha(in image: NSImage) -> CGFloat {
    let bitmap = render(image)
    let scale = CGFloat(bitmap.pixelsWide) / image.size.width
    let caretColumn = Int(16.4 * scale)
    return (0..<bitmap.pixelsHigh).map { bitmap.colorAt(x: caretColumn, y: $0)?.alphaComponent ?? 0 }
      .max() ?? 0
  }

  /// Total alpha left of the caret: the glyph.
  private static func glyphInk(in image: NSImage) -> CGFloat {
    let bitmap = render(image)
    let scale = CGFloat(bitmap.pixelsWide) / image.size.width
    var total: CGFloat = 0
    for x in 0..<Int(15 * scale) {
      for y in 0..<bitmap.pixelsHigh {
        total += bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
      }
    }
    return total
  }

  private static func render(_ image: NSImage) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
  }
}

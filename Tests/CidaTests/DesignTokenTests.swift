import AppKit
import XCTest

@testable import Cida

@MainActor
final class DesignTokenTests: XCTestCase {
  func testSemanticPaletteProducesExactAppKitColorsFromSharedTokens() throws {
    let expectations: [(CidaColorToken, UInt32, CGFloat)] = [
      (CidaDesign.Palette.background, 0xFAFAF8, 1),
      (CidaDesign.Palette.surface, 0xFFFFFF, 1),
      (CidaDesign.Palette.surfaceFold, 0xF1F1EC, 1),
      (CidaDesign.Palette.border, 0xE8E8E3, 1),
      (CidaDesign.Palette.textPrimary, 0x1A1A18, 1),
      (CidaDesign.Palette.textSecondary, 0x8A8A83, 1),
      (CidaDesign.Palette.textTertiary, 0xB5B5AE, 1),
      (CidaDesign.Palette.accent, 0x2E6B4F, 1),
      (CidaDesign.Palette.placeholder, 0xB5B7B0, 0.22),
      (CidaDesign.Palette.placeholderSeparator, 0xE1E1DC, 0.7),
    ]

    for (token, expectedHex, expectedAlpha) in expectations {
      XCTAssertEqual(token.hex, expectedHex)
      XCTAssertEqual(token.alpha, expectedAlpha, accuracy: 0.0001)
      let color = try XCTUnwrap(token.appKit.usingColorSpace(.sRGB))
      XCTAssertEqual(color.redComponent, component(expectedHex, shift: 16), accuracy: 0.0001)
      XCTAssertEqual(color.greenComponent, component(expectedHex, shift: 8), accuracy: 0.0001)
      XCTAssertEqual(color.blueComponent, component(expectedHex, shift: 0), accuracy: 0.0001)
      XCTAssertEqual(color.alphaComponent, expectedAlpha, accuracy: 0.0001)
      _ = token.swiftUI
    }
  }

  func testHistoryMetricsRemainOneSharedContractForEveryRenderer() {
    XCTAssertEqual(HistoryEntryPencilLayout.actionColumnWidth, 24)
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourceLineLimit, 2)
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourcePreviewHeight, 41)
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourceFadeHeight, 20)
    XCTAssertEqual(HistoryEntryPencilLayout.foldedHeight, 96)
    XCTAssertEqual(HistoryEntryPencilLayout.foldedRowStride, 97)
  }

  private func component(_ hex: UInt32, shift: UInt32) -> CGFloat {
    CGFloat((hex >> shift) & 0xff) / 255
  }
}

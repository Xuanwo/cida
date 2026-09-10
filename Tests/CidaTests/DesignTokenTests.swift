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
    XCTAssertEqual(HistoryEntryPencilLayout.windowHorizontalPadding, 28)
    XCTAssertEqual(HistoryEntryPencilLayout.readingWidth, 804)
    XCTAssertEqual(HistoryEntryPencilLayout.hoverBleed, 10)
    XCTAssertEqual(HistoryEntryPencilLayout.hoverCornerRadius, 8)
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourceLineLimit, 2)
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourcePreviewHeight, 41)
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourceFadeHeight, 20)
    XCTAssertEqual(HistoryEntryPencilLayout.resultLineHeight, 26)
    XCTAssertEqual(HistoryEntryPencilLayout.foldedPreviewHeight, 52)
    XCTAssertEqual(HistoryEntryPencilLayout.foldedPreviewFadeHeight, 25)
    XCTAssertEqual(HistoryEntryPencilLayout.separatorHeight, 1)
    // Pencil `Entry`: 16 + 16 + 8 + n × 26 + 16 for one or two visible lines.
    XCTAssertEqual(HistoryEntryPencilLayout.historyRowHeight(previewLineCount: 1), 82)
    XCTAssertEqual(HistoryEntryPencilLayout.historyRowHeight(previewLineCount: 2), 108)
    XCTAssertEqual(HistoryEntryPencilLayout.historyRowHeight(previewLineCount: 7), 108)
    XCTAssertEqual(HistoryEntryPencilLayout.foldedHeight, 108)
    XCTAssertEqual(HistoryEntryPencilLayout.placeholderRowStride, 109)
    XCTAssertEqual(HistoryEntryPencilLayout.previewHeight(forRowHeight: 82), 26)
    XCTAssertEqual(HistoryEntryPencilLayout.previewHeight(forRowHeight: 108), 52)
    XCTAssertEqual(HistoryEntryPencilLayout.previewHeight(forRowHeight: 300), 52)
  }

  func testHistoryRowHeightFollowsThePreviewWithoutLayingItOut() {
    let oneLine = HistoryResultStorage("No such guarantee.")
    let wrapped = HistoryResultStorage(
      String(repeating: "Having used GPT-6-Astra for a while now, ", count: 4)
    )
    let lineBreak = HistoryResultStorage("First line\nSecond line")

    XCTAssertEqual(HistoryResultTextStyle.historyRowHeight(for: oneLine, textWidth: 780), 82)
    XCTAssertEqual(HistoryResultTextStyle.historyRowHeight(for: wrapped, textWidth: 780), 108)
    XCTAssertEqual(HistoryResultTextStyle.historyRowHeight(for: lineBreak, textWidth: 780), 108)
    // A narrow column wraps the one-liner too.
    XCTAssertEqual(HistoryResultTextStyle.historyRowHeight(for: oneLine, textWidth: 60), 108)

    let cached = HistoryResultStorage("Cached preview width.")
    var measurements = 0
    for _ in 0..<5 {
      _ = cached.previewSingleLineWidth { text in
        measurements += 1
        return HistoryResultTextStyle.singleLineWidth(of: text)
      }
    }
    XCTAssertEqual(measurements, 1, "The single-line width is cached until the preview changes")
    cached.append(" Really.")
    _ = cached.previewSingleLineWidth { text in
      measurements += 1
      return HistoryResultTextStyle.singleLineWidth(of: text)
    }
    XCTAssertEqual(measurements, 2)
  }

  func testMotionTokensMatchThePencilVariables() {
    XCTAssertEqual(CidaMotion.characterInMilliseconds, 120)
    XCTAssertEqual(CidaMotion.iconInMilliseconds, 120)
    XCTAssertEqual(CidaMotion.iconSwapMilliseconds, 150)
    XCTAssertEqual(CidaMotion.heightMilliseconds, 150)
    XCTAssertEqual(CidaMotion.cursorOutMilliseconds, 200)
    XCTAssertEqual(CidaMotion.historyFoldMilliseconds, 200)
    XCTAssertEqual(CidaMotion.copiedHoldMilliseconds, 800)
    XCTAssertEqual(CidaMotion.breatheMilliseconds, 1_200)
    XCTAssertEqual(CidaMotion.characterBlurRadius, 2)
    XCTAssertEqual(CidaMotion.cursorWidth, 2)
    XCTAssertEqual(CidaMotion.cursorHeight, 20)
    XCTAssertEqual(CidaMotion.resolvedDuration(0.2, in: nil), 0)
  }

  private func component(_ hex: UInt32, shift: UInt32) -> CGFloat {
    CGFloat((hex >> shift) & 0xff) / 255
  }
}

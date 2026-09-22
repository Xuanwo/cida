import AppKit
import XCTest

@testable import Cida

@MainActor
final class DesignTokenTests: XCTestCase {
  func testSemanticPaletteProducesExactAppKitColorsFromSharedTokens() throws {
    let expectations: [(CidaColorToken, UInt32, CGFloat)] = [
      (CidaDesign.Palette.background, 0xFAFAF8, 1),
      (CidaDesign.Palette.surface, 0xFFFFFF, 1),
      (CidaDesign.Palette.surfacePaper, 0xF7F6F1, 1),
      (CidaDesign.Palette.border, 0xE8E8E3, 1),
      (CidaDesign.Palette.textPrimary, 0x1A1A18, 1),
      (CidaDesign.Palette.textSecondary, 0x8A8A83, 1),
      (CidaDesign.Palette.textTertiary, 0xB5B5AE, 1),
      (CidaDesign.Palette.textInk, 0x161614, 1),
      (CidaDesign.Palette.textControl, 0x4E4E49, 1),
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

  /// Pencil `Spec — 面板模型`: the panel's fixed width and screen ratios, the
  /// pane insets, and the result typography.
  func testPanelAndResultTokensMatchThePencilVariables() {
    XCTAssertEqual(CidaDesign.Panel.width, 800)
    XCTAssertEqual(CidaDesign.Panel.topRatio, 0.2)
    XCTAssertEqual(CidaDesign.Panel.sourceMaxRatio, 0.3)
    XCTAssertEqual(CidaDesign.Panel.maxRatio, 0.7)
    XCTAssertEqual(CidaDesign.Panel.controlBarHeight, 50)
    XCTAssertEqual(CidaDesign.Radius.panel, 14)
    XCTAssertEqual(CidaDesign.Spacing.windowHorizontal, 28)
    XCTAssertEqual(CidaDesign.Spacing.paneVertical, 18)
    XCTAssertEqual(CidaDesign.Spacing.resultVertical, 22)
    XCTAssertEqual(CidaDesign.Typography.resultSize, 17.5)
    XCTAssertEqual(CidaDesign.Typography.resultSizeCJK, 17)
    XCTAssertEqual(CidaDesign.Typography.resultLineHeight, 29)
    XCTAssertEqual(CidaDesign.Typography.resultLineHeightCJK, 31)

    let budget = PanelHeightBudget(visibleScreenHeight: 1_000)
    XCTAssertEqual(budget.panelMaxHeight, 700)
    XCTAssertEqual(budget.sourceEditorMaxHeight, 300 - 36)
  }

  func testResultTypographyUsesTheBundledSerifFacesPerLanguage() {
    FontRegistrar.registerBundledFonts()
    let latin = CidaDesign.appKitResult(for: .english)
    let cjk = CidaDesign.appKitResult(for: .chinese)

    XCTAssertEqual(latin.familyName, "Source Serif 4")
    XCTAssertEqual(latin.pointSize, 17.5)
    XCTAssertEqual(cjk.familyName, "Noto Serif SC")
    XCTAssertEqual(cjk.pointSize, 17)
    XCTAssertEqual(ResultTextStyle.lineHeight(for: .english), 29)
    XCTAssertEqual(ResultTextStyle.lineHeight(for: .chinese), 31)
  }

  func testMotionTokensMatchThePencilVariables() {
    XCTAssertEqual(CidaMotion.characterInMilliseconds, 120)
    XCTAssertEqual(CidaMotion.iconInMilliseconds, 120)
    XCTAssertEqual(CidaMotion.iconSwapMilliseconds, 150)
    XCTAssertEqual(CidaMotion.heightMilliseconds, 150)
    XCTAssertEqual(CidaMotion.cursorOutMilliseconds, 200)
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

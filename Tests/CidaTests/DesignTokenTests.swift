import AppKit
import XCTest

@testable import Cida

@MainActor
final class DesignTokenTests: XCTestCase {
  /// `Design/boards/tokens.css` is the design's token file; every value the
  /// implementation mirrors must match it.
  func testSwiftTokensMatchTheDesignTokenFile() throws {
    let tokens = try Self.designTokens()
    let darkTokens = try Self.designTokens(in: .dark)
    let colors: [(String, CidaColorToken)] = [
      ("bg", CidaDesign.Palette.background), ("surface", CidaDesign.Palette.surface),
      ("surface-dim", CidaDesign.Palette.surfaceDim),
      ("surface-paper", CidaDesign.Palette.surfacePaper), ("border", CidaDesign.Palette.border),
      ("text-primary", CidaDesign.Palette.textPrimary),
      ("text-secondary", CidaDesign.Palette.textSecondary),
      ("text-tertiary", CidaDesign.Palette.textTertiary), ("text-ink", CidaDesign.Palette.textInk),
      ("text-control", CidaDesign.Palette.textControl), ("hint", CidaDesign.Palette.hint),
      ("accent", CidaDesign.Palette.accent), ("accent-soft", CidaDesign.Palette.accentSoft),
      ("accent-foreground", CidaDesign.Palette.accentForeground),
      ("toggle-off", CidaDesign.Palette.toggleOff),
    ]
    for (name, token) in colors {
      XCTAssertEqual(try XCTUnwrap(darkTokens[name], "dark \(name)"), String(format: "#%06X", token.darkHex), "dark \(name)")
    }
    XCTAssertEqual(
      Set(darkTokens.keys), Set(colors.map(\.0) + ["panel-edge", "panel-shadow"]),
      "the dark appearance redefines exactly the colors")

    // The panel's edge and its two shadow layers, as #RRGGBBAA.
    for (appearance, values) in [(false, tokens), (true, darkTokens)] {
      XCTAssertEqual(values["panel-edge"], Self.cssColor(CidaDesign.Palette.panelEdge, dark: appearance))
      XCTAssertEqual(
        values["panel-shadow"],
        "0 2px 6px \(Self.cssColor(CidaDesign.Palette.contactShadow, dark: appearance)), "
          + "0 28px 72px \(Self.cssColor(CidaDesign.Palette.ambientShadow, dark: appearance))")
    }

    for (name, token) in colors {
      let value = try XCTUnwrap(tokens[name], name)
      XCTAssertEqual(value, String(format: "#%06X", token.hex), name)
    }

    let numbers: [(String, Double)] = [
      ("panel-width", CidaDesign.Panel.width), ("panel-top-ratio", CidaDesign.Panel.topRatio),
      ("source-max-ratio", CidaDesign.Panel.sourceMaxRatio),
      ("panel-max-ratio", CidaDesign.Panel.maxRatio),
      ("control-bar-height", CidaDesign.Panel.controlBarHeight),
      ("share-card-width", CidaDesign.ShareCard.width),
      ("share-card-margin", CidaDesign.ShareCard.margin),
      ("radius-window", CidaDesign.Radius.window), ("radius-panel", CidaDesign.Radius.panel),
      ("radius-card", CidaDesign.Radius.card), ("radius-seg", CidaDesign.Radius.segment),
      ("radius-chip", CidaDesign.Radius.chip), ("radius-seg-item", CidaDesign.Radius.segmentItem),
      ("space-window-x", CidaDesign.Spacing.windowHorizontal),
      ("space-entry-y", CidaDesign.Spacing.entryVertical),
      ("space-pane-y", CidaDesign.Spacing.paneVertical),
      ("space-result-y", CidaDesign.Spacing.resultVertical),
      ("result-fade", CidaDesign.ResultFade.length),
      ("result-fade-floor", CidaDesign.ResultFade.inkFloor),
      ("font-size-body", CidaDesign.Typography.bodySize),
      ("font-size-result", CidaDesign.Typography.resultSize),
      ("font-size-result-cjk", CidaDesign.Typography.resultSizeCJK),
      ("motion-char-in-ms", Double(CidaMotion.characterInMilliseconds)),
      ("motion-icon-in-ms", Double(CidaMotion.iconInMilliseconds)),
      ("motion-icon-swap-ms", Double(CidaMotion.iconSwapMilliseconds)),
      ("motion-height-ms", Double(CidaMotion.heightMilliseconds)),
      ("motion-cursor-out-ms", Double(CidaMotion.cursorOutMilliseconds)),
      ("motion-copied-hold-ms", Double(CidaMotion.copiedHoldMilliseconds)),
      ("motion-breathe-ms", Double(CidaMotion.breatheMilliseconds)),
      ("motion-catchup-ms", Double(CidaMotion.catchUpMilliseconds)),
      ("motion-rate-min-cps", CidaMotion.minimumCharactersPerSecond),
      ("motion-rate-max-cps", CidaMotion.maximumCharactersPerSecond),
      ("motion-rate-alpha", CidaMotion.smoothingAlphaPer120HzFrame),
      ("motion-blur-char-px", CidaMotion.characterBlurRadius),
      ("motion-cursor-opacity-min", Double(CidaMotion.cursorMinimumOpacity)),
      ("motion-waiting-opacity-max", Double(CidaMotion.waitingMaximumOpacity)),
      ("motion-waiting-opacity-min", Double(CidaMotion.waitingMinimumOpacity)),
      ("motion-cursor-w", CidaMotion.cursorWidth),
      ("motion-cursor-h", CidaMotion.cursorHeight),
    ]
    for (name, expected) in numbers {
      let raw = try XCTUnwrap(tokens[name], name).replacingOccurrences(of: "px", with: "")
      let value = try XCTUnwrap(Double(raw), "\(name) = \(raw)")
      XCTAssertEqual(value, expected, accuracy: 0.0001, name)
    }

    let curves: [(String, CidaMotion.Curve)] = [
      ("motion-ease-char-in", CidaMotion.characterInCurve),
      ("motion-ease-height", CidaMotion.heightCurve),
      ("motion-ease-cursor-out", CidaMotion.cursorOutCurve),
      ("motion-ease-breathe", CidaMotion.breatheCurve),
    ]
    for (name, curve) in curves {
      XCTAssertEqual(try XCTUnwrap(tokens[name], name), curve.rawValue, name)
    }
  }

  /// The app icon's light appearance is ink on paper with the accent caret (spec/brand.md);
  /// its colours are written by hand in icon.json and by the generator in the layers.
  func testAppIconColorsMatchTheDesignTokens() throws {
    let tokens = try Self.designTokens()
    let iconURL = Self.projectRoot.appendingPathComponent("Resources/AppIcon.icon")
    let json = try String(
      contentsOf: iconURL.appendingPathComponent("icon.json"), encoding: .utf8)
    let lightFill = try XCTUnwrap(
      json.range(of: #""solid" : "srgb:[0-9.,]+""#, options: .regularExpression))
    XCTAssertEqual(
      Self.hex(fromIconSolid: String(json[lightFill])), try XCTUnwrap(tokens["surface-paper"]))

    for (layer, token) in [("glyph", "text-ink"), ("caret", "accent")] {
      let svg = try String(
        contentsOf: iconURL.appendingPathComponent("Assets/\(layer).svg"), encoding: .utf8)
      XCTAssertTrue(svg.contains("fill=\"\(try XCTUnwrap(tokens[token]))\""), layer)
    }
  }

  private static let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// `"solid" : "srgb:r,g,b,a"` with components in 0...1, as `#RRGGBB`.
  private static func hex(fromIconSolid declaration: String) -> String {
    let components = declaration.split(separator: ":").last!.split(separator: ",").prefix(3)
    return "#" + components.map { String(format: "%02X", Int((Double($0)! * 255).rounded())) }
      .joined()
  }

  private enum TokenScope {
    case light, dark
  }

  /// `--name: value;` declarations of the design token file: `:root` for the light
  /// appearance, `[data-appearance="dark"]` for the dark one.
  private static func designTokens(in scope: TokenScope = .light) throws -> [String: String] {
    let url = projectRoot.appendingPathComponent("Design/boards/tokens.css")
    let css = try String(contentsOf: url, encoding: .utf8)
    var tokens: [String: String] = [:]
    var current: TokenScope?
    for line in css.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix(":root") { current = .light }
      if trimmed.hasPrefix("[data-appearance=\"dark\"]") { current = .dark }
      if trimmed == "}" { current = nil }
      guard current == scope, trimmed.hasPrefix("--"), let colon = trimmed.firstIndex(of: ":") else {
        continue
      }
      let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<colon])
      let value = trimmed[trimmed.index(after: colon)...]
        .trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
      tokens[name] = value
    }
    return tokens
  }

  private static func cssColor(_ token: CidaColorToken, dark: Bool) -> String {
    let (hex, alpha) = dark ? (token.darkHex, token.darkAlpha) : (token.hex, token.alpha)
    return String(format: "#%06X%02X", hex, Int((alpha * 255).rounded()))
  }

  func testSemanticPaletteProducesExactAppKitColorsFromSharedTokens() throws {
    let expectations: [(CidaColorToken, UInt32, UInt32)] = [
      (CidaDesign.Palette.background, 0xFAFAF8, 0x1E1E1C),
      (CidaDesign.Palette.surface, 0xFFFFFF, 0x262624),
      (CidaDesign.Palette.surfacePaper, 0xF7F6F1, 0x1B1A17),
      (CidaDesign.Palette.border, 0xE8E8E3, 0x383835),
      (CidaDesign.Palette.textPrimary, 0x1A1A18, 0xEDEDE9),
      (CidaDesign.Palette.textSecondary, 0x8A8A83, 0x8A8A83),
      (CidaDesign.Palette.textTertiary, 0xB5B5AE, 0x5E5E58),
      (CidaDesign.Palette.textInk, 0x161614, 0xE9E6DD),
      (CidaDesign.Palette.textControl, 0x4E4E49, 0xC2C2BA),
      (CidaDesign.Palette.accent, 0x2E6B4F, 0x5E9C7C),
    ]

    for (token, light, dark) in expectations {
      for (appearanceName, expectedHex) in [(NSAppearance.Name.aqua, light), (.darkAqua, dark)] {
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        var resolved: NSColor?
        // The dynamic color resolves to the appearance it is drawn in.
        appearance.performAsCurrentDrawingAppearance {
          resolved = token.appKit.usingColorSpace(.sRGB)
        }
        let color = try XCTUnwrap(resolved)
        XCTAssertEqual(color.redComponent, component(expectedHex, shift: 16), accuracy: 0.0001)
        XCTAssertEqual(color.greenComponent, component(expectedHex, shift: 8), accuracy: 0.0001)
        XCTAssertEqual(color.blueComponent, component(expectedHex, shift: 0), accuracy: 0.0001)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.0001)
        XCTAssertEqual(
          token.cgColor(in: appearance).components?.first ?? -1, component(expectedHex, shift: 16),
          accuracy: 0.0001)
      }
      _ = token.swiftUI
    }
  }

  /// `Design/spec/panel.md`: the panel's fixed width and screen ratios, the
  /// pane insets, and the result typography.
  func testPanelAndResultTokensMatchTheDesignTokens() {
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

  func testMotionTokensMatchTheDesignTokens() {
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

import AppKit
import CoreText
import QuartzCore
import SwiftUI

struct CidaColorToken: Sendable {
  let hex: UInt32
  let alpha: CGFloat

  init(_ hex: UInt32, alpha: CGFloat = 1) {
    self.hex = hex
    self.alpha = alpha
  }

  var swiftUI: Color {
    Color(hex: hex, alpha: Double(alpha))
  }

  var appKit: NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
      green: CGFloat((hex >> 8) & 0xff) / 255,
      blue: CGFloat(hex & 0xff) / 255,
      alpha: alpha
    )
  }
}

enum CidaDesign {
  enum Palette {
    static let background = CidaColorToken(0xFAFAF8)
    static let surface = CidaColorToken(0xFFFFFF)
    static let surfaceDim = CidaColorToken(0xF4F4F1)
    static let surfacePaper = CidaColorToken(0xF7F6F1)
    static let border = CidaColorToken(0xE8E8E3)
    static let textPrimary = CidaColorToken(0x1A1A18)
    static let textSecondary = CidaColorToken(0x8A8A83)
    static let textTertiary = CidaColorToken(0xB5B5AE)
    static let textInk = CidaColorToken(0x161614)
    static let textControl = CidaColorToken(0x4E4E49)
    static let hint = CidaColorToken(0xC4C4BD)
    static let accent = CidaColorToken(0x2E6B4F)
    static let accentSoft = CidaColorToken(0xEAF2EE)
    static let accentForeground = CidaColorToken(0xFFFFFF)
    static let toggleOff = CidaColorToken(0xDBDBD5)
    static let placeholder = CidaColorToken(0xB5B7B0, alpha: 0.22)
  }

  static let background = Palette.background.swiftUI
  static let surface = Palette.surface.swiftUI
  static let surfaceDim = Palette.surfaceDim.swiftUI
  static let surfacePaper = Palette.surfacePaper.swiftUI
  static let border = Palette.border.swiftUI
  static let textPrimary = Palette.textPrimary.swiftUI
  static let textSecondary = Palette.textSecondary.swiftUI
  static let textTertiary = Palette.textTertiary.swiftUI
  static let textInk = Palette.textInk.swiftUI
  static let textControl = Palette.textControl.swiftUI
  static let hint = Palette.hint.swiftUI
  static let accent = Palette.accent.swiftUI
  static let accentSoft = Palette.accentSoft.swiftUI
  static let accentForeground = Palette.accentForeground.swiftUI
  static let toggleOff = Palette.toggleOff.swiftUI

  enum Radius {
    static let window: CGFloat = 14
    static let panel: CGFloat = 14
    static let card: CGFloat = 8
    static let segment: CGFloat = 7
    static let chip: CGFloat = 6
    static let segmentItem: CGFloat = 5
  }

  enum Spacing {
    static let windowHorizontal: CGFloat = 28
    static let entryVertical: CGFloat = 16
    static let paneVertical: CGFloat = 18
    static let resultVertical: CGFloat = 22
    static let component: CGFloat = 12
  }

  /// `Design/spec/panel.md`: the floating panel's fixed width and the
  /// screen-relative limits of its height.
  enum Panel {
    static let width: CGFloat = 800
    static let topRatio: CGFloat = 0.2
    static let sourceMaxRatio: CGFloat = 0.3
    static let maxRatio: CGFloat = 0.7
    static let controlBarHeight: CGFloat = 50
    static let compactEditorHeight: CGFloat = 27
    static let composerLineHeight: CGFloat = 26
  }

  /// The design's result typography (`font-size-result*` × `line-height-result*`,
  /// rounded to whole points).
  enum Typography {
    static let bodySize: CGFloat = 16
    static let bodyLineHeight: CGFloat = 26
    static let resultSize: CGFloat = 17.5
    static let resultSizeCJK: CGFloat = 17
    static let resultLineHeight: CGFloat = 29
    static let resultLineHeightCJK: CGFloat = 31
  }

  static let windowRadius = Radius.window

  static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom(interName(for: weight), fixedSize: size)
  }

  static func mainUI(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom(interName(for: weight), fixedSize: size)
  }

  static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom(interName(for: weight), fixedSize: size)
  }

  static func appKitBody(_ size: CGFloat) -> NSFont {
    NSFont(name: "Inter-Regular", size: size)
      ?? NSFont.systemFont(ofSize: size, weight: .regular)
  }

  static func brand(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom(notoSerifSCName(for: weight), fixedSize: size)
  }

  /// The result face: Source Serif 4 for Latin results, Noto Serif SC for
  /// Chinese ones, each cascading to the other for mixed text. Wherever Noto
  /// Serif SC sets Chinese, its punctuation follows `cjkPunctuationFeatures`.
  static func appKitResult(for language: Language) -> NSFont {
    let size = language == .chinese ? Typography.resultSizeCJK : Typography.resultSize
    let latin = NSFontDescriptor(fontAttributes: [.family: "Source Serif 4"])
    let cjk = NSFontDescriptor(fontAttributes: [
      .family: "Noto Serif SC",
      .featureSettings: cjkPunctuationFeatures,
    ])
    let (primary, secondary) = language == .chinese ? (cjk, latin) : (latin, cjk)
    let descriptor = primary.addingAttributes([.cascadeList: [secondary]])
    let primaryFamily = language == .chinese ? "Noto Serif SC" : "Source Serif 4"
    if let font = NSFont(descriptor: descriptor, size: size),
      font.familyName == primaryFamily
    {
      return font
    }
    let fallback = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body)
      .withDesign(.serif) ?? NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body)
    return NSFont(descriptor: fallback, size: size) ?? NSFont.systemFont(ofSize: size)
  }

  /// Contextual half-width spacing (`chws`) for the Chinese result face: a
  /// full-width punctuation mark next to another one or at the edge of a line
  /// takes half its width, as typeset Chinese does, and keeps its full width
  /// elsewhere. The result pane and the panel's paper text share the face, so
  /// both set punctuation this way.
  static var cjkPunctuationFeatures: [[NSFontDescriptor.FeatureKey: Any]] {
    [
      [
        NSFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureTag as String): "chws",
        NSFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureValue as String): 1,
      ]
    ]
  }

  /// CSS centres a line's glyphs in its line box: half of the extra leading
  /// goes above them and half below. TextKit's fixed line height (minimum =
  /// maximum) puts all of it above, which sets native text lower than the board
  /// and than SwiftUI text on the same surface. Raising the glyphs by this much
  /// puts them where CSS has them.
  static func halfLeading(of font: NSFont, lineHeight: CGFloat) -> CGFloat {
    (lineHeight - (font.ascender - font.descender)) / 2
  }

  static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom("JetBrains Mono", fixedSize: size).weight(weight)
  }

  private static func notoSerifSCName(for weight: Font.Weight) -> String {
    if weight == .semibold { return "NotoSerifSC-SemiBold" }
    if weight == .medium { return "NotoSerifSC-Medium" }
    if weight == .bold { return "NotoSerifSC-Bold" }
    return "NotoSerifSC-Regular"
  }

  private static func interName(for weight: Font.Weight) -> String {
    if weight == .semibold { return "Inter-SemiBold" }
    if weight == .medium { return "Inter-Medium" }
    if weight == .bold { return "Inter-Bold" }
    return "Inter-Regular"
  }
}

enum CidaMotion {
  static let characterInMilliseconds = 120
  static let iconInMilliseconds = 120
  static let iconSwapMilliseconds = 150
  static let heightMilliseconds = 150
  static let cursorOutMilliseconds = 200
  static let copiedHoldMilliseconds = 800
  static let breatheMilliseconds = 1_200
  static let catchUpMilliseconds = 400

  static let characterInSeconds: CFTimeInterval = 0.120
  static let iconInSeconds: Double = 0.120
  static let iconSwapSeconds: Double = 0.150
  static let heightSeconds: Double = 0.150
  static let cursorOutSeconds: CFTimeInterval = 0.200
  static let breatheHalfCycleSeconds: CFTimeInterval = 0.600

  static let minimumCharactersPerSecond = 30.0
  static let maximumCharactersPerSecond = 400.0
  static let smoothingAlphaPer120HzFrame = 0.15
  static let characterBlurRadius: CGFloat = 2
  static let cursorMinimumOpacity: Float = 0.3
  static let cursorWidth: CGFloat = 2
  static let cursorHeight: CGFloat = 20

  /// The design's named curves, as the `motion-ease-*` tokens write them. Core
  /// Animation and SwiftUI read the same control points, so a frame that
  /// SwiftUI animates and the content that AppKit animates inside it stay in
  /// step. The design's ease-out is (0.33, 1, 0.68, 1).
  enum Curve: String, Sendable {
    case easeOut = "ease-out"
    case easeInOut = "ease-in-out"

    var controlPoints: (x1: Float, y1: Float, x2: Float, y2: Float) {
      switch self {
      case .easeOut: (0.33, 1, 0.68, 1)
      case .easeInOut: (0.42, 0, 0.58, 1)
      }
    }

    var timingFunction: CAMediaTimingFunction {
      let points = controlPoints
      return CAMediaTimingFunction(controlPoints: points.x1, points.y1, points.x2, points.y2)
    }

    func animation(duration: TimeInterval) -> Animation {
      let points = controlPoints
      return .timingCurve(
        Double(points.x1), Double(points.y1), Double(points.x2), Double(points.y2),
        duration: duration
      )
    }

    /// The curve's progress at `time` (0...1), for motion driven frame by frame.
    func progress(at time: Double) -> Double {
      let points = controlPoints
      let (x1, y1, x2, y2) = (Double(points.x1), Double(points.y1), Double(points.x2), Double(points.y2))
      let t = min(1, max(0, time))
      func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
      }
      var low = 0.0
      var high = 1.0
      for _ in 0..<32 {
        let middle = (low + high) / 2
        if bezier(middle, x1, x2) < t { low = middle } else { high = middle }
      }
      return bezier((low + high) / 2, y1, y2)
    }
  }

  /// `motion-ease-char-in`
  static let characterInCurve = Curve.easeOut
  /// `motion-ease-height`
  static let heightCurve = Curve.easeOut
  /// `motion-ease-cursor-out`: the caret fading out when a stream ends, and
  /// easing back to full opacity when it stops breathing.
  static let cursorOutCurve = Curve.easeOut
  /// `motion-ease-breathe`
  static let breatheCurve = Curve.easeInOut

  static var easeOut: CAMediaTimingFunction {
    Curve.easeOut.timingFunction
  }

  /// Tests that assert on motion pin this, so the host's Reduce Motion setting (on by default
  /// on CI runners) does not decide what they see.
  @MainActor static var reducesMotionOverride: Bool?

  /// Whether to drop motion: the system's Reduce Motion setting unless a test pinned it.
  @MainActor
  static var reducesMotion: Bool {
    reducesMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// Motion is dropped when the system reduces motion or the view is not in a
  /// window; static durations keep the same end state.
  @MainActor
  static func resolvedDuration(_ seconds: TimeInterval, in window: NSWindow?) -> TimeInterval {
    guard window != nil, !reducesMotion else {
      return 0
    }
    return seconds
  }
}

extension Color {
  init(hex: UInt32, alpha: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255,
      opacity: alpha
    )
  }
}

enum FontRegistrar {
  private static let fontFiles = [
    "Inter[opsz,wght]",
    "JetBrainsMono[wght]",
    "SourceSerif4[opsz,wght]",
    "NotoSerifSC[wght]",
  ]

  static func registerBundledFonts() {
    for name in fontFiles {
      guard
        let url = CidaResourceBundle.bundle.url(
          forResource: name,
          withExtension: "ttf"
        )
      else {
        continue
      }

      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
  }
}

struct WindowSurface<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(CidaDesign.background)
      .ignoresSafeArea(.container, edges: .top)
  }
}

struct Hairline: View {
  var body: some View {
    CidaDesign.border.frame(height: 1)
  }
}

struct HoverFadeButtonStyle: ButtonStyle {
  @State private var isHovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.55 : isHovering ? 0.78 : 1)
      .contentShape(Rectangle())
      .onHover { isHovering = $0 }
  }
}

import AppKit
import CoreText
import SwiftUI

enum CidaDesign {
  static let background = Color(hex: 0xFAFAF8)
  static let surface = Color.white
  static let surfaceDim = Color(hex: 0xF4F4F1)
  static let surfaceFold = Color(hex: 0xF1F1EC)
  static let border = Color(hex: 0xE8E8E3)
  static let textPrimary = Color(hex: 0x1A1A18)
  static let textSecondary = Color(hex: 0x8A8A83)
  static let textTertiary = Color(hex: 0xB5B5AE)
  static let accent = Color(hex: 0x2E6B4F)
  static let accentSoft = Color(hex: 0xEAF2EE)
  static let accentForeground = Color.white
  static let toggleOff = Color(hex: 0xDBDBD5)

  enum Radius {
    static let window: CGFloat = 14
    static let card: CGFloat = 8
    static let segment: CGFloat = 7
    static let chip: CGFloat = 6
    static let segmentItem: CGFloat = 5
  }

  enum Spacing {
    static let windowHorizontal: CGFloat = 28
    static let entryVertical: CGFloat = 16
    static let component: CGFloat = 12
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
  static let historyFoldMilliseconds = 200
  static let copiedHoldMilliseconds = 800
  static let breatheMilliseconds = 1_200
  static let catchUpMilliseconds = 400

  static let characterInSeconds: CFTimeInterval = 0.120
  static let iconInSeconds: Double = 0.120
  static let iconSwapSeconds: Double = 0.150
  static let heightSeconds: Double = 0.150
  static let cursorOutSeconds: CFTimeInterval = 0.200
  static let historyFoldSeconds: Double = 0.200
  static let breatheHalfCycleSeconds: CFTimeInterval = 0.600

  static let minimumCharactersPerSecond = 30.0
  static let maximumCharactersPerSecond = 400.0
  static let smoothingAlphaPer120HzFrame = 0.15
  static let characterBlurRadius: CGFloat = 2
  static let cursorMinimumOpacity: Float = 0.3
  static let cursorWidth: CGFloat = 2
  static let cursorHeight: CGFloat = 20
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

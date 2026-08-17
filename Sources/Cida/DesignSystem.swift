import AppKit
import CoreText
import SwiftUI

enum CidaDesign {
  static let background = Color(hex: 0xFAFAF8)
  static let surface = Color.white
  static let surfaceDim = Color(hex: 0xF4F4F1)
  static let border = Color(hex: 0xE8E8E3)
  static let textPrimary = Color(hex: 0x1A1A18)
  static let textSecondary = Color(hex: 0x8A8A83)
  static let textTertiary = Color(hex: 0xB5B5AE)
  static let accent = Color(hex: 0x2E6B4F)
  static let accentSoft = Color(hex: 0xEAF2EE)
  static let toggleOff = Color(hex: 0xDBDBD5)
  static let windowRadius: CGFloat = 14

  static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
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
    let packagedBundleURL = Bundle.main.resourceURL?
      .appendingPathComponent("Cida_Cida.bundle", isDirectory: true)
    let resourceBundle =
      packagedBundleURL
      .flatMap(Bundle.init(url:))
      ?? Bundle.module

    for name in fontFiles {
      guard
        let url = resourceBundle.url(
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

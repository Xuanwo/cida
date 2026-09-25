import AppKit
import SwiftUI

/// The brand mark in the menu bar: 辞 followed by the streaming caret (Design/spec/brand.md §三).
/// While a request keeps running behind a hidden panel, the caret breathes like the result pane's
/// waiting caret, so the menu bar shows that the result is still arriving.
@MainActor
final class StatusItemMark {
  private static let size = NSSize(width: 18, height: 18)
  /// Caret opacities are rounded to this many steps between the minimum and 1, so a breath
  /// reuses a handful of images instead of drawing one per tick.
  private static let opacitySteps = 14
  private static let ticksPerSecond: TimeInterval = 30

  private let button: NSStatusBarButton
  private let glyph: NSImage
  private let caret: NSImage
  private var images: [Int: NSImage] = [:]
  private var timer: Timer?

  /// Nil when the bundled mark is missing; the caller then shows 辞 as text.
  init?(button: NSStatusBarButton) {
    guard let glyph = Self.layer("status-item-glyph"), let caret = Self.layer("status-item-caret")
    else { return nil }
    self.button = button
    self.glyph = glyph
    self.caret = caret
    button.image = image(caretOpacity: 1)
    button.setAccessibilityLabel("辞达")
  }

  /// Whether a request is running while the panel is hidden. The accessibility value says so
  /// too; with Reduce Motion the caret stays dim instead of breathing.
  var isBreathing = false {
    didSet {
      guard isBreathing != oldValue else { return }
      timer?.invalidate()
      timer = nil
      button.setAccessibilityValue(isBreathing ? "正在生成" : nil)
      guard isBreathing else {
        button.image = image(caretOpacity: 1)
        return
      }
      if CidaMotion.reducesMotion {
        button.image = image(caretOpacity: CGFloat(CidaMotion.cursorMinimumOpacity))
        return
      }
      let start = Date()
      button.image = image(caretOpacity: Self.caretOpacity(after: 0))
      let timer = Timer(timeInterval: 1 / Self.ticksPerSecond, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.button.image = self.image(
            caretOpacity: Self.caretOpacity(after: Date().timeIntervalSince(start)))
        }
      }
      // Keep breathing while the status item's menu is open.
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    }
  }

  /// The result pane's waiting pulse: from the minimum opacity to 1 over `motion-breathe-ms` / 2
  /// and back, eased in and out.
  nonisolated static func caretOpacity(after elapsed: TimeInterval) -> CGFloat {
    let half = CidaMotion.breatheHalfCycleSeconds
    let phase = elapsed.truncatingRemainder(dividingBy: 2 * half)
    let progress = phase < half ? phase / half : (2 * half - phase) / half
    let eased = progress * progress * (3 - 2 * progress)
    let minimum = Double(CidaMotion.cursorMinimumOpacity)
    return CGFloat(minimum + (1 - minimum) * eased)
  }

  func image(caretOpacity: CGFloat) -> NSImage {
    let minimum = CGFloat(CidaMotion.cursorMinimumOpacity)
    let step = Int(
      ((caretOpacity - minimum) / (1 - minimum) * CGFloat(Self.opacitySteps)).rounded())
    let clampedStep = min(max(step, 0), Self.opacitySteps)
    if let cached = images[clampedStep] { return cached }
    let opacity = minimum + (1 - minimum) * CGFloat(clampedStep) / CGFloat(Self.opacitySteps)
    let image = NSImage(size: Self.size, flipped: false) { [glyph, caret] rect in
      glyph.draw(in: rect)
      caret.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "辞达"
    images[clampedStep] = image
    return image
  }

  private static func layer(_ name: String) -> NSImage? {
    let bundle = CidaResourceBundle.bundle
    guard
      let url = bundle.url(forResource: name, withExtension: "svg", subdirectory: "Brand")
        ?? bundle.url(forResource: name, withExtension: "svg")
    else { return nil }
    return NSImage(contentsOf: url)
  }
}

/// 辞达 set in the brand face with the accent caret after it, as in the app icon.
struct CidaWordmark: View {
  private static let size: CGFloat = 12
  /// The caret keeps the mark's proportions: 0.8 em tall, a tenth as wide but at least 1.5 pt,
  /// its centre a little below the glyphs' centre.
  private static let caretHeight: CGFloat = size * 0.8
  private static let caretWidth: CGFloat = max(caretHeight / 10, 1.5)

  var body: some View {
    HStack(spacing: 0) {
      Text("辞达")
        .font(CidaDesign.brand(Self.size, weight: .semibold))
        .tracking(2)
        .foregroundStyle(CidaDesign.textSecondary)
      Rectangle()
        .fill(CidaDesign.accent)
        .frame(width: Self.caretWidth, height: Self.caretHeight)
        .offset(y: Self.size * 0.06)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("辞达")
  }
}

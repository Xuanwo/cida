import AppKit
import QuartzCore
import SwiftUI

/// Shared nonactivating feedback for the translation layer and selection improvement.
/// Optional actions stay clickable without taking keyboard focus from the source editor.
final class CidaHintPanel: NSPanel {
  private let container = NSView()
  private let hosting = NSHostingView(rootView: HintContent(text: ""))
  private var shownAt: Date?
  private(set) var text: String?

  init(identifier: String = "translation-layer-hint") {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    // Above the translations it may talk about.
    level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    animationBehavior = .none
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    hosting.autoresizingMask = [.width, .height]
    hosting.frame = container.bounds
    container.addSubview(hosting)
    contentView = container
    setAccessibilityIdentifier("\(identifier)-panel")
    setAccessibilityLabel("辞达提示")
    // The pill is read as one element, like the translations, whether or not the panel is key.
    hosting.setAccessibilityElement(true)
    hosting.setAccessibilityRole(.staticText)
    hosting.setAccessibilityIdentifier(identifier)
  }

  override var canBecomeKey: Bool { false }

  /// How long a statement stays (§五 提示胶囊): long enough to read one short line.
  static let briefSeconds = 1.5
  /// A statement that also says what to press next.
  static let instructiveSeconds = 2.5

  /// Centred on the screen's free area, the pill's top edge on the panel's; `size` includes
  /// the room left for the shadow.
  static func frame(fitting size: CGSize, in visibleFrame: CGRect) -> CGRect {
    let anchor = CidaDesign.Panel.topCenter(in: visibleFrame)
    return CGRect(
      x: floor(anchor.x - size.width / 2), y: floor(anchor.y + CidaHintPill.shadowInsets.top - size.height),
      width: size.width, height: size.height)
  }

  /// Shows `text` for `seconds`, or until `hide` when nil; `onPress` makes the pill a button.
  func show(_ text: String, for seconds: Double?, action: String? = nil, on screen: NSScreen? = nil, onPress: (() -> Void)? = nil) {
    let wasShowing = isVisible && self.text != nil
    self.text = text
    hosting.rootView = HintContent(text: text, action: action, onPress: onPress)
    let mouse = NSEvent.mouseLocation
    let screen = screen ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    setFrame(Self.frame(fitting: hosting.fittingSize, in: screen?.visibleFrame ?? .zero), display: true)
    hosting.frame = container.bounds
    ignoresMouseEvents = onPress == nil
    hosting.setAccessibilityElement(action == nil)
    hosting.setAccessibilityLabel(text)
    hosting.setAccessibilityValue(text)
    hosting.wantsLayer = true
    hosting.layer?.removeAllAnimations()
    alphaValue = 1
    orderFrontRegardless()
    // In and out like the capture hint (`motion-icon-in-ms`); a new message replaces the
    // one showing without a flicker.
    if wasShowing {
      hosting.layer?.opacity = 1
    } else {
      fade(hosting.layer, from: 0, to: 1, duration: CidaMotion.resolvedDuration(CidaMotion.iconInSeconds, in: self))
    }
    let shown = Date()
    shownAt = shown
    guard let seconds else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self, shownAt == shown else { return }
      hide()
    }
  }

  func hide() {
    guard isVisible || shownAt != nil else {
      text = nil
      orderOut(nil)
      return
    }
    let shown = shownAt
    text = nil
    // A layer fade: a window's own alpha animation does not always run in a Release build
    // under automation, which left panels ordered in but transparent.
    let duration = CidaMotion.resolvedDuration(CidaMotion.iconInSeconds, in: self)
    fade(hosting.layer, from: 1, to: 0, duration: duration)
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
      guard let self, shownAt == shown else { return }
      orderOut(nil)
    }
  }
}

/// Fades `layer` and leaves it at `to`; with no duration (reduced motion) it lands at once.
@MainActor
func fade(_ layer: CALayer?, from: Float, to: Float, duration: TimeInterval) {
  guard let layer else { return }
  layer.opacity = to
  guard duration > 0 else { return }
  let animation = CABasicAnimation(keyPath: "opacity")
  animation.fromValue = from
  animation.toValue = to
  animation.duration = duration
  animation.timingFunction = CidaMotion.Curve.easeOut.timingFunction
  layer.add(animation, forKey: "fade")
}

/// Existing layer hints remain whole-pill actions; named actions expose a separate button.
struct HintContent: View {
  let text: String
  var action: String?
  var onPress: (() -> Void)?

  var body: some View {
    CidaHintPill(text: text, action: action, onPress: onPress)
      .onTapGesture { if action == nil { onPress?() } }
  }
}

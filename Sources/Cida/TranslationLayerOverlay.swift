import AppKit
import QuartzCore
import SwiftUI

/// How one translated paragraph is painted (`Design/spec/translation-layer.md` §三): with the
/// original's colours when the screen can be read, on paper when it cannot.
struct LayerTextStyle: Equatable {
  let background: NSColor
  let foreground: NSColor
  let isPaper: Bool

  static func paper(darkAppearance: Bool) -> LayerTextStyle {
    darkAppearance
      ? LayerTextStyle(
        background: CidaDesign.Palette.textInk.appKit,
        foreground: CidaDesign.Palette.surfacePaper.appKit, isPaper: true)
      : LayerTextStyle(
        background: CidaDesign.Palette.surfacePaper.appKit,
        foreground: CidaDesign.Palette.textInk.appKit, isPaper: true)
  }
}

/// One paragraph to draw, in the overlay's flipped coordinates.
struct LayerDrawing: Equatable {
  let frame: CGRect
  let text: String
  let lineHeight: CGFloat
  let style: LayerTextStyle
}

enum LayerTextFitting {
  /// The largest system font, up to the original's size, at which `text` wraps into `size`;
  /// nil when even 8 pt does not fit, and the original then stays visible (§三: 不裁字).
  static func fittedFont(text: String, size: CGSize, maximum: CGFloat) -> NSFont? {
    let minimum = min(8, maximum)
    func fits(_ pointSize: CGFloat) -> Bool {
      let measured = (text as NSString).boundingRect(
        with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: NSFont.systemFont(ofSize: pointSize)])
      return ceil(measured.height) <= size.height + 1 && ceil(measured.width) <= size.width + 1
    }
    guard size.width > 0, size.height > 0, fits(minimum) else { return nil }
    var low = minimum
    var high = max(maximum, minimum)
    if fits(high) { return .systemFont(ofSize: high) }
    for _ in 0..<10 {
      let middle = (low + high) / 2
      if fits(middle) { low = middle } else { high = middle }
    }
    return .systemFont(ofSize: low)
  }

  /// A line of body text is about 1.3 times its font size.
  static func fontSize(forLineHeight lineHeight: CGFloat) -> CGFloat {
    min(max(lineHeight / 1.3, 9), 28)
  }
}

/// Paper and ink of a paragraph in a window capture: the most common colour is the paper,
/// the populated colour furthest from it in luminance is the ink. Carried over from the
/// in-place screenshot translation.
enum LayerColorSampler {
  static func style(in image: CGImage, pixelRect: CGRect) -> LayerTextStyle? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let crop = image.cropping(to: pixelRect.insetBy(dx: -2, dy: -2).integral.intersection(bounds))
    else {
      return nil
    }
    let scale = min(1, 256 / CGFloat(max(crop.width, crop.height)))
    let width = max(1, Int(CGFloat(crop.width) * scale))
    let height = max(1, Int(CGFloat(crop.height) * scale))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    var bins: [Int: (count: Int, r: Double, g: Double, b: Double)] = [:]
    for index in stride(from: 0, to: bytes.count, by: 4) {
      let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
      let key = (r / 24) * 121 + (g / 24) * 11 + b / 24
      let previous = bins[key] ?? (0, 0, 0, 0)
      bins[key] = (previous.count + 1, previous.r + Double(r), previous.g + Double(g), previous.b + Double(b))
    }
    let colors = bins.values.map { bin in
      (
        count: bin.count,
        color: NSColor(
          srgbRed: bin.r / Double(bin.count) / 255, green: bin.g / Double(bin.count) / 255,
          blue: bin.b / Double(bin.count) / 255, alpha: 1)
      )
    }.sorted { $0.count > $1.count }
    guard let background = colors.first?.color else { return nil }
    func luminance(_ color: NSColor) -> CGFloat {
      0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
    let backgroundLuminance = luminance(background)
    // Antialiased edges outnumber solid ink; take a populated colour of clear contrast.
    let foreground =
      colors.filter {
        $0.count >= max(2, width * height / 1_000)
          && abs(luminance($0.color) - backgroundLuminance) > 0.3
      }.max {
        abs(luminance($0.color) - backgroundLuminance) < abs(luminance($1.color) - backgroundLuminance)
      }?.color
      ?? (backgroundLuminance > 0.5 ? NSColor.black : NSColor.white)
    return LayerTextStyle(background: background, foreground: foreground, isPaper: false)
  }
}

/// The window over one pane. It never takes a click: presses, scrolling and selection all
/// reach the application underneath (§一).
final class LayerOverlayPanel: NSPanel {
  let overlayView: LayerOverlayView

  init() {
    overlayView = LayerOverlayView(frame: .zero)
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    animationBehavior = .none
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    contentView = overlayView
    setAccessibilityIdentifier("translation-layer-overlay")
    setAccessibilityLabel("原处译文")
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Paints the translated paragraphs as layers, so hiding while scrolling and showing an
/// original under the pointer are opacity changes.
final class LayerOverlayView: NSView {
  private var blockLayers: [CALayer] = []
  private let blocksLayer = CALayer()
  /// Paragraphs ⌥D asked for, breathing on accent while their translation is on the way.
  private let pendingLayer = CALayer()
  private(set) var pendingFrames: [CGRect] = []
  private let occlusionMask = CAShapeLayer()
  private(set) var drawings: [LayerDrawing] = []
  private(set) var peekedIndex: Int?
  /// Moves every paragraph by this much, from the screen's own motion, until the next read.
  private(set) var offset: CGFloat = 0

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.addSublayer(blocksLayer)
    blocksLayer.addSublayer(pendingLayer)
    occlusionMask.fillRule = .evenOdd
    blocksLayer.mask = occlusionMask
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("translation-layer-content")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    blocksLayer.frame = bounds
    pendingLayer.frame = bounds
    CATransaction.commit()
  }

  /// The paragraphs waiting for their translation (§二 等待), in this view's coordinates:
  /// accent at 16%, breathing down to 7% over `motion-breathe-ms`.
  func setPending(_ frames: [CGRect]) {
    guard frames != pendingFrames else { return }
    pendingFrames = frames
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pendingLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
    for frame in frames {
      let underlay = CALayer()
      underlay.frame = frame.insetBy(dx: -3, dy: -3)
      underlay.cornerRadius = 4
      underlay.cornerCurve = .continuous
      underlay.backgroundColor = CidaDesign.Palette.accent.appKit.withAlphaComponent(0.16).cgColor
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.07 / 0.16
        breathe.duration = CidaMotion.breatheHalfCycleSeconds
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CidaMotion.Curve.easeInOut.timingFunction
        underlay.add(breathe, forKey: "breathe")
      }
      pendingLayer.addSublayer(underlay)
    }
    CATransaction.commit()
  }

  /// How many paragraphs are painted: a translation that does not fit leaves its original.
  var paintedCount: Int { blockLayers.count }

  func show(_ drawings: [LayerDrawing], scale: CGFloat) {
    // The tree is read again every second; unchanged paragraphs keep their layers and a
    // paragraph showing its original keeps showing it.
    if drawings == self.drawings {
      setOffset(0)
      return
    }
    self.drawings = drawings
    peekedIndex = nil
    offset = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    blockLayers.forEach { $0.removeFromSuperlayer() }
    blockLayers = drawings.compactMap { makeLayer(for: $0, scale: scale) }
    blockLayers.forEach(blocksLayer.addSublayer)
    pendingLayer.removeFromSuperlayer()
    blocksLayer.insertSublayer(pendingLayer, at: 0)
    blocksLayer.sublayerTransform = CATransform3DIdentity
    CATransaction.commit()
    setAccessibilityValue(drawings.map(\.text).joined(separator: "\n"))
  }

  /// Everything moves with the content between two reads of the tree (§五).
  func setOffset(_ offset: CGFloat) {
    self.offset = offset
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    blocksLayer.sublayerTransform = CATransform3DMakeTranslation(0, offset, 0)
    CATransaction.commit()
  }

  /// Parts covered by other windows are not painted (§五), in this view's coordinates.
  func setOcclusion(_ covered: [CGRect]) {
    let path = CGMutablePath()
    path.addRect(bounds)
    for rect in covered where rect.intersects(bounds) { path.addRect(rect.intersection(bounds)) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    occlusionMask.frame = bounds
    occlusionMask.path = path
    CATransaction.commit()
  }

  /// The pointer rests on a paragraph: it fades to show the original (§四).
  func setPeek(_ index: Int?, animated: Bool) {
    guard index != peekedIndex else { return }
    peekedIndex = index
    CATransaction.begin()
    CATransaction.setAnimationDuration(animated ? CidaMotion.heightSeconds : 0)
    for (layerIndex, layer) in blockLayers.enumerated() {
      layer.opacity = layerIndex == index ? 0 : 1
    }
    CATransaction.commit()
  }

  func index(at point: CGPoint) -> Int? {
    let shifted = CGPoint(x: point.x, y: point.y - offset)
    return drawings.firstIndex { $0.frame.contains(shifted) }
  }

  private func makeLayer(for drawing: LayerDrawing, scale: CGFloat) -> CALayer? {
    // Paper stands a little proud of the original; sampled paint covers it exactly.
    let frame =
      drawing.style.isPaper
      ? drawing.frame.insetBy(dx: -8, dy: -3) : drawing.frame.insetBy(dx: -1, dy: -1)
    let textFrame = drawing.style.isPaper ? drawing.frame.insetBy(dx: 0, dy: 0) : drawing.frame
    let maximum = LayerTextFitting.fontSize(forLineHeight: drawing.lineHeight)
    guard
      let font = LayerTextFitting.fittedFont(
        text: drawing.text, size: textFrame.size, maximum: maximum)
    else {
      return nil
    }
    let container = CALayer()
    container.frame = frame
    container.backgroundColor = drawing.style.background.cgColor
    if drawing.style.isPaper {
      container.cornerRadius = CidaDesign.Radius.chip
      container.cornerCurve = .continuous
      container.borderWidth = 1
      container.borderColor = NSColor.black.withAlphaComponent(0x12 / 255).cgColor
    }
    let text = CATextLayer()
    text.frame = CGRect(
      x: textFrame.minX - frame.minX, y: textFrame.minY - frame.minY,
      width: textFrame.width, height: textFrame.height)
    text.string = NSAttributedString(
      string: drawing.text,
      attributes: [.font: font, .foregroundColor: drawing.style.foreground])
    text.isWrapped = true
    text.contentsScale = scale
    container.addSublayer(text)
    return container
  }
}

/// The pill at a pane's lower right (§三): only while paragraphs wait, or after a failure,
/// when a press retries. It is the only part of the layer that takes a click.
final class LayerStatusPanel: NSPanel {
  private let hosting: NSHostingView<LayerStatusPill>
  var onRetry: (() -> Void)?
  /// When the latest transient message appeared; an older one's fade leaves it alone.
  fileprivate var lastFlash: Date?

  init() {
    hosting = NSHostingView(rootView: LayerStatusPill(text: ""))
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    animationBehavior = .none
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    contentView = hosting
    setAccessibilityIdentifier("translation-layer-status")
  }

  override var canBecomeKey: Bool { false }

  /// Places the pill inside `pane` (AppKit screen coordinates), 14 pt from its lower right.
  func show(text: String, retryable: Bool, in pane: CGRect) {
    hosting.rootView = LayerStatusPill(text: text, onPress: retryable ? { [weak self] in self?.onRetry?() } : nil)
    let size = hosting.fittingSize
    setFrame(
      CGRect(x: pane.maxX - size.width - 14 + LayerStatusPill.shadowMargin,
             y: pane.minY + 12 - LayerStatusPill.shadowMargin, width: size.width, height: size.height),
      display: true)
    ignoresMouseEvents = !retryable
    setAccessibilityValue(text)
    orderFront(nil)
  }
}

extension LayerStatusPanel {
  /// Shows `text` for `seconds` at the lower right of `rect` (AppKit coordinates): turning a
  /// window's translation on or off (§三).
  func flash(text: String, in rect: CGRect, for seconds: Double) {
    show(text: text, retryable: false, in: rect)
    fadeOut(after: seconds)
  }

  /// Shows `text` beside the pointer (AppKit coordinates) for 1.2 s: nothing to translate
  /// there (§二).
  func flash(text: String, near point: CGPoint) {
    show(text: text, retryable: false, in: CGRect(x: point.x, y: point.y, width: 0, height: 0))
    let size = frame.size
    setFrameOrigin(
      CGPoint(x: point.x + 14 - LayerStatusPill.shadowMargin, y: point.y - 22 - size.height + LayerStatusPill.shadowMargin))
    fadeOut(after: 1.2)
  }

  private func fadeOut(after seconds: Double) {
    alphaValue = 1
    let shown = Date()
    lastFlash = shown
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self, lastFlash == shown else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = CidaMotion.resolvedDuration(0.3, in: self)
        self.animator().alphaValue = 0
      } completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.lastFlash == shown else { return }
          self.orderOut(nil)
          self.alphaValue = 1
        }
      }
    }
  }
}

/// A window outlined for a moment when its translation turns on (§三): 1.5 pt accent, fading
/// in over 150 ms, holding 600 ms, fading out over 300 ms.
final class LayerOutlinePanel: NSPanel {
  private let outline = CAShapeLayer()

  init() {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = true
    animationBehavior = .none
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    let view = NSView()
    view.wantsLayer = true
    view.layer?.addSublayer(outline)
    contentView = view
    outline.fillColor = nil
    outline.strokeColor = CidaDesign.Palette.accent.appKit.cgColor
    outline.lineWidth = 1.5
    setAccessibilityIdentifier("translation-layer-outline")
  }

  override var canBecomeKey: Bool { false }

  /// Outlines `rect` (AppKit coordinates) just outside its edge.
  func flash(around rect: CGRect) {
    let frame = rect.insetBy(dx: -3, dy: -3)
    setFrame(frame, display: false)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    outline.frame = CGRect(origin: .zero, size: frame.size)
    outline.path = CGPath(
      roundedRect: outline.frame.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 12, cornerHeight: 12, transform: nil)
    CATransaction.commit()
    alphaValue = 0
    orderFront(nil)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = CidaMotion.resolvedDuration(0.15, in: self)
      self.animator().alphaValue = 1
    } completionHandler: { [weak self] in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        guard let self else { return }
        NSAnimationContext.runAnimationGroup { context in
          context.duration = CidaMotion.resolvedDuration(0.3, in: self)
          self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
          MainActor.assumeIsolated { self?.orderOut(nil) }
        }
      }
    }
  }
}

struct LayerStatusPill: View {
  static let shadowMargin: CGFloat = 16
  let text: String
  var onPress: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      CidaWordmark()
      Text(text)
        .font(CidaDesign.ui(12, weight: .medium))
        .foregroundStyle(CidaDesign.textControl)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .background(CidaDesign.surface, in: Capsule())
    .overlay { Capsule().strokeBorder(Color.black.opacity(0x12 / 255), lineWidth: 1) }
    .shadow(color: CidaDesign.textPrimary.opacity(0x14 / 255), radius: 3, y: 2)
    .shadow(color: CidaDesign.textPrimary.opacity(0x22 / 255), radius: 12, y: 10)
    .contentShape(Capsule())
    .onTapGesture { onPress?() }
    .padding(Self.shadowMargin)
    .accessibilityElement(children: .combine)
  }
}

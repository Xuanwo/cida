import AppKit
import QuartzCore
import SwiftUI

/// The full-screen layer the capture shortcut puts over a frozen screen
/// (`Design/boards/capture.html`): a veil fades in over the frozen image, a
/// hint pill names what to do, and the dragged frame is lifted out of the
/// veil as a sheet of paper. Escape, a right click, or a click without a
/// drag cancels.
@MainActor
enum CaptureOverlay {
  /// Shows `image` over `screen` and returns the part of it the user framed,
  /// or nil when they cancelled.
  static func selectRegion(of image: CGImage, on screen: NSScreen) async -> CGImage? {
    let panel = CaptureOverlayPanel(screen: screen)
    let view = CaptureOverlayView(
      frame: NSRect(origin: .zero, size: screen.frame.size), image: image,
      veil: CaptureVeil(forScreen: image))
    panel.contentView = view
    defer { panel.orderOut(nil) }
    return await withCheckedContinuation { continuation in
      view.onFinish = { selection in
        view.onFinish = nil
        guard let selection else {
          continuation.resume(returning: nil)
          return
        }
        let pixelRect = CaptureGeometry.pixelRect(
          for: selection, in: view.bounds.size,
          imageSize: CGSize(width: image.width, height: image.height))
        continuation.resume(returning: image.cropping(to: pixelRect))
      }
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(view)
      view.fadeInVeil()
    }
  }
}

/// Maps a selection in the overlay (points, origin bottom-left) onto the
/// frozen image (pixels, origin top-left).
enum CaptureGeometry {
  /// A drag shorter than this on either side is a click, which cancels.
  static let minimumSelectionSide: CGFloat = 4

  static func pixelRect(for selection: CGRect, in viewSize: CGSize, imageSize: CGSize) -> CGRect {
    let scaleX = imageSize.width / viewSize.width
    let scaleY = imageSize.height / viewSize.height
    let rect = CGRect(
      x: selection.minX * scaleX,
      y: (viewSize.height - selection.maxY) * scaleY,
      width: selection.width * scaleX,
      height: selection.height * scaleY
    ).integral
    return rect.intersection(CGRect(origin: .zero, size: imageSize))
  }

  static func selection(from start: CGPoint, to end: CGPoint, within bounds: CGRect) -> CGRect {
    CGRect(
      x: min(start.x, end.x), y: min(start.y, end.y),
      width: abs(end.x - start.x), height: abs(end.y - start.y)
    ).intersection(bounds)
  }
}

/// What the frozen screen is veiled with: the result pane's paper over a
/// light screen, ink over a dark one, where a paper wash would turn the
/// whole screen milky. On ink the panel's shadows vanish, so the sheet's
/// edge is a light hairline instead of a dark one.
enum CaptureVeil: Equatable {
  case paper
  case ink

  init(averageLuminance: CGFloat) {
    self = averageLuminance < 0.5 ? .ink : .paper
  }

  init(forScreen image: CGImage) {
    self.init(averageLuminance: Self.averageLuminance(of: image))
  }

  var color: CGColor {
    switch self {
    case .paper: CidaDesign.Palette.surfacePaper.appKit.withAlphaComponent(0.72).cgColor
    case .ink: CidaDesign.Palette.textInk.appKit.withAlphaComponent(0.45).cgColor
    }
  }

  var sheetEdge: CGColor {
    switch self {
    case .paper: NSColor.black.withAlphaComponent(0x12 / 255).cgColor
    case .ink: NSColor.white.withAlphaComponent(0x24 / 255).cgColor
    }
  }

  /// Relative luminance averaged over a 32 × 32 downsample of the image.
  static func averageLuminance(of image: CGImage) -> CGFloat {
    let side = 32
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else {
        return false
      }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { return 1 }
    var total: CGFloat = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
      total +=
        0.2126 * CGFloat(pixels[index]) + 0.7152 * CGFloat(pixels[index + 1])
        + 0.0722 * CGFloat(pixels[index + 2])
    }
    return total / CGFloat(side * side) / 255
  }
}

final class CaptureOverlayPanel: NSPanel {
  override var canBecomeKey: Bool { true }

  init(screen: NSScreen) {
    super.init(
      contentRect: screen.frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    setFrame(screen.frame, display: false)
    level = .screenSaver
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = true
    hasShadow = false
    animationBehavior = .none
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    title = "截图框选"
    setAccessibilityIdentifier("capture-overlay")
    setAccessibilityLabel("截图框选")
  }
}

/// The frozen image is the view's layer contents and never redraws. The
/// veil covers it; a drag only moves the sheet, which shows the same image
/// through `contentsRect`, and its two shadows.
final class CaptureOverlayView: NSView {
  private let image: CGImage
  let veil: CaptureVeil
  private var dragStart: CGPoint?
  private(set) var selection: CGRect?
  var onFinish: ((CGRect?) -> Void)?

  private let veilLayer = CALayer()
  /// The panel's shadow is two layers deep (`Spec — 面板模型` §七): a tight
  /// contact shadow and a wide ambient one. On ink neither would show, so
  /// both stay hidden there.
  private let contactShadowLayer = CALayer()
  private let ambientShadowLayer = CALayer()
  private let sheetLayer = CALayer()
  private let hint: NSHostingView<CaptureHint>

  init(frame: NSRect, image: CGImage, veil: CaptureVeil) {
    self.image = image
    self.veil = veil
    hint = NSHostingView(rootView: CaptureHint())
    super.init(frame: frame)
    wantsLayer = true
    layer?.contentsGravity = .resize

    veilLayer.backgroundColor = veil.color
    let shadows: [(CALayer, Float, CGFloat, CGFloat)] = [
      (contactShadowLayer, Float(0x14) / 255, -2, 3),
      (ambientShadowLayer, Float(0x30) / 255, -28, 36),
    ]
    for (shadowLayer, opacity, offset, radius) in shadows {
      // An opaque body the sheet covers exactly: a layer casts its shadow
      // from what it draws, so an empty one may cast none.
      shadowLayer.backgroundColor = CidaDesign.Palette.surface.appKit.cgColor
      shadowLayer.cornerRadius = CidaDesign.Radius.card
      shadowLayer.cornerCurve = .continuous
      shadowLayer.shadowColor = CidaDesign.Palette.textPrimary.appKit.cgColor
      shadowLayer.shadowOpacity = opacity
      shadowLayer.shadowOffset = CGSize(width: 0, height: offset)
      shadowLayer.shadowRadius = radius
    }
    sheetLayer.contents = image
    sheetLayer.contentsGravity = .resize
    sheetLayer.cornerRadius = CidaDesign.Radius.card
    sheetLayer.cornerCurve = .continuous
    sheetLayer.masksToBounds = true
    sheetLayer.borderWidth = 1
    sheetLayer.borderColor = veil.sheetEdge
    for sublayer in [veilLayer, ambientShadowLayer, contactShadowLayer, sheetLayer] {
      layer?.addSublayer(sublayer)
    }

    addSubview(hint)
    hint.wantsLayer = true
    hint.layer?.zPosition = 10

    updateLayers()
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("拖动框选要翻译的文字")
    setAccessibilityIdentifier("capture-overlay-canvas")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.contents = image
  }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// The hint is only a label; every press belongs to the overlay.
  override func hitTest(_ point: NSPoint) -> NSView? {
    frame.contains(point) ? self : nil
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
  }

  override func layout() {
    super.layout()
    // Centred, with the pill's top edge where the panel's is
    // (`panel-top-ratio`); the hosting view also holds the shadow margin.
    let size = hint.fittingSize
    let pillTop = bounds.height * (1 - CidaDesign.Panel.topRatio)
    hint.frame = NSRect(
      x: floor((bounds.width - size.width) / 2),
      y: floor(pillTop + CaptureHint.shadowMargin - size.height),
      width: size.width, height: size.height)
    updateLayers()
  }

  /// The frozen image already matches the screen, so the overlay appears
  /// unnoticed; only the veil and the hint fade in (`motion-icon-in-ms`).
  func fadeInVeil() {
    let duration = CidaMotion.resolvedDuration(CidaMotion.iconInSeconds, in: window)
    guard duration > 0 else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = duration
    fade.timingFunction = CidaMotion.easeOut
    veilLayer.add(fade, forKey: "fade-in")
    hint.layer?.add(fade, forKey: "fade-in")
  }

  private func updateLayers() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    veilLayer.frame = bounds
    let sheetFrame = selection ?? .zero
    let isLifted = selection != nil
    for sublayer in [ambientShadowLayer, contactShadowLayer, sheetLayer] {
      sublayer.frame = sheetFrame
      sublayer.isHidden = !isLifted
    }
    if veil == .ink {
      ambientShadowLayer.isHidden = true
      contactShadowLayer.isHidden = true
    }
    let shadowPath = CGPath(
      roundedRect: CGRect(origin: .zero, size: sheetFrame.size),
      cornerWidth: CidaDesign.Radius.card, cornerHeight: CidaDesign.Radius.card,
      transform: nil)
    ambientShadowLayer.shadowPath = shadowPath
    contactShadowLayer.shadowPath = shadowPath
    if isLifted, bounds.width > 0, bounds.height > 0 {
      sheetLayer.contentsRect = CaptureGeometry.contentsRect(for: sheetFrame, in: bounds.size)
    }
    CATransaction.commit()
    updateHintVisibility()
  }

  /// The hint never covers the sheet: it fades out while the frame reaches
  /// it and back when the frame moves away.
  private func updateHintVisibility() {
    let pill = hint.frame.insetBy(dx: CaptureHint.shadowMargin, dy: CaptureHint.shadowMargin)
    let isCovering = selection.map { $0.intersects(pill) } ?? false
    let targetAlpha: CGFloat = isCovering ? 0 : 1
    guard hintAlphaTarget != targetAlpha else { return }
    hintAlphaTarget = targetAlpha
    NSAnimationContext.runAnimationGroup { context in
      context.duration = CidaMotion.resolvedDuration(CidaMotion.iconInSeconds, in: window)
      hint.animator().alphaValue = targetAlpha
    }
  }

  /// Where the hint's alpha is heading, so a drag does not restart a fade
  /// on every move.
  private var hintAlphaTarget: CGFloat = 1

  override func mouseDown(with event: NSEvent) {
    dragStart = convert(event.locationInWindow, from: nil)
    selection = nil
    updateLayers()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragStart else { return }
    selection = CaptureGeometry.selection(
      from: dragStart, to: convert(event.locationInWindow, from: nil), within: bounds)
    updateLayers()
  }

  override func mouseUp(with event: NSEvent) {
    guard let selection,
      selection.width >= CaptureGeometry.minimumSelectionSide,
      selection.height >= CaptureGeometry.minimumSelectionSide
    else {
      onFinish?(nil)
      return
    }
    onFinish?(selection)
  }

  override func rightMouseDown(with event: NSEvent) {
    onFinish?(nil)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onFinish?(nil)
    } else {
      super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) {
    onFinish?(nil)
  }
}

extension CaptureGeometry {
  /// The part of the layer's contents a sheet over `selection` shows. The
  /// unit square has its origin at the bottom-left, like the view.
  static func contentsRect(for selection: CGRect, in viewSize: CGSize) -> CGRect {
    CGRect(
      x: selection.minX / viewSize.width, y: selection.minY / viewSize.height,
      width: selection.width / viewSize.width, height: selection.height / viewSize.height)
  }
}

/// The pill at the panel's height: the wordmark, then what to do.
struct CaptureHint: View {
  /// Room around the pill for its shadow inside the hosting view.
  static let shadowMargin: CGFloat = 40

  var body: some View {
    HStack(spacing: 12) {
      CidaWordmark()
      Text("拖动框选要翻译的文字 · Esc 取消")
        .font(CidaDesign.ui(12.5, weight: .medium))
        .foregroundStyle(CidaDesign.textControl)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(CidaDesign.surface, in: Capsule())
    .overlay { Capsule().strokeBorder(Color.black.opacity(0x12 / 255), lineWidth: 1) }
    .shadow(color: CidaDesign.textPrimary.opacity(0x14 / 255), radius: 3, y: 2)
    .shadow(color: CidaDesign.textPrimary.opacity(0x30 / 255), radius: 36, y: 28)
    .padding(Self.shadowMargin)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("capture-overlay-hint")
  }
}

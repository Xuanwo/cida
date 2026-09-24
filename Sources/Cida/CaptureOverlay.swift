import AppKit
import QuartzCore

/// The full-screen layer the capture shortcut puts over a frozen screen
/// (Pencil `States — 截图框选`): the frozen image dimmed, the dragged region
/// at full brightness with a 1 pt white outline, a crosshair pointer.
/// Escape, a right click, or a click without a drag cancels.
@MainActor
enum CaptureOverlay {
  /// Shows `image` over `screen` and returns the part of it the user framed,
  /// or nil when they cancelled.
  static func selectRegion(of image: CGImage, on screen: NSScreen) async -> CGImage? {
    let panel = CaptureOverlayPanel(screen: screen)
    let view = CaptureOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
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

/// The frozen image is the layer's contents and never redraws; a drag only
/// moves the hole in the dimming and the outline.
final class CaptureOverlayView: NSView {
  private let image: CGImage
  private var dragStart: CGPoint?
  private(set) var selection: CGRect?
  var onFinish: ((CGRect?) -> Void)?

  private let dimmingLayer = CAShapeLayer()
  private let outlineLayer = CAShapeLayer()

  init(frame: NSRect, image: CGImage) {
    self.image = image
    super.init(frame: frame)
    wantsLayer = true
    layer?.contentsGravity = .resize
    dimmingLayer.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
    dimmingLayer.fillRule = .evenOdd
    outlineLayer.fillColor = nil
    outlineLayer.strokeColor = NSColor.white.cgColor
    outlineLayer.lineWidth = 1
    layer?.addSublayer(dimmingLayer)
    layer?.addSublayer(outlineLayer)
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

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
  }

  override func layout() {
    super.layout()
    updateLayers()
  }

  private func updateLayers() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dimmingLayer.frame = bounds
    outlineLayer.frame = bounds
    let dimmed = CGMutablePath()
    dimmed.addRect(bounds)
    if let selection {
      dimmed.addRect(selection)
      outlineLayer.path = CGPath(rect: selection.insetBy(dx: 0.5, dy: 0.5), transform: nil)
    } else {
      outlineLayer.path = nil
    }
    dimmingLayer.path = dimmed
    CATransaction.commit()
  }

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

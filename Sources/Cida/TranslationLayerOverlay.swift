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
  /// Where the links are in `text`; they are drawn in accent.
  var links: [NSRange] = []
  let lineHeight: CGFloat
  let style: LayerTextStyle
}

/// A translation set in Cida's result serif (§五): the largest size up to the original's that
/// fits its paragraph, lines as far apart as the face needs, and where the caret after the last
/// line goes. Coordinates are top-left, inside the paragraph's frame.
struct LayerTypeset {
  struct Line {
    let line: CTLine
    /// The baseline's start.
    let origin: CGPoint
  }

  let font: NSFont
  let lines: [Line]
  /// Cida's caret after the last character, as if Cida had just written it.
  let caret: CGRect

  /// A line of body text is about 1.2 times its font size: an app's text box that tall holds
  /// text of that size (Slack's 18 pt boxes hold 15 pt text).
  static func fontSize(forLineHeight lineHeight: CGFloat) -> CGFloat {
    min(max(lineHeight / 1.2, 9), 28)
  }

  /// Glyphs may reach this far past the paragraph's frame, above and below.
  static let bleed: CGFloat = 2

  /// Nil when even 8 pt does not fit, and the original then stays (不裁字).
  static func fitting(_ text: String, in size: CGSize, lineHeight: CGFloat) -> LayerTypeset? {
    let language = TextLanguageDetector.typography(of: text) ?? .chinese
    let maximum = fontSize(forLineHeight: lineHeight)
    let minimum = min(8, maximum)
    func set(_ pointSize: CGFloat) -> LayerTypeset? {
      typeset(text, font: CidaDesign.appKitResult(for: language, size: pointSize), in: size, lineHeight: lineHeight)
    }
    guard size.width > 0, size.height > 0, set(minimum) != nil else { return nil }
    if let largest = set(maximum) { return largest }
    var low = minimum
    var high = maximum
    for _ in 0..<10 {
      let middle = (low + high) / 2
      if set(middle) != nil { low = middle } else { high = middle }
    }
    return set(low)
  }

  /// Lines start where the original's do: the first is centred on the original's first line,
  /// the rest follow at the face's own spacing, however many lines the original took.
  private static func typeset(_ text: String, font: NSFont, in size: CGSize, lineHeight: CGFloat) -> LayerTypeset? {
    let string = NSAttributedString(string: text, attributes: [.font: font])
    let typesetter = CTTypesetterCreateWithAttributedString(string)
    let length = string.length
    var ranges: [CFRange] = []
    var start = 0
    while start < length {
      let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(size.width))
      guard count > 0 else { return nil }
      ranges.append(CFRange(location: start, length: count))
      start += count
    }
    let ascent = font.ascender
    let glyphs = font.ascender - font.descender
    let pitch = max(glyphs, font.pointSize * 1.4)
    let top = (min(lineHeight, size.height) - pitch) / 2
    guard top >= -bleed, top + CGFloat(ranges.count) * pitch <= size.height + bleed else { return nil }
    var lines: [Line] = []
    var lastWidth: CGFloat = 0
    for (index, range) in ranges.enumerated() {
      let line = CTTypesetterCreateLine(typesetter, range)
      let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
      guard width <= size.width + 1 else { return nil }
      let baseline = top + CGFloat(index) * pitch + (pitch - glyphs) / 2 + ascent
      lines.append(Line(line: line, origin: CGPoint(x: 0, y: baseline)))
      lastWidth = width
    }
    // The caret stands as tall as the text, centred on its middle (about a third of the size
    // above the baseline).
    let height = font.pointSize
    let middle = (lines.last?.origin.y ?? 0) - font.pointSize * 0.35
    let caret = CGRect(x: lastWidth + 3, y: middle - height / 2, width: CidaMotion.cursorWidth, height: height)
    return LayerTypeset(font: font, lines: lines, caret: caret)
  }

  /// The paragraph drawn onto `background` with font smoothing, as the app draws its own text:
  /// a text layer drawn over transparency comes out about a sixth lighter than native text.
  func image(
    of text: String, links: [NSRange], size: CGSize, style: LayerTextStyle, scale: CGFloat
  ) -> CGImage? {
    let height = size.height + Self.bleed * 2
    guard
      let context = CGContext(
        data: nil, width: Int((size.width * scale).rounded(.up)), height: Int((height * scale).rounded(.up)),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(style.background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: size.width, height: height))
    context.setAllowsFontSmoothing(true)
    context.setShouldSmoothFonts(true)
    let colored = NSMutableAttributedString(
      string: text,
      attributes: [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.foreground.cgColor])
    for link in links where NSMaxRange(link) <= colored.length {
      colored.addAttribute(
        NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: CidaDesign.Palette.accent.appKit.cgColor,
        range: link)
    }
    // The same lines, in colour: breaks and positions come from the plain layout.
    for line in lines {
      let range = CTLineGetStringRange(line.line)
      let piece = CTLineCreateWithAttributedString(
        colored.attributedSubstring(from: NSRange(location: range.location, length: range.length)))
      context.textPosition = CGPoint(x: line.origin.x, y: height - Self.bleed - line.origin.y)
      CTLineDraw(piece, context)
    }
    return context.makeImage()
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
      // Skips pixels instead of blending them: a blended thin stroke turns black ink grey
      // and pulls a white page a shade darker, and either shows around the translation.
      context.interpolationQuality = .none
      context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    // Near colours count together; each group paints with its most common exact colour.
    var exact: [UInt32: Int] = [:]
    for index in stride(from: 0, to: bytes.count, by: 4) {
      let rgb = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
      exact[rgb, default: 0] += 1
    }
    var groups: [Int: (count: Int, top: UInt32, topCount: Int)] = [:]
    for (rgb, count) in exact {
      let key = Int(rgb >> 16 & 0xFF) / 24 * 121 + Int(rgb >> 8 & 0xFF) / 24 * 11 + Int(rgb & 0xFF) / 24
      var group = groups[key] ?? (0, rgb, 0)
      group.count += count
      if count > group.topCount { (group.top, group.topCount) = (rgb, count) }
      groups[key] = group
    }
    let colors = groups.values.map { group in
      (
        count: group.count,
        color: NSColor(
          srgbRed: CGFloat(group.top >> 16 & 0xFF) / 255, green: CGFloat(group.top >> 8 & 0xFF) / 255,
          blue: CGFloat(group.top & 0xFF) / 255, alpha: 1)
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
  /// Carets breathing after the paragraphs whose translation is on the way.
  private let pendingLayer = CALayer()
  private(set) var pendingFrames: [CGRect] = []
  private let occlusionMask = CAShapeLayer()
  private(set) var drawings: [LayerDrawing] = []

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

  /// The paragraphs waiting for their translation (§二 等待): Cida's caret after each one's
  /// last line, breathing between full and `motion-cursor-opacity-min` over
  /// `motion-breathe-ms`, as if Cida were writing. `carets` are in this view's coordinates.
  func setPending(_ carets: [CGRect]) {
    guard carets != pendingFrames else { return }
    pendingFrames = carets
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pendingLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
    for frame in carets {
      let caret = CALayer()
      caret.frame = frame
      caret.cornerRadius = CidaMotion.cursorWidth / 2
      caret.backgroundColor = CidaDesign.Palette.accent.appKit.cgColor
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = CidaMotion.cursorMinimumOpacity
        breathe.duration = CidaMotion.breatheHalfCycleSeconds
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CidaMotion.Curve.easeInOut.timingFunction
        caret.add(breathe, forKey: "breathe")
      }
      pendingLayer.addSublayer(caret)
    }
    CATransaction.commit()
  }

  /// How many paragraphs are painted: a translation that does not fit leaves its original.
  var paintedCount: Int { blockLayers.count }

  func show(_ drawings: [LayerDrawing], scale: CGFloat) {
    // The tree is read again every second; unchanged paragraphs keep their layers and a
    // paragraph showing its original keeps showing it.
    if drawings == self.drawings { return }
    self.drawings = drawings
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    blockLayers.forEach { $0.removeFromSuperlayer() }
    blockLayers = drawings.compactMap { makeLayer(for: $0, scale: scale) }
    blockLayers.forEach(blocksLayer.addSublayer)
    pendingLayer.removeFromSuperlayer()
    blocksLayer.insertSublayer(pendingLayer, at: 0)
    CATransaction.commit()
    setAccessibilityValue(drawings.map(\.text).joined(separator: "\n"))
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


  /// A paragraph's paper card, and the underlay it replaces: 8 pt wider on each side, 3 pt
  /// taller (§五).
  static func cardFrame(around paragraph: CGRect) -> CGRect {
    paragraph.insetBy(dx: -8, dy: -3)
  }

  private func makeLayer(for drawing: LayerDrawing, scale: CGFloat) -> CALayer? {
    guard let typeset = LayerTypeset.fitting(drawing.text, in: drawing.frame.size, lineHeight: drawing.lineHeight),
      let image = typeset.image(
        of: drawing.text, links: drawing.links, size: drawing.frame.size, style: drawing.style, scale: scale)
    else {
      return nil
    }
    // Paper stands a little proud of the original; the app's own background covers it exactly.
    let text = drawing.frame.insetBy(dx: 0, dy: -LayerTypeset.bleed)
    let frame = drawing.style.isPaper ? Self.cardFrame(around: drawing.frame).union(text) : text.insetBy(dx: -1, dy: 0)
    let container = CALayer()
    container.frame = frame
    container.backgroundColor = drawing.style.background.cgColor
    if drawing.style.isPaper {
      container.cornerRadius = CidaDesign.Radius.chip
      container.cornerCurve = .continuous
      container.borderWidth = 1
      container.borderColor = NSColor.black.withAlphaComponent(0x12 / 255).cgColor
    }
    let paragraph = CALayer()
    paragraph.frame = text.offsetBy(dx: -frame.minX, dy: -frame.minY)
    paragraph.contents = image
    paragraph.contentsScale = scale
    container.addSublayer(paragraph)
    // Cida's caret after the last character, at rest: this paragraph is Cida's (§五).
    let caret = CALayer()
    caret.frame = typeset.caret.offsetBy(dx: drawing.frame.minX - frame.minX, dy: drawing.frame.minY - frame.minY)
    caret.cornerRadius = CidaMotion.cursorWidth / 2
    caret.backgroundColor = CidaDesign.Palette.accent.appKit.withAlphaComponent(0.45).cgColor
    container.addSublayer(caret)
    return container
  }
}

/// What the layer says, in Cida's hint pill where the panel and the capture hint appear: the
/// screen under the pointer, the pill's top edge at the panel's (§五 提示胶囊). A failure stays
/// until it is pressed, which retries; everything else fades on its own.
final class LayerHintPanel: NSPanel {
  private let hosting = NSHostingView(rootView: LayerHint(text: ""))
  private var shownAt: Date?
  private(set) var text: String?

  init() {
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
    contentView = hosting
    setAccessibilityIdentifier("translation-layer-hint-panel")
    setAccessibilityLabel("辞达提示")
    // The pill is read as one element, like the translations, whether or not the panel is key.
    hosting.setAccessibilityElement(true)
    hosting.setAccessibilityRole(.staticText)
    hosting.setAccessibilityIdentifier("translation-layer-hint")
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
      x: floor(anchor.x - size.width / 2), y: floor(anchor.y + CidaHintPill.shadowMargin - size.height),
      width: size.width, height: size.height)
  }

  /// Shows `text` for `seconds`, or until `hide` when nil; `onPress` makes the pill a button.
  func show(_ text: String, for seconds: Double?, onPress: (() -> Void)? = nil) {
    let wasShowing = isVisible && self.text != nil
    self.text = text
    hosting.rootView = LayerHint(text: text, onPress: onPress)
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    setFrame(Self.frame(fitting: hosting.fittingSize, in: screen?.visibleFrame ?? .zero), display: true)
    ignoresMouseEvents = onPress == nil
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
private func fade(_ layer: CALayer?, from: Float, to: Float, duration: TimeInterval) {
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

/// The hint pill, pressable when it offers a retry.
struct LayerHint: View {
  let text: String
  var onPress: (() -> Void)?

  var body: some View {
    CidaHintPill(text: text)
      .onTapGesture { onPress?() }
  }
}

/// A window outlined for a moment when its translation turns on (§三): 1.5 pt accent 3 pt
/// outside the window, concentric with a macOS 26 window's corners, fading in over
/// `motion-height-ms`, holding 600 ms, fading out over 300 ms.
final class LayerOutlinePanel: NSPanel {
  /// A titled window's corner radius on macOS 26, measured in the VM; windows with a toolbar
  /// are a little rounder, which only widens the gap at their corners.
  static let windowCornerRadius: CGFloat = 16
  static let gap: CGFloat = 3
  static let lineWidth: CGFloat = 1.5

  /// A border fills the panel's edge, so its outer edge is the panel's.
  private let outline = CALayer()

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
    outline.borderColor = CidaDesign.Palette.accent.appKit.cgColor
    outline.borderWidth = Self.lineWidth
    outline.cornerRadius = Self.windowCornerRadius + Self.gap
    outline.cornerCurve = .continuous
    setAccessibilityIdentifier("translation-layer-outline")
  }

  override var canBecomeKey: Bool { false }

  /// Outlines `rect` (AppKit coordinates) just outside its edge.
  func flash(around rect: CGRect) {
    let frame = rect.insetBy(dx: -Self.gap, dy: -Self.gap)
    setFrame(frame, display: false)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    outline.frame = CGRect(origin: .zero, size: frame.size)
    CATransaction.commit()
    alphaValue = 1
    orderFrontRegardless()
    // Layer fades, for the reason `LayerHintPanel.hide` gives.
    let fadeIn = CidaMotion.resolvedDuration(CidaMotion.heightSeconds, in: self)
    let fadeOut = CidaMotion.resolvedDuration(0.3, in: self)
    outline.opacity = 0
    fade(outline, from: 0, to: 1, duration: fadeIn)
    DispatchQueue.main.asyncAfter(deadline: .now() + fadeIn + 0.6) { [weak self] in
      guard let self else { return }
      fade(outline, from: 1, to: 0, duration: fadeOut)
      DispatchQueue.main.asyncAfter(deadline: .now() + fadeOut) { [weak self] in self?.orderOut(nil) }
    }
  }
}

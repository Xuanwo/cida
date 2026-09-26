import AppKit
import QuartzCore
import SwiftUI

/// The layer's configuration over the screen under the pointer
/// (`Design/spec/translation-layer.md` §二): a live veil with every chosen pane lifted out of
/// it like the capture sheet; the paragraph and pane under the pointer are previewed. A click
/// translates that paragraph once; ⇧-click keeps translating the pane, or stops.
@MainActor
final class LayerConfiguration {
  private let controller: TranslationLayerController
  private let panel: LayerConfigurationPanel
  private let view: LayerConfigurationView
  private let screen: NSScreen
  private var working: [LayerSelection]
  /// Frames of panes chosen in this session, until the controller finds them itself.
  private var addedFrames: [UUID: CGRect] = [:]
  private var hover: LayerHover?
  private var hoverTask: Task<Void, Never>?
  private var pendingPoint: CGPoint?
  private var paneCache: (pane: AccessibilityLayerNode, blocks: [LayerBlock], read: Date)?
  private var enabledTrees: Set<pid_t> = []
  private var lastChosen: LayerApplication?
  private var finish: CheckedContinuation<Void, Never>?

  init(controller: TranslationLayerController, screen: NSScreen) {
    self.controller = controller
    self.screen = screen
    working = controller.selections
    panel = LayerConfigurationPanel(screen: screen)
    view = LayerConfigurationView(frame: NSRect(origin: .zero, size: screen.frame.size))
    panel.contentView = view
  }

  /// Shows the configuration and returns when it is finished or cancelled.
  func run() async {
    view.onMove = { [weak self] point in self?.pointerMoved(to: point) }
    view.onClick = { [weak self] extends in self?.click(extends: extends) }
    view.onFinish = { [weak self] commit in self?.close(commit: commit) }
    view.veilIsInk = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    refreshLifted()
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(view)
    view.fadeIn()
    pointerMoved(to: view.convert(panel.mouseLocationOutsideOfEventStream, from: nil))
    await withCheckedContinuation { finish = $0 }
  }

  private func close(commit: Bool) {
    hoverTask?.cancel()
    if commit {
      controller.setSelections(working)
      if let lastChosen { NSRunningApplication(processIdentifier: lastChosen.processIdentifier)?.activate() }
    }
    panel.orderOut(nil)
    finish?.resume()
    finish = nil
  }

  // MARK: Pointer

  /// Screen points, top-left origin, for a point in the view.
  private func screenPoint(_ point: CGPoint) -> CGPoint {
    let appKit = CGPoint(x: screen.frame.minX + point.x, y: screen.frame.minY + point.y)
    return LayerScreenGeometry.topLeftPoint(fromAppKit: appKit)
  }

  private func viewRect(_ rect: CGRect) -> CGRect {
    let appKit = LayerScreenGeometry.appKitRect(fromTopLeft: rect)
    return appKit.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
  }

  private func pointerMoved(to point: CGPoint) {
    pendingPoint = screenPoint(point)
    guard hoverTask == nil else { return }
    hoverTask = Task { [weak self] in
      while let self, let target = pendingPoint {
        pendingPoint = nil
        let hover = await resolveHover(at: target)
        guard !Task.isCancelled else { return }
        apply(hover)
      }
      self?.hoverTask = nil
    }
  }

  private func resolveHover(at point: CGPoint) async -> LayerHover? {
    let windows = LayerWindowInfo.onScreen()
    guard let info = LayerWindowInfo.applicationWindow(at: point, in: windows),
      let running = NSRunningApplication(processIdentifier: info.ownerPID),
      let application = LayerApplication(running)
    else {
      return nil
    }
    if !enabledTrees.contains(application.processIdentifier) {
      enabledTrees.insert(application.processIdentifier)
      application.enableAccessibilityTree()
    }
    let cached = paneCache
    let result = await Task.detached(priority: .userInitiated) { () -> LayerHover.Resolved? in
      guard let hit = application.element(at: point) else { return nil }
      guard let pane = LayerPaneRule.pane(from: hit), let paneFrame = pane.frame,
        let window = hit.window ?? pane.window, let windowFrame = window.frame
      else {
        return LayerHover.Resolved(pane: nil, paneFrame: nil, window: nil, windowFrame: info.bounds,
          blocks: [], scope: .application, readsText: LayerPaneRule.holdsText(hit.window ?? hit))
      }
      var blocks: [LayerBlock]
      if let cached, cached.pane.isSameElement(as: pane), Date().timeIntervalSince(cached.read) < 1 {
        blocks = cached.blocks
      } else {
        blocks = LayerBlockExtractor.blocks(in: pane, visible: paneFrame)
      }
      return LayerHover.Resolved(
        pane: pane, paneFrame: paneFrame, window: window, windowFrame: windowFrame, blocks: blocks,
        scope: LayerScope.of(pane), readsText: true)
    }.value
    guard let result else {
      return LayerHover(application: application, point: point, resolved: nil)
    }
    if let pane = result.pane { paneCache = (pane, result.blocks, cached?.pane.isSameElement(as: pane) == true ? cached!.read : Date()) }
    return LayerHover(application: application, point: point, resolved: result)
  }

  private func apply(_ hover: LayerHover?) {
    self.hover = hover
    guard let hover else {
      view.setPreview(pane: nil, paragraph: nil)
      view.setHint(Self.idleHint)
      return
    }
    guard let resolved = hover.resolved, let paneFrame = resolved.paneFrame else {
      view.setPreview(pane: nil, paragraph: nil)
      view.setHint(
        hover.resolved?.readsText == false
          ? "\(hover.application.name) 里读不到文字，可以用截图翻译 \(Self.captureShortcutText)"
          : "正在读取 \(hover.application.name)…")
      return
    }
    let paragraph = resolved.blocks.first { $0.frame.contains(hover.point) }
    view.setPreview(pane: viewRect(paneFrame), paragraph: paragraph.map { viewRect($0.frame) })
    let scope = resolved.scope.label(applicationName: hover.application.name)
    let isChosen = chosenSelection(for: hover) != nil
    view.setHint(
      "\(scope) · 点击：翻译这一段 · ⇧ 点击：\(isChosen ? "不再翻译这个区域" : "一直翻译这个区域") · Esc 取消")
  }

  static let idleHint = "点击：翻译这一段 · ⇧ 点击：一直翻译这个区域 · Esc 取消"
  static var captureShortcutText = GlobalShortcut.optionS.displayText

  // MARK: Choosing

  private func chosenSelection(for hover: LayerHover) -> LayerSelection? {
    guard let resolved = hover.resolved, let pane = resolved.pane else { return nil }
    return working.first {
      $0.bundleIdentifier == hover.application.bundleIdentifier && $0.scope == resolved.scope
        && $0.locator.matches(pane)
        && LayerPaneLocator(pane: pane, window: resolved.windowFrame).relativeFrame
          .insetBy(dx: -0.1, dy: -0.1).contains($0.locator.relativeFrame.origin)
    }
  }

  private func click(extends: Bool) {
    guard let hover, let resolved = hover.resolved, let pane = resolved.pane, let window = resolved.window
    else {
      NSSound.beep()
      return
    }
    if extends {
      if let chosen = chosenSelection(for: hover) {
        working.removeAll { $0.id == chosen.id }
        addedFrames[chosen.id] = nil
      } else {
        let selection = LayerSelection(
          bundleIdentifier: hover.application.bundleIdentifier,
          applicationName: hover.application.name, scope: resolved.scope,
          locator: LayerPaneLocator(pane: pane, window: resolved.windowFrame))
        working.append(selection)
        addedFrames[selection.id] = resolved.paneFrame
        bringForward(hover.application, window: window)
      }
      refreshLifted()
      apply(hover)
      return
    }
    guard let paragraph = resolved.blocks.first(where: { $0.frame.contains(hover.point) }) else {
      NSSound.beep()
      return
    }
    controller.translateOnce(paragraph: paragraph, pane: pane, window: window, application: hover.application)
    lastChosen = hover.application
    close(commit: true)
  }

  /// A chosen pane's app comes to the front and its window above the others, so a pane
  /// that was partly covered shows whole (§二). The configuration keeps the keyboard.
  private func bringForward(_ application: LayerApplication, window: AccessibilityLayerNode) {
    lastChosen = application
    NSRunningApplication(processIdentifier: application.processIdentifier)?.activate()
    window.perform(kAXRaiseAction)
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(80))
      guard let self else { return }
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(view)
    }
  }

  private func refreshLifted() {
    var frames: [CGRect] = []
    let known = controller.visibleSelectedPanes
    for selection in working {
      if let frame = addedFrames[selection.id] ?? known.first(where: { $0.selectionID == selection.id })?.frame {
        frames.append(viewRect(frame))
      }
    }
    view.setLifted(frames)
  }
}

/// What the pointer is over.
struct LayerHover {
  struct Resolved: @unchecked Sendable {
    let pane: AccessibilityLayerNode?
    let paneFrame: CGRect?
    let window: AccessibilityLayerNode?
    let windowFrame: CGRect
    let blocks: [LayerBlock]
    let scope: LayerScope
    let readsText: Bool
  }

  let application: LayerApplication
  let point: CGPoint
  let resolved: Resolved?
}

final class LayerConfigurationPanel: NSPanel {
  override var canBecomeKey: Bool { true }

  init(screen: NSScreen) {
    super.init(
      contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    setFrame(screen.frame, display: false)
    level = .screenSaver
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    animationBehavior = .none
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    acceptsMouseMovedEvents = true
    title = "翻译图层"
    setAccessibilityIdentifier("translation-layer-configuration")
    setAccessibilityLabel("翻译图层")
  }
}

/// The veil with holes for the chosen panes, their lifted edges, the dashed previews and the
/// hint pill.
final class LayerConfigurationView: NSView {
  var onMove: ((CGPoint) -> Void)?
  var onClick: ((Bool) -> Void)?
  var onFinish: ((Bool) -> Void)?
  var veilIsInk = false {
    didSet { veilLayer.fillColor = (veilIsInk ? CaptureVeil.ink : CaptureVeil.paper).color }
  }

  private let veilLayer = CAShapeLayer()
  private var liftedLayers: [CALayer] = []
  private let panePreview = CAShapeLayer()
  private let paragraphPreview = CAShapeLayer()
  private let hint: NSHostingView<LayerHint>
  private var lifted: [CGRect] = []
  private var previewPane: CGRect?
  /// Room the lifted sheet keeps around a pane's content.
  static let sheetMargin: CGFloat = 6

  override init(frame: NSRect) {
    hint = NSHostingView(rootView: LayerHint(text: LayerConfiguration.idleHint))
    super.init(frame: frame)
    wantsLayer = true
    veilLayer.fillRule = .evenOdd
    veilLayer.fillColor = CaptureVeil.paper.color
    layer?.addSublayer(veilLayer)
    for preview in [panePreview, paragraphPreview] {
      preview.fillColor = nil
      preview.strokeColor = CidaDesign.Palette.accent.appKit.cgColor
      preview.lineWidth = 1.5
      layer?.addSublayer(preview)
    }
    panePreview.lineDashPattern = [5, 4]
    paragraphPreview.lineDashPattern = [3, 3]
    paragraphPreview.fillColor = CidaDesign.Palette.accentSoft.appKit.withAlphaComponent(0.35).cgColor
    addSubview(hint)
    hint.wantsLayer = true
    hint.layer?.zPosition = 10
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("translation-layer-canvas")
    setAccessibilityLabel(LayerConfiguration.idleHint)
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

  override func layout() {
    super.layout()
    let size = hint.fittingSize
    let pillTop = bounds.height * (1 - CidaDesign.Panel.topRatio)
    hint.frame = NSRect(
      x: floor((bounds.width - size.width) / 2),
      y: floor(pillTop + LayerHint.shadowMargin - size.height), width: size.width, height: size.height)
    updateVeil()
  }

  func fadeIn() {
    let duration = CidaMotion.resolvedDuration(CidaMotion.iconInSeconds, in: window)
    guard duration > 0 else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = duration
    fade.timingFunction = CidaMotion.easeOut
    layer?.add(fade, forKey: "fade-in")
  }

  func setHint(_ text: String) {
    hint.rootView = LayerHint(text: text)
    setAccessibilityLabel(text)
    needsLayout = true
  }

  func setLifted(_ frames: [CGRect]) {
    lifted = frames.map { $0.insetBy(dx: -Self.sheetMargin, dy: -Self.sheetMargin) }
    liftedLayers.forEach { $0.removeFromSuperlayer() }
    liftedLayers = lifted.flatMap(makeLiftedLayers)
    for sheet in liftedLayers { layer?.insertSublayer(sheet, above: veilLayer) }
    updateVeil()
  }

  func setPreview(pane: CGRect?, paragraph: CGRect?) {
    previewPane = pane.map { $0.insetBy(dx: -Self.sheetMargin, dy: -Self.sheetMargin) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    panePreview.path = previewPane.map {
      CGPath(roundedRect: $0, cornerWidth: CidaDesign.Radius.card, cornerHeight: CidaDesign.Radius.card, transform: nil)
    }
    paragraphPreview.path = paragraph.map {
      CGPath(roundedRect: $0.insetBy(dx: -4, dy: -2), cornerWidth: 4, cornerHeight: 4, transform: nil)
    }
    CATransaction.commit()
    updateVeil()
  }

  /// The veil covers the screen except the chosen panes and the pane under the pointer.
  private func updateVeil() {
    let path = CGMutablePath()
    path.addRect(bounds)
    for hole in lifted + (previewPane.map { [$0] } ?? []) {
      path.addRoundedRect(in: hole, cornerWidth: CidaDesign.Radius.card, cornerHeight: CidaDesign.Radius.card)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    veilLayer.frame = bounds
    veilLayer.path = path
    CATransaction.commit()
  }

  /// The capture sheet's edge and two shadows, around an empty middle.
  private func makeLiftedLayers(_ frame: CGRect) -> [CALayer] {
    let edge = CAShapeLayer()
    let rounded = CGPath(
      roundedRect: frame, cornerWidth: CidaDesign.Radius.card, cornerHeight: CidaDesign.Radius.card,
      transform: nil)
    edge.path = rounded
    edge.fillColor = nil
    edge.strokeColor = (veilIsInk ? CaptureVeil.ink : CaptureVeil.paper).sheetEdge
    edge.lineWidth = 1
    guard !veilIsInk else { return [edge] }
    let shadows: [(Float, CGFloat, CGFloat)] = [(Float(0x14) / 255, -2, 3), (Float(0x30) / 255, -28, 36)]
    let shadowLayers: [CALayer] = shadows.map { opacity, offset, radius in
      let shadow = CALayer()
      shadow.frame = bounds
      shadow.shadowPath = rounded
      shadow.shadowColor = CidaDesign.Palette.textPrimary.appKit.cgColor
      shadow.shadowOpacity = opacity
      shadow.shadowOffset = CGSize(width: 0, height: offset)
      shadow.shadowRadius = radius
      // Only the shadow outside the sheet shows; the pane stays clear.
      let mask = CAShapeLayer()
      let outside = CGMutablePath()
      outside.addRect(bounds)
      outside.addPath(rounded)
      mask.path = outside
      mask.fillRule = .evenOdd
      shadow.mask = mask
      return shadow
    }
    return shadowLayers + [edge]
  }

  override func mouseMoved(with event: NSEvent) {
    onMove?(convert(event.locationInWindow, from: nil))
  }

  override func mouseDown(with event: NSEvent) {
    onMove?(convert(event.locationInWindow, from: nil))
    onClick?(event.modifierFlags.contains(.shift))
  }

  override func rightMouseDown(with event: NSEvent) { onFinish?(false) }

  override func keyDown(with event: NSEvent) {
    switch Int(event.keyCode) {
    case 53: onFinish?(false)
    case 36, 76: onFinish?(true)
    default: super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) { onFinish?(false) }
}

/// The capture hint's pill with the layer's words.
struct LayerHint: View {
  static let shadowMargin: CGFloat = 40
  let text: String

  var body: some View {
    HStack(spacing: 12) {
      CidaWordmark()
      Text(text)
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
    .accessibilityIdentifier("translation-layer-hint")
  }
}

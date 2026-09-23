import AppKit
import SwiftUI

struct CidaScrollIndicatorConfiguration: Equatable, Sendable {
  let accessibilityIdentifier: String
  let knobLength: CGFloat
  let trackTopInset: CGFloat
  let trackBottomInset: CGFloat
  let minimumScrollableOverflow: CGFloat
  /// How far past the scroll view's right edge the indicator sits, so a
  /// scroll view inset inside its pane can still hug the pane's edge.
  var trailingOutset: CGFloat = 0

  static let result = CidaScrollIndicatorConfiguration(
    accessibilityIdentifier: "result-scroll-indicator",
    knobLength: 90,
    trackTopInset: 10,
    trackBottomInset: 12,
    minimumScrollableOverflow: 1.5,
    trailingOutset: CidaDesign.Spacing.windowHorizontal
  )

  static let composer = CidaScrollIndicatorConfiguration(
    accessibilityIdentifier: "composer-scroll-indicator",
    knobLength: 64,
    trackTopInset: 0,
    trackBottomInset: 0,
    minimumScrollableOverflow: 1
  )

}

@MainActor
final class CidaScrollIndicator: NSView {
  static let knobWidth: CGFloat = 4
  static let trailingInset: CGFloat = 4
  static let interactionWidth: CGFloat = 12
  static let knobColor = NSColor(calibratedWhite: 0, alpha: 38 / 255)
  static let isCompatibleWithOverlayScrollers = false

  let configuration: CidaScrollIndicatorConfiguration
  private let knobLayer = CALayer()
  private(set) weak var observedScrollView: NSScrollView?
  private(set) var doubleValue = 0.0
  let scrollerStyle = NSScroller.Style.legacy
  private var visibilityEnabled = true
  private var forceVisible = false
  private var normalizedValue = 0.0
  private var activePart = NSScroller.Part.noPart
  private var knobDragOffset: CGFloat = 0
  private var isGeometryRefreshScheduled = false
  private var isPostScrollSuppressionScheduled = false
  private var lastPositionChangeTimestamp = 0.0
  private var lastVisibleOriginY: CGFloat?
  private var lastVisibleHeight: CGFloat?
  private var lastDocumentHeight: CGFloat?

  override var isFlipped: Bool { true }

  var knobDrawingRect: NSRect {
    rect(for: .knob)
  }

  init(configuration: CidaScrollIndicatorConfiguration) {
    self.configuration = configuration
    super.init(frame: .zero)
    focusRingType = .none
    wantsLayer = true
    knobLayer.backgroundColor = Self.knobColor.cgColor
    knobLayer.cornerRadius = Self.knobWidth / 2
    knobLayer.actions = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
    ]
    layer?.addSublayer(knobLayer)
    setAccessibilityRole(.scrollBar)
    setAccessibilityIdentifier(configuration.accessibilityIdentifier)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @discardableResult
  static func install(
    on scrollView: NSScrollView,
    configuration: CidaScrollIndicatorConfiguration
  ) -> CidaScrollIndicator {
    suppressSystemVerticalScroller(on: scrollView)
    if let existingHost = scrollView.subviews.compactMap({
      $0 as? CidaScrollIndicatorHostView
    }).first {
      if existingHost.indicator.configuration == configuration {
        return existingHost.indicator
      }
      existingHost.removeFromSuperview()
    }

    let indicator = CidaScrollIndicator(configuration: configuration)
    let host = CidaScrollIndicatorHostView(indicator: indicator)
    host.autoresizingMask = [.minXMargin, .height]
    scrollView.addSubview(host, positioned: .above, relativeTo: nil)
    host.attach(to: scrollView)
    return indicator
  }

  static func installed(in scrollView: NSScrollView) -> CidaScrollIndicator? {
    scrollView.subviews.compactMap { $0 as? CidaScrollIndicatorHostView }.first?.indicator
  }

  func setVisibilityEnabled(_ enabled: Bool) {
    guard visibilityEnabled != enabled else { return }
    visibilityEnabled = enabled
  }

  func setForceVisible(_ visible: Bool) {
    guard forceVisible != visible else { return }
    forceVisible = visible
  }

  func refresh() {
    if let observedScrollView {
      Self.suppressSystemVerticalScroller(on: observedScrollView)
    }
    updateFrame()
    synchronizeFromScrollView()
  }

  func scroll(toNormalizedValue value: Double) {
    doubleValue = min(1, max(0, value))
    scrollDocument(toNormalizedValue: doubleValue)
  }

  func rect(for part: NSScroller.Part) -> NSRect {
    let trackRect = NSRect(
      x: bounds.maxX - Self.trailingInset - Self.knobWidth,
      y: configuration.trackBottomInset,
      width: Self.knobWidth,
      height: max(
        0,
        bounds.height - configuration.trackTopInset - configuration.trackBottomInset
      )
    )
    let knobHeight = min(trackRect.height, configuration.knobLength)
    let travel = max(0, trackRect.height - knobHeight)
    let knobRect = NSRect(
      x: trackRect.minX,
      y: trackRect.minY + travel * CGFloat(normalizedValue),
      width: trackRect.width,
      height: knobHeight
    )

    switch part {
    case .knob:
      return knobRect
    case .knobSlot:
      return trackRect
    case .decrementPage:
      return NSRect(
        x: bounds.minX,
        y: trackRect.minY,
        width: bounds.width,
        height: max(0, knobRect.minY - trackRect.minY)
      )
    case .incrementPage:
      return NSRect(
        x: bounds.minX,
        y: knobRect.maxY,
        width: bounds.width,
        height: max(0, trackRect.maxY - knobRect.maxY)
      )
    case .decrementLine, .incrementLine, .noPart:
      return .zero
    @unknown default:
      return .zero
    }
  }

  override func layout() {
    super.layout()
    updateKnobLayer()
  }

  func testPart(_ point: NSPoint) -> NSScroller.Part {
    guard !isHidden else { return .noPart }
    let knobRect = rect(for: .knob)
    if point.y >= knobRect.minY, point.y <= knobRect.maxY {
      return .knob
    }
    return point.y < knobRect.minY ? .decrementPage : .incrementPage
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    guard let scrollView = observedScrollView else { return }
    let point = convert(event.locationInWindow, from: nil)
    activePart = testPart(point)
    switch activePart {
    case .knob:
      knobDragOffset = point.y - knobDrawingRect.minY
    case .decrementPage:
      scrollDocument(by: -scrollView.contentView.documentVisibleRect.height)
    case .incrementPage:
      scrollDocument(by: scrollView.contentView.documentVisibleRect.height)
    case .decrementLine, .incrementLine, .knobSlot, .noPart:
      break
    @unknown default:
      break
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard activePart == .knob else { return }
    let trackRect = rect(for: .knobSlot)
    let knobRect = rect(for: .knob)
    let travel = max(0, trackRect.height - knobRect.height)
    guard travel > 0 else { return }
    let point = convert(event.locationInWindow, from: nil)
    let knobOriginY = min(
      trackRect.maxY - knobRect.height,
      max(trackRect.minY, point.y - knobDragOffset)
    )
    scrollDocument(
      toNormalizedValue: Double((knobOriginY - trackRect.minY) / travel)
    )
  }

  override func mouseUp(with event: NSEvent) {
    activePart = .noPart
  }

  fileprivate func attach(to scrollView: NSScrollView) {
    guard observedScrollView !== scrollView else {
      updateFrame()
      synchronizeFromScrollView()
      return
    }

    NotificationCenter.default.removeObserver(self)
    observedScrollView = scrollView
    let clipView = scrollView.contentView
    clipView.postsBoundsChangedNotifications = true
    scrollView.postsFrameChangedNotifications = true
    scrollView.documentView?.postsFrameChangedNotifications = true

    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(scrollPositionDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: clipView
    )
    center.addObserver(
      self,
      selector: #selector(scrollViewFrameDidChange(_:)),
      name: NSView.frameDidChangeNotification,
      object: scrollView
    )
    if let documentView = scrollView.documentView {
      center.addObserver(
        self,
        selector: #selector(documentGeometryDidChange(_:)),
        name: NSView.frameDidChangeNotification,
        object: documentView
      )
    }
    center.addObserver(
      self,
      selector: #selector(scrollPositionDidChange(_:)),
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )
    center.addObserver(
      self,
      selector: #selector(scrollingDidEnd(_:)),
      name: NSScrollView.didEndLiveScrollNotification,
      object: scrollView
    )

    updateFrame()
    synchronizeFromScrollView()
  }

  @objc
  private func scrollPositionDidChange(_ notification: Notification) {
    suppressReinstalledSystemScroller()
    lastPositionChangeTimestamp = ProcessInfo.processInfo.systemUptime
    synchronizeFromScrollView(committingControlValue: false)
  }

  @objc
  private func documentGeometryDidChange(_ notification: Notification) {
    guard ProcessInfo.processInfo.systemUptime - lastPositionChangeTimestamp >= 0.05 else { return }
    synchronizeFromScrollView(committingControlValue: false)
  }

  @objc
  private func scrollingDidEnd(_ notification: Notification) {
    suppressReinstalledSystemScroller()
    synchronizeFromScrollView()
  }

  @objc
  private func scrollViewFrameDidChange(_ notification: Notification) {
    scheduleGeometryRefresh()
  }

  private func scheduleGeometryRefresh() {
    guard !isGeometryRefreshScheduled else { return }
    isGeometryRefreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.isGeometryRefreshScheduled = false
      self.refresh()
    }
  }

  private func suppressReinstalledSystemScroller() {
    guard let scrollView = observedScrollView else { return }
    Self.suppressSystemVerticalScroller(on: scrollView)

    // SwiftUI may restore its overlay scroller after delivering the bounds or
    // live-scroll notification. Recheck on the next main-run-loop turn so the
    // native thumb never survives beside the Pencil indicator.
    guard !isPostScrollSuppressionScheduled else { return }
    isPostScrollSuppressionScheduled = true
    DispatchQueue.main.async { [weak self, weak scrollView] in
      guard let self else { return }
      self.isPostScrollSuppressionScheduled = false
      guard let scrollView else { return }
      Self.suppressSystemVerticalScroller(on: scrollView)
    }
  }

  @discardableResult
  private static func suppressSystemVerticalScroller(on scrollView: NSScrollView) -> Bool {
    let needsSuppression =
      scrollView.hasVerticalScroller
      || scrollView.verticalScroller != nil
    guard needsSuppression else { return false }

    scrollView.verticalScroller = nil
    scrollView.hasVerticalScroller = false
    scrollView.tile()
    scrollView.needsDisplay = true
    return true
  }

  private func updateFrame() {
    guard let scrollView = observedScrollView else { return }
    if let host = superview as? CidaScrollIndicatorHostView {
      host.updateFrame(in: scrollView)
      frame = host.bounds
    }
  }

  private func synchronizeFromScrollView(committingControlValue: Bool = true) {
    guard
      visibilityEnabled,
      let scrollView = observedScrollView,
      let documentView = scrollView.documentView
    else {
      if !isHidden { isHidden = true }
      return
    }

    let visibleRect = scrollView.contentView.documentVisibleRect
    let documentBounds = documentView.bounds
    if !committingControlValue,
      lastVisibleOriginY == visibleRect.minY,
      lastVisibleHeight == visibleRect.height,
      lastDocumentHeight == documentBounds.height
    {
      return
    }
    lastVisibleOriginY = visibleRect.minY
    lastVisibleHeight = visibleRect.height
    lastDocumentHeight = documentBounds.height
    let scrollableHeight = max(0, documentBounds.height - visibleRect.height)
    let isScrollable = scrollableHeight > configuration.minimumScrollableOverflow
    guard isScrollable || forceVisible else {
      if !isHidden { isHidden = true }
      return
    }

    if isHidden { isHidden = false }
    let nextValue: Double
    if isScrollable {
      let offset =
        documentView.isFlipped
        ? visibleRect.minY - documentBounds.minY
        : documentBounds.maxY - visibleRect.maxY
      nextValue = min(1, max(0, offset / scrollableHeight))
    } else {
      nextValue = 0
    }
    normalizedValue = nextValue
    if committingControlValue, abs(doubleValue - nextValue) > 0.000_001 {
      doubleValue = nextValue
    }
    setAccessibilityValue(nextValue)
    updateKnobLayer()
  }

  private func updateKnobLayer() {
    let nextFrame = knobDrawingRect
    guard knobLayer.frame != nextFrame else { return }
    knobLayer.frame = nextFrame
  }

  private func scrollDocument(toNormalizedValue value: Double) {
    guard
      let scrollView = observedScrollView,
      let documentView = scrollView.documentView
    else { return }
    let clipView = scrollView.contentView
    let visibleRect = clipView.documentVisibleRect
    let documentBounds = documentView.bounds
    let scrollableHeight = max(0, documentBounds.height - visibleRect.height)
    guard scrollableHeight > 0.5 else {
      synchronizeFromScrollView()
      return
    }
    let normalizedValue = min(1, max(0, value))
    self.normalizedValue = normalizedValue
    if abs(doubleValue - normalizedValue) > 0.000_001 {
      doubleValue = normalizedValue
    }
    setAccessibilityValue(normalizedValue)
    let originY =
      documentView.isFlipped
      ? documentBounds.minY + scrollableHeight * normalizedValue
      : documentBounds.maxY - visibleRect.height - scrollableHeight * normalizedValue
    clipView.scroll(to: NSPoint(x: visibleRect.minX, y: originY))
    scrollView.reflectScrolledClipView(clipView)
    synchronizeFromScrollView()
  }

  private func scrollDocument(by delta: CGFloat) {
    guard let scrollView = observedScrollView, let documentView = scrollView.documentView else {
      return
    }
    let clipView = scrollView.contentView
    let visibleRect = clipView.documentVisibleRect
    let signedDelta = documentView.isFlipped ? delta : -delta
    clipView.scroll(to: NSPoint(x: visibleRect.minX, y: visibleRect.minY + signedDelta))
    scrollView.reflectScrolledClipView(clipView)
    synchronizeFromScrollView()
  }
}

@MainActor
private final class CidaScrollIndicatorHostView: NSView {
  let indicator: CidaScrollIndicator

  init(indicator: CidaScrollIndicator) {
    self.indicator = indicator
    super.init(frame: .zero)
    addSubview(indicator)
    indicator.autoresizingMask = [.width, .height]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func attach(to scrollView: NSScrollView) {
    updateFrame(in: scrollView)
    indicator.frame = bounds
    indicator.attach(to: scrollView)
  }

  func updateFrame(in scrollView: NSScrollView) {
    frame = NSRect(
      x: scrollView.bounds.maxX + indicator.configuration.trailingOutset
        - CidaScrollIndicator.interactionWidth,
      y: scrollView.bounds.minY,
      width: CidaScrollIndicator.interactionWidth,
      height: scrollView.bounds.height
    )
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point), !indicator.isHidden else { return nil }
    return indicator
  }
}

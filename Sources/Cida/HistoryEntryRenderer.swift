import AppKit
import QuartzCore

@MainActor
/// One record action icon. The glyph is painted only by `iconView`. The
/// NSButton cell still holds the described template image because the native
/// accessibility audit takes a button's description from its image, but the
/// cell never draws: even with `imagePosition = .noImage` it would paint a
/// second copy of the image without the icon view's alignment, leaving blocky
/// strokes and a mark in each corner over the crisp glyph.
class HistoryEntryActionButton: NSButton {
  private static let revealAnimationKey = "history-action-reveal"
  private static let concealAnimationKey = "history-action-conceal"
  private let iconView = NSImageView()

  var iconImage: NSImage? {
    didSet { iconView.image = iconImage }
  }

  var normalTintColor = NSColor.secondaryLabelColor {
    didSet { updateTintColor() }
  }
  var hoverTintColor = NSColor.labelColor {
    didSet { updateTintColor() }
  }

  private var trackingAreaReference: NSTrackingArea?
  private var isHovering = false
  private var usesFeedbackTint = false
  private var feedbackTintColor = NSColor.controlAccentColor

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureIconView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  #if DEBUG
    var revealAnimationForTesting: CABasicAnimation? {
      layer?.animation(forKey: Self.revealAnimationKey) as? CABasicAnimation
    }
    private(set) weak var concealGhostLayerForTesting: CALayer?
    var concealAnimationForTesting: CABasicAnimation? {
      concealGhostLayerForTesting?.animation(forKey: Self.concealAnimationKey) as? CABasicAnimation
    }
    var iconSwapTransitionForTesting: CATransition? {
      iconView.layer?.animation(forKey: kCATransition) as? CATransition
    }
  #endif

  override func layout() {
    super.layout()
    iconView.frame = bounds
  }

  /// The cell must not paint; see the class note.
  override func draw(_ dirtyRect: NSRect) {}

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, isEnabled, bounds.contains(point) else { return nil }
    return self
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaReference {
      removeTrackingArea(trackingAreaReference)
    }
    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    trackingAreaReference = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    setHovering(true)
  }

  override func mouseExited(with event: NSEvent) {
    setHovering(false)
  }

  override func accessibilityPerformPress() -> Bool {
    guard isEnabled, !isHidden else { return false }
    performClick(nil)
    return true
  }

  /// Shows the icon with the Pencil fade-in. A hidden icon is fully hidden at
  /// rest, so the reveal always starts from transparent.
  func reveal(duration: TimeInterval) {
    guard isHidden else { return }
    isHidden = false
    layer?.removeAnimation(forKey: Self.revealAnimationKey)
    alphaValue = 1
    let resolved = CidaMotion.resolvedDuration(duration, in: window)
    guard resolved > 0, let layer else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = resolved
    fade.timingFunction = CidaMotion.easeOut
    layer.add(fade, forKey: Self.revealAnimationKey)
  }

  /// Hides the icon at once. Hit-testing, accessibility, and presentation
  /// state read `isHidden`, so nothing lingers.
  func conceal() {
    guard !isHidden else { return }
    layer?.removeAnimation(forKey: Self.revealAnimationKey)
    isHidden = true
    alphaValue = 1
  }

  /// Hides the icon with the Pencil fade reversed. The button hides at once so
  /// its state stays exact; a detached snapshot layer in the superview carries
  /// the visual fade-out and removes itself when it ends.
  func conceal(duration: TimeInterval) {
    guard !isHidden else { return }
    let resolved = CidaMotion.resolvedDuration(duration, in: window)
    if resolved > 0, let ghost = makeGhostLayer(), let hostLayer = superview?.layer {
      ghost.frame = frame
      hostLayer.addSublayer(ghost)
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = layer?.presentation()?.opacity ?? 1
      fade.toValue = 0
      fade.duration = resolved
      fade.timingFunction = CidaMotion.easeOut
      CATransaction.begin()
      CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
      ghost.add(fade, forKey: Self.concealAnimationKey)
      CATransaction.commit()
      #if DEBUG
        concealGhostLayerForTesting = ghost
      #endif
    }
    conceal()
  }

  /// Replaces the glyph, crossfading over the Pencil icon-swap duration when
  /// the icon is visible and actually changes, e.g. copy → ✓ and back.
  func showIcon(_ image: NSImage?, feedbackTint: NSColor?, swapDuration: TimeInterval) {
    let changesGlyph = image !== iconImage
    let resolved = isHidden || !changesGlyph ? 0 : CidaMotion.resolvedDuration(swapDuration, in: window)
    if resolved > 0, let iconLayer = iconView.layer {
      let transition = CATransition()
      transition.type = .fade
      transition.duration = resolved
      transition.timingFunction = CidaMotion.easeOut
      iconLayer.add(transition, forKey: kCATransition)
    }
    iconImage = image
    setFeedbackTint(feedbackTint)
  }

  private func makeGhostLayer() -> CALayer? {
    guard bounds.width > 0, bounds.height > 0,
      let representation = bitmapImageRepForCachingDisplay(in: bounds)
    else { return nil }
    cacheDisplay(in: bounds, to: representation)
    guard let image = representation.cgImage else { return nil }
    let ghost = CALayer()
    ghost.contents = image
    ghost.contentsScale = layer?.contentsScale ?? 1
    ghost.opacity = 0
    ghost.actions = ["opacity": NSNull(), "contents": NSNull()]
    return ghost
  }

  func setFeedbackTint(_ color: NSColor?) {
    usesFeedbackTint = color != nil
    if let color {
      feedbackTintColor = color
    }
    updateTintColor()
  }

  func resetHoverState() {
    setHovering(false)
  }

  /// Re-reads hover from the pointer. Tracking areas report no exit for a
  /// button that hides under the pointer and no entry for one that appears
  /// under it, so visibility changes re-evaluate the real position.
  func refreshHoverState() {
    guard !isHidden, let window else {
      setHovering(false)
      return
    }
    let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    setHovering(bounds.contains(pointer))
  }

  private func setHovering(_ hovering: Bool) {
    guard isHovering != hovering else { return }
    isHovering = hovering
    updateTintColor()
  }

  private func updateTintColor() {
    let tintColor =
      usesFeedbackTint
      ? feedbackTintColor
      : (isHovering ? hoverTintColor : normalTintColor)
    contentTintColor = tintColor
    iconView.contentTintColor = tintColor
  }

  private func configureIconView() {
    title = ""
    image = nil
    isBordered = false
    imagePosition = .noImage
    focusRingType = .none
    wantsLayer = true
    layer?.masksToBounds = true

    iconView.imageScaling = .scaleProportionallyDown
    iconView.imageAlignment = .alignCenter
    iconView.setAccessibilityElement(false)
    iconView.wantsLayer = true
    iconView.layer?.masksToBounds = true
    addSubview(iconView)
    updateTintColor()
  }
}

private final class HistorySourceTextField: NSTextField, @unchecked Sendable {
  nonisolated override func accessibilityFrame() -> NSRect {
    let currentField = self
    return MainActor.assumeIsolated {
      guard let window = currentField.window else { return .zero }
      return window.convertToScreen(currentField.convert(currentField.bounds, to: nil))
    }
  }
}

private final class HistoryEntryAccessibilityElement: NSAccessibilityElement,
  @unchecked Sendable
{
  enum Region: Sendable {
    case entry
    case preview
  }

  weak var owner: HistoryEntryNSView?
  var region = Region.entry

  nonisolated override func accessibilityParent() -> Any? {
    owner
  }

  nonisolated override func accessibilityFrame() -> NSRect {
    let currentOwner = owner
    let currentRegion = region
    return MainActor.assumeIsolated {
      currentOwner?.accessibilityFrame(for: currentRegion) ?? .zero
    }
  }

  nonisolated override func accessibilityPerformPress() -> Bool {
    let currentOwner = owner
    let currentRegion = region
    return MainActor.assumeIsolated {
      guard currentRegion == .entry else { return false }
      return currentOwner?.accessibilityPerformPress() ?? false
    }
  }
}

/// Draws a historical record's result at rest with the same TextKit attributes
/// as the expanded result, so folding never changes glyph placement or line
/// height. Up to two lines show in full; a longer result is clipped under the
/// Pencil fade at the bottom of the view.
@MainActor
final class FoldedPreviewTextView: NSView {
  private static let disabledLayerActions: [String: CAAction] = [
    "bounds": NSNull(),
    "hidden": NSNull(),
    "position": NSNull(),
    "sublayers": NSNull(),
  ]

  private let textStorage = NSTextStorage()
  private let layoutManager = NSLayoutManager()
  private let textContainer: NSTextContainer
  let fadeLayer = CAGradientLayer()

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    textContainer = NSTextContainer(
      containerSize: NSSize(width: max(1, frameRect.width), height: .greatestFiniteMagnitude)
    )
    textContainer.lineFragmentPadding = 0
    layoutManager.allowsNonContiguousLayout = true
    layoutManager.backgroundLayoutEnabled = false
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.masksToBounds = true
    fadeLayer.actions = Self.disabledLayerActions
    fadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
    fadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
    fadeLayer.locations = [0, 1]
    layer?.addSublayer(fadeLayer)
    setAccessibilityElement(false)
    setFadeColor(CidaDesign.Palette.background.appKit, animated: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  var text: String {
    textStorage.string
  }

  func setText(_ text: String) {
    guard textStorage.string != text else { return }
    textStorage.setAttributedString(
      NSAttributedString(string: text, attributes: HistoryResultTextStyle.attributes)
    )
    needsDisplay = true
  }

  func setTextWidth(_ width: CGFloat) {
    let resolvedWidth = max(1, width)
    guard abs(textContainer.size.width - resolvedWidth) > 0.5 else { return }
    textContainer.size = NSSize(width: resolvedWidth, height: .greatestFiniteMagnitude)
    layoutManager.invalidateLayout(
      forCharacterRange: NSRange(location: 0, length: textStorage.length),
      actualCharacterRange: nil
    )
    needsDisplay = true
  }

  /// Natural height of the whole preview text at the current width. Previews
  /// are bounded, so this stays cheap.
  var naturalTextHeight: CGFloat {
    guard textStorage.length > 0 else { return HistoryEntryPencilLayout.resultLineHeight }
    layoutManager.ensureLayout(for: textContainer)
    return ceil(layoutManager.usedRect(for: textContainer).height)
  }

  var naturalLineCount: Int {
    max(1, Int((naturalTextHeight / HistoryEntryPencilLayout.resultLineHeight).rounded(.up)))
  }

  func setFadeColor(_ color: NSColor, animated: Bool) {
    CATransaction.begin()
    if animated {
      CATransaction.setAnimationDuration(CidaMotion.iconInSeconds)
      CATransaction.setAnimationTimingFunction(CidaMotion.easeOut)
    } else {
      CATransaction.setDisableActions(true)
    }
    fadeLayer.colors = [color.withAlphaComponent(0).cgColor, color.cgColor]
    CATransaction.commit()
  }

  func setFadeOpacity(_ opacity: Float, duration: TimeInterval) {
    let from = fadeLayer.presentation()?.opacity ?? fadeLayer.opacity
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fadeLayer.removeAnimation(forKey: "fade-opacity")
    fadeLayer.opacity = opacity
    CATransaction.commit()
    guard duration > 0 else { return }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = from
    animation.toValue = opacity
    animation.duration = duration
    animation.timingFunction = CidaMotion.easeOut
    fadeLayer.add(animation, forKey: "fade-opacity")
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fadeLayer.frame = NSRect(
      x: 0,
      y: max(0, bounds.height - HistoryEntryPencilLayout.foldedPreviewFadeHeight),
      width: bounds.width,
      height: HistoryEntryPencilLayout.foldedPreviewFadeHeight
    )
    CATransaction.commit()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard textStorage.length > 0 else { return }
    let glyphRange = layoutManager.glyphRange(forBoundingRect: dirtyRect, in: textContainer)
    guard glyphRange.length > 0 else { return }
    layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
    layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
  }
}

@MainActor
final class HistoryEntryNSView: NSControl, HistoryResultHeightChangeHosting {
  private enum Layout {
    static let verticalPadding = HistoryEntryPencilLayout.verticalPadding
    static let headerHeight = HistoryEntryPencilLayout.headerHeight
    static let contentSpacing = HistoryEntryPencilLayout.contentSpacing
    static let previewHeight = HistoryEntryPencilLayout.foldedPreviewHeight
    static let actionSize = HistoryEntryPencilLayout.actionIconSize
    static let actionGap = HistoryEntryPencilLayout.actionGap
    static let actionColumnWidth = HistoryEntryPencilLayout.actionColumnWidth
    static let sourceLineHeight = HistoryEntryPencilLayout.latestSourceLineHeight
    static let sourceMaximumHeight = HistoryEntryPencilLayout.latestSourcePreviewHeight
    static let sourceFadeHeight = HistoryEntryPencilLayout.latestSourceFadeHeight
    static let separatorHeight = HistoryEntryPencilLayout.separatorHeight
    static let hoverBleed = HistoryEntryPencilLayout.hoverBleed
    static let iconOffset: CGFloat = 2
    static let modeOffset: CGFloat = 18
    static let metadataGap: CGFloat = 6
    static let actionRowOffset: CGFloat = 4
    static let contentTop = verticalPadding + headerHeight + contentSpacing
  }

  private struct SourcePresentationLayout {
    static let hidden = SourcePresentationLayout(height: 0, usesFade: false)

    let height: CGFloat
    let usesFade: Bool
  }

  /// Every frame the entry lays out for one presentation, in the entry's own
  /// flipped coordinate space.
  private struct PresentationGeometry {
    var icon: NSRect
    var mode: NSRect
    var metadata: NSRect
    var source: NSRect
    var sourceUsesFade: Bool
    var sourceAlpha: CGFloat
    var preview: NSRect
    var previewUsesFade: Bool
    var result: NSRect
    var redo: NSRect
    var chevron: NSRect
    var copyResult: NSRect
    var copySource: NSRect
  }

  private struct PresentationTransition {
    let target: HistoryPresentation
    let completion: DispatchWorkItem
  }

  private static let accentColor = CidaDesign.Palette.accent.appKit
  private static let backgroundColor = CidaDesign.Palette.background.appKit
  private static let hoverHighlightColor = CidaDesign.Palette.surfaceFold.appKit
  private static let tertiaryTextColor = CidaDesign.Palette.textTertiary.appKit
  private static let secondaryTextColor = CidaDesign.Palette.textSecondary.appKit
  private static let borderColor = CidaDesign.Palette.border.appKit
  private static let disabledLayerActions: [String: CAAction] = [
    "bounds": NSNull(),
    "contents": NSNull(),
    "hidden": NSNull(),
    "position": NSNull(),
    "sublayers": NSNull(),
  ]
  private static let modeFont =
    NSFont(name: "Inter-SemiBold", size: 11)
    ?? NSFont.systemFont(ofSize: 11, weight: .semibold)
  private static let metadataFont =
    NSFont(name: "Inter-Regular", size: 11)
    ?? NSFont.systemFont(ofSize: 11, weight: .regular)
  private let hoverHighlightLayer = CALayer()
  private let iconView = NSImageView()
  private let modeTextLayer = CATextLayer()
  private let metadataTextLayer = CATextLayer()
  private let previewView = FoldedPreviewTextView(frame: .zero)
  private let sourceTextField = HistorySourceTextField(frame: .zero)
  private let sourceFadeLayer = CAGradientLayer()
  private let separatorLayer = CALayer()
  private lazy var expandAccessibilityElement: HistoryEntryAccessibilityElement = {
    let element = HistoryEntryAccessibilityElement()
    element.owner = self
    element.region = .entry
    element.setAccessibilityRole(.button)
    element.setAccessibilityLabel("展开历史记录")
    element.setAccessibilityHelp("显示完整结果")
    return element
  }()
  private lazy var previewAccessibilityElement: HistoryEntryAccessibilityElement = {
    let element = HistoryEntryAccessibilityElement()
    element.owner = self
    element.region = .preview
    return element
  }()
  private var trackingAreaReference: NSTrackingArea?
  private weak var observedClipView: NSClipView?
  private var redoButton: HistoryEntryActionButton?
  private var copyButton: HistoryEntryActionButton?
  private var copySourceButton: HistoryEntryActionButton?
  private var chevronButton: HistoryEntryActionButton?
  private var stickyResultActionView: StickyHistoryResultActionNSView?
  private var hoverTrackingView: HistoryEntryHoverTrackingNSView?
  private var resultContainer: HistoryResultTextContainer?
  private var resultCoordinator: HistoryResultTextCoordinator?
  private var copyResetWorkItem: DispatchWorkItem?
  private var sourceCopyResetWorkItem: DispatchWorkItem?
  private var resultCopyResetWorkItem: DispatchWorkItem?
  private var transition: PresentationTransition?
  private var entryID = UUID()
  private var mode = ProcessingMode.translate
  private var metadata = ""
  private var preview = ""
  private var displayedSource = ""
  private var resultStorage: HistoryResultStorage?
  private var resultPresentationRevision = 0
  private var latestPresentationDelta: String?
  private var isLongEntry = false
  private var showsSeparator = false
  private var entryState = HistoryEntryState.completed
  private(set) var presentation = HistoryPresentation.folded
  private var isHovering = false
  private var isSourceCopied = false
  private var isResultCopied = false
  private var isPresentationActive = true
  private var isHoverManagedExternally = false
  private var pendingActionRevealDuration = CidaMotion.iconInSeconds
  private var modeAttributedString = NSAttributedString()
  private var metadataAttributedString = NSAttributedString()
  private var measuredSourceWidth: CGFloat?
  private var measuredSourceLayout = SourcePresentationLayout.hidden
  private var onExpand: (@MainActor () -> Void)?
  private var onCollapse: (@MainActor () -> Void)?
  private var onRedo: (@MainActor () -> Void)?
  private var onCopySource: (@MainActor () -> Void)?
  private var onCopyResult: (@MainActor () -> Void)?

  #if DEBUG
    var headerModeFrameForTesting: NSRect { modeTextLayer.frame }
    var foldedPreviewFrameForTesting: NSRect { previewView.frame }
    var foldedPreviewViewForTesting: FoldedPreviewTextView { previewView }
    var foldedFadeFrameForTesting: NSRect { previewView.fadeLayer.frame }
    var foldedPreviewUsesFadeForTesting: Bool {
      !previewView.isHidden && previewView.fadeLayer.opacity > 0
    }
    var hoverHighlightFrameForTesting: NSRect { hoverHighlightLayer.frame }
    var hoverHighlightOpacityForTesting: Float { hoverHighlightLayer.opacity }
    var hoverHighlightColorForTesting: CGColor? { hoverHighlightLayer.backgroundColor }
    var isTransitioningForTesting: Bool { transition != nil }
    var sourceFrameForTesting: NSRect { sourceTextField.frame }
    var sourceFadeFrameForTesting: NSRect { sourceFadeLayer.frame }
    var sourceUsesFadeForTesting: Bool { sourceTextField.layer?.mask === sourceFadeLayer }
    private(set) var sourceMeasurementCountForTesting = 0
    var resultFrameForTesting: NSRect { resultContainer?.frame ?? .zero }
    var resultContainerForTesting: HistoryResultTextContainer? { resultContainer }
    var hasExpandHandlerForTesting: Bool { onExpand != nil }
    private(set) var mouseDownCountForTesting = 0
    var headerRendererIdentityForTesting: ObjectIdentifier {
      ObjectIdentifier(modeTextLayer)
    }
    var actionButtonsForTesting: [HistoryEntryActionButton] {
      [redoButton, copyButton, copySourceButton, chevronButton].compactMap { $0 }
    }
    var chevronButtonForTesting: HistoryEntryActionButton? { chevronButton }
  #endif

  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(
      width: NSView.noIntrinsicMetric,
      height: preferredHeight(for: max(1, bounds.width))
    )
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    focusRingType = .none
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    // The hover highlight bleeds past the text column, so the entry itself
    // must not clip; the result container and preview clip their own text.
    layer?.masksToBounds = false
    layer?.backgroundColor = NSColor.clear.cgColor

    hoverHighlightLayer.actions = Self.disabledLayerActions
    hoverHighlightLayer.cornerRadius = HistoryEntryPencilLayout.hoverCornerRadius
    hoverHighlightLayer.backgroundColor = Self.hoverHighlightColor.cgColor
    hoverHighlightLayer.opacity = 0
    layer?.insertSublayer(hoverHighlightLayer, at: 0)

    for textLayer in [modeTextLayer, metadataTextLayer] {
      textLayer.alignmentMode = .left
      textLayer.contentsGravity = .topLeft
      textLayer.truncationMode = .end
      textLayer.actions = Self.disabledLayerActions
      layer?.addSublayer(textLayer)
    }
    sourceFadeLayer.actions = Self.disabledLayerActions
    separatorLayer.actions = Self.disabledLayerActions
    separatorLayer.backgroundColor = Self.borderColor.cgColor
    layer?.addSublayer(separatorLayer)
    updateLayerScale()

    iconView.imageScaling = .scaleProportionallyDown
    iconView.contentTintColor = Self.accentColor
    addSubview(iconView)

    previewView.isHidden = false
    addSubview(previewView)

    sourceTextField.font = CidaDesign.appKitBody(13)
    sourceTextField.textColor = Self.tertiaryTextColor
    sourceTextField.backgroundColor = .clear
    sourceTextField.drawsBackground = false
    sourceTextField.isBezeled = false
    sourceTextField.isEditable = false
    sourceTextField.isSelectable = true
    sourceTextField.setAccessibilityElement(true)
    sourceTextField.setAccessibilityRole(.staticText)
    sourceTextField.setAccessibilityLabel("原文")
    sourceTextField.maximumNumberOfLines = HistoryEntryPencilLayout.latestSourceLineLimit
    sourceTextField.lineBreakMode = .byWordWrapping
    sourceTextField.cell?.wraps = true
    sourceTextField.cell?.isScrollable = false
    sourceTextField.wantsLayer = true
    sourceFadeLayer.colors = [
      NSColor.white.cgColor,
      NSColor.white.cgColor,
      NSColor.clear.cgColor,
    ]
    sourceFadeLayer.locations = [
      0,
      NSNumber(
        value: Double(
          (HistoryEntryPencilLayout.latestSourcePreviewHeight
            - HistoryEntryPencilLayout.latestSourceFadeHeight)
            / HistoryEntryPencilLayout.latestSourcePreviewHeight
        )
      ),
      1,
    ]
    sourceFadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
    sourceFadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
    sourceTextField.isHidden = true
    addSubview(sourceTextField)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("历史记录")
    previewAccessibilityElement.setAccessibilityRole(.staticText)
    updateLayerAppearance(animated: false)
    updateAccessibilityChildren()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    MainActor.assumeIsolated {
      transition?.completion.cancel()
      releaseResultPresentation()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateLayerScale()
    guard window != nil else {
      removeScrollObservation()
      setHovering(false)
      return
    }
    DispatchQueue.main.async { [weak self] in
      self?.installScrollObservationIfNeeded()
      self?.refreshHoverState()
    }
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  func configure(
    entryID: UUID,
    mode: ProcessingMode,
    metadata: String,
    preview: String,
    state: HistoryEntryState,
    showsSeparator: Bool = false,
    animated: Bool = false,
    onExpand: @escaping @MainActor () -> Void,
    onRedo: @escaping @MainActor () -> Void,
    onCopyResult: @escaping @MainActor () -> Void
  ) {
    setHoverManagedExternally(false)
    configureContent(
      entryID: entryID,
      mode: mode,
      metadata: metadata,
      preview: preview,
      state: state,
      showsSeparator: showsSeparator
    )
    setActionHandlers(
      onExpand: onExpand,
      onRedo: onRedo,
      onCopyResult: onCopyResult
    )
    setPresentation(.folded, animated: animated)
  }

  func configureExpanded(
    entryID: UUID,
    mode: ProcessingMode,
    metadata: String,
    source: String,
    preview: String,
    resultStorage: HistoryResultStorage,
    presentationRevision: Int,
    latestPresentationDelta: String?,
    state: HistoryEntryState,
    presentation: HistoryPresentation,
    isLongEntry: Bool,
    showsSeparator: Bool,
    animated: Bool = false,
    onCollapse: @escaping @MainActor () -> Void,
    onRedo: @escaping @MainActor () -> Void,
    onCopySource: @escaping @MainActor () -> Void,
    onCopyResult: @escaping @MainActor () -> Void
  ) {
    precondition(presentation.isExpanded)
    configureContent(
      entryID: entryID,
      mode: mode,
      metadata: metadata,
      preview: preview,
      state: state,
      showsSeparator: showsSeparator
    )
    let nextDisplayedSource = String(source.prefix(420))
    if displayedSource != nextDisplayedSource {
      displayedSource = nextDisplayedSource
      invalidateSourceLayout()
    }
    self.resultStorage = resultStorage
    resultPresentationRevision = presentationRevision
    self.latestPresentationDelta = latestPresentationDelta
    self.isLongEntry = isLongEntry
    self.onCollapse = onCollapse
    self.onRedo = onRedo
    self.onCopySource = onCopySource
    self.onCopyResult = onCopyResult
    setHoverManagedExternally(true)
    configureExpandedContent(layoutImmediately: animated && self.presentation == .folded)
    setPresentation(presentation, animated: animated)
  }

  /// Keeps the expanded content for a record that is folding, so the fold can
  /// animate from the live expanded frames.
  func configureFolding(
    entryID: UUID,
    mode: ProcessingMode,
    metadata: String,
    source: String,
    preview: String,
    resultStorage: HistoryResultStorage,
    state: HistoryEntryState,
    isLongEntry: Bool,
    showsSeparator: Bool,
    animated: Bool,
    onExpand: @escaping @MainActor () -> Void,
    onRedo: @escaping @MainActor () -> Void,
    onCopyResult: @escaping @MainActor () -> Void
  ) {
    configureContent(
      entryID: entryID,
      mode: mode,
      metadata: metadata,
      preview: preview,
      state: state,
      showsSeparator: showsSeparator
    )
    let nextDisplayedSource = String(source.prefix(420))
    if displayedSource != nextDisplayedSource {
      displayedSource = nextDisplayedSource
      invalidateSourceLayout()
    }
    self.resultStorage = resultStorage
    self.isLongEntry = isLongEntry
    setActionHandlers(onExpand: onExpand, onRedo: onRedo, onCopyResult: onCopyResult)
    setPresentation(.folded, animated: animated)
  }

  func configureContent(
    entryID: UUID,
    mode: ProcessingMode,
    metadata: String,
    preview: String,
    state: HistoryEntryState,
    showsSeparator: Bool = false
  ) {
    let identityChanged = self.entryID != entryID
    let contentChanged =
      self.mode != mode || self.metadata != metadata
      || self.preview != preview
      || self.showsSeparator != showsSeparator

    if identityChanged {
      prepareForReuse()
      copyResetWorkItem?.cancel()
      copyResetWorkItem = nil
      resetCopyFeedback()
    }
    let completedWhileHovering =
      !identityChanged && entryState == .streaming && state != .streaming && isHovering
    self.entryID = entryID
    self.mode = mode
    self.metadata = metadata
    self.preview = preview
    self.showsSeparator = showsSeparator
    entryState = state

    if identityChanged || contentChanged {
      iconView.image = LucideIconAsset.image(for: mode == .translate ? .languages : .sparkles)
      modeAttributedString = makeModeAttributedString()
      metadataAttributedString = makeMetadataAttributedString()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      modeTextLayer.string = modeAttributedString
      metadataTextLayer.string = metadataAttributedString
      CATransaction.commit()
      if presentation == .folded, transition == nil {
        previewView.setText(preview)
      }
      needsLayout = true
    }

    redoButton?.setAccessibilityIdentifier("history-action-redo-\(identifierSuffix)")
    copyButton?.setAccessibilityIdentifier("history-action-copy-result-\(identifierSuffix)")
    copySourceButton?.setAccessibilityIdentifier(
      "history-action-copy-source-\(identifierSuffix)"
    )
    chevronButton?.setAccessibilityIdentifier("history-action-disclose-\(identifierSuffix)")
    updatePresentationAccessibility()
    if completedWhileHovering {
      pendingActionRevealDuration = CidaMotion.iconSwapSeconds
    }
    updateActionVisibility()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    transition?.completion.cancel()
    transition = nil
    copyResetWorkItem?.cancel()
    sourceCopyResetWorkItem?.cancel()
    resultCopyResetWorkItem?.cancel()
    copyResetWorkItem = nil
    sourceCopyResetWorkItem = nil
    resultCopyResetWorkItem = nil
    releaseResultPresentation()
    stickyResultActionView?.detach()
    stickyResultActionView?.removeFromSuperview()
    stickyResultActionView = nil
    hoverTrackingView?.detach()
    hoverTrackingView?.removeFromSuperview()
    hoverTrackingView = nil
    sourceTextField.stringValue = ""
    sourceTextField.isHidden = true
    sourceTextField.alphaValue = 1
    sourceTextField.layer?.mask = nil
    sourceFadeLayer.isHidden = true
    previewView.isHidden = false
    previewView.setText("")
    previewView.setFadeOpacity(0, duration: 0)
    isHovering = false
    isSourceCopied = false
    isResultCopied = false
    for button in [redoButton, copyButton, copySourceButton, chevronButton] {
      button?.conceal()
      button?.resetHoverState()
    }
    presentation = .folded
    displayedSource = ""
    invalidateSourceLayout()
    resultStorage = nil
    resultPresentationRevision = 0
    latestPresentationDelta = nil
    isLongEntry = false
    onCollapse = nil
    onCopySource = nil
    pendingActionRevealDuration = CidaMotion.iconInSeconds
    updateAccessibilityChildren()
    updateLayerAppearance(animated: false)
    needsLayout = true
  }

  func detachStandalonePresentation() {
    prepareForReuse()
    removeScrollObservation()
  }

  func historyResultHeightWillChange(by delta: CGFloat, animated: Bool) {
    invalidateIntrinsicContentSize()
    needsLayout = true
    var ancestor = superview
    while let current = ancestor {
      if let hostingView = current as? any HistoryResultHeightChangeHosting {
        hostingView.historyResultHeightWillChange(by: delta, animated: animated)
        break
      }
      ancestor = current.superview
    }
  }

  // MARK: - Presentation

  private func setPresentation(_ nextPresentation: HistoryPresentation, animated: Bool) {
    let previousPresentation = presentation
    if let transition {
      // SwiftUI re-renders freely while a transition runs; the same target
      // just keeps the in-flight animation.
      guard transition.target != nextPresentation else {
        updatePresentationAccessibility()
        return
      }
      transition.completion.cancel()
      finishTransition(transition)
    }
    let changed = previousPresentation != nextPresentation
    presentation = nextPresentation
    let duration =
      changed && animated
      ? CidaMotion.resolvedDuration(CidaMotion.historyFoldSeconds, in: window)
      : 0

    if duration > 0 {
      beginTransition(from: previousPresentation, to: nextPresentation, duration: duration)
    } else {
      applyPresentationImmediately(nextPresentation)
    }

    if changed {
      invalidateIntrinsicContentSize()
      needsLayout = true
    }
    updateLayerAppearance(animated: duration > 0)
    updatePresentationAccessibility()
    updateActionVisibility()
  }

  private func applyPresentationImmediately(_ nextPresentation: HistoryPresentation) {
    switch nextPresentation {
    case .folded:
      releaseResultPresentation()
      hoverTrackingView?.detach()
      hoverTrackingView?.removeFromSuperview()
      hoverTrackingView = nil
      stickyResultActionView?.detach()
      stickyResultActionView?.removeFromSuperview()
      stickyResultActionView = nil
      sourceTextField.isHidden = true
      sourceTextField.alphaValue = 1
      sourceTextField.layer?.mask = nil
      sourceFadeLayer.isHidden = true
      copySourceButton?.conceal()
      previewView.setText(preview)
      previewView.isHidden = false
    case .current, .manuallyExpanded:
      previewView.isHidden = true
      sourceTextField.isHidden = displayedSource.isEmpty
      sourceTextField.alphaValue = 1
      resultContainer?.isHidden = false
      hoverTrackingView?.setActive(true)
      stickyResultActionView?.isHidden = false
    }
    needsLayout = true
  }

  private func beginTransition(
    from previousPresentation: HistoryPresentation,
    to nextPresentation: HistoryPresentation,
    duration: TimeInterval
  ) {
    let width = max(1, bounds.width)
    let fromGeometry = geometry(for: previousPresentation, width: width)
    var toGeometry = geometry(for: nextPresentation, width: width)

    // Register the transition first so any layout pass that runs while the
    // animations are in flight leaves the animated frames alone.
    let completion = DispatchWorkItem { [weak self] in
      guard let self, let transition = self.transition else { return }
      self.finishTransition(transition)
    }
    transition = PresentationTransition(target: nextPresentation, completion: completion)

    for button in [redoButton, copyButton, copySourceButton, chevronButton] {
      button?.conceal()
    }
    stickyResultActionView?.isHidden = true

    switch nextPresentation {
    case .folded:
      // The result text swaps to the preview renderer at the start so the fold
      // only animates geometry: the source collapses and the result rises and,
      // for a long record, clips to two lines under the Pencil fade.
      hoverTrackingView?.setActive(false)
      let transitionText =
        isLongEntry ? preview : (resultStorage?.string ?? preview)
      previewView.setTextWidth(toGeometry.preview.width)
      previewView.setText(transitionText)
      let naturalHeight = previewView.naturalTextHeight
      toGeometry = geometry(for: .folded, width: width)
      previewView.frame = NSRect(
        x: fromGeometry.result.minX,
        y: fromGeometry.result.minY,
        width: toGeometry.preview.width,
        height: max(toGeometry.preview.height, naturalHeight)
      )
      previewView.layoutSubtreeIfNeeded()
      previewView.setFadeOpacity(0, duration: 0)
      previewView.isHidden = false
      releaseResultPresentation()
      sourceTextField.frame = fromGeometry.source
      sourceTextField.alphaValue = 1
      sourceTextField.isHidden = displayedSource.isEmpty
    case .current, .manuallyExpanded:
      previewView.isHidden = true
      if let resultContainer {
        resultContainer.frame = NSRect(
          x: fromGeometry.preview.minX,
          y: fromGeometry.preview.minY,
          width: toGeometry.result.width,
          height: fromGeometry.preview.height
        )
        resultContainer.isHidden = false
      }
      sourceTextField.frame = fromGeometry.source
      sourceTextField.alphaValue = fromGeometry.sourceAlpha
      sourceTextField.isHidden = displayedSource.isEmpty
      hoverTrackingView?.setActive(false)
    }
    applySourceMask(usesFade: toGeometry.sourceUsesFade, frame: toGeometry.source)

    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CidaMotion.easeOut
      context.allowsImplicitAnimation = true
      sourceTextField.animator().frame = toGeometry.source
      sourceTextField.animator().alphaValue = toGeometry.sourceAlpha
      if nextPresentation == .folded {
        previewView.animator().frame = toGeometry.preview
      } else if let resultContainer {
        resultContainer.animator().frame = toGeometry.result
      }
    }
    previewView.setFadeOpacity(toGeometry.previewUsesFade ? 1 : 0, duration: duration)

    DispatchQueue.main.asyncAfter(
      deadline: .now() + duration,
      execute: completion
    )
  }

  private func finishTransition(_ transition: PresentationTransition) {
    guard self.transition?.completion === transition.completion else { return }
    self.transition = nil
    switch transition.target {
    case .folded:
      previewView.setText(preview)
      sourceTextField.isHidden = true
      sourceTextField.alphaValue = 1
      sourceTextField.layer?.mask = nil
      sourceFadeLayer.isHidden = true
      hoverTrackingView?.detach()
      hoverTrackingView?.removeFromSuperview()
      hoverTrackingView = nil
      stickyResultActionView?.detach()
      stickyResultActionView?.removeFromSuperview()
      stickyResultActionView = nil
    case .current, .manuallyExpanded:
      previewView.isHidden = true
      sourceTextField.alphaValue = 1
      hoverTrackingView?.setActive(true)
      stickyResultActionView?.isHidden = false
    }
    needsLayout = true
    layoutSubtreeIfNeeded()
    updateLayerAppearance(animated: false)
    updateActionVisibility()
  }

  private func configureExpandedContent(layoutImmediately: Bool) {
    guard let resultStorage else { return }
    if sourceTextField.stringValue != displayedSource {
      let sourceParagraphStyle = NSMutableParagraphStyle()
      sourceParagraphStyle.minimumLineHeight = Layout.sourceLineHeight
      sourceParagraphStyle.maximumLineHeight = Layout.sourceLineHeight
      sourceParagraphStyle.lineBreakMode = .byWordWrapping
      sourceTextField.attributedStringValue = NSAttributedString(
        string: displayedSource,
        attributes: [
          .font: CidaDesign.appKitBody(13),
          .foregroundColor: Self.tertiaryTextColor,
          .paragraphStyle: sourceParagraphStyle,
        ]
      )
      invalidateSourceLayout()
    }
    sourceTextField.isSelectable = !isLongEntry
    sourceTextField.setAccessibilityIdentifier("history-source-\(identifierSuffix)")
    sourceTextField.setAccessibilityValue(displayedSource)

    let resultContainer: HistoryResultTextContainer
    let resultCoordinator: HistoryResultTextCoordinator
    if let existingContainer = self.resultContainer,
      let existingCoordinator = self.resultCoordinator
    {
      resultContainer = existingContainer
      resultCoordinator = existingCoordinator
    } else {
      resultContainer = HistoryResultTextContainerPool.shared.acquire()
      resultCoordinator = HistoryResultTextCoordinator()
      self.resultContainer = resultContainer
      self.resultCoordinator = resultCoordinator
      resultContainer.isHidden = presentation == .folded
      addSubview(resultContainer)
    }
    resultContainer.setResultAccessibilityIdentifier(
      "history-result-\(entryID.uuidString)"
    )
    #if DEBUG
      resultContainer.setContentEndAccessibilityIdentifier(
        "history-result-content-end-\(entryID.uuidString)"
      )
    #endif
    resultContainer.onWidthChange = { [weak resultContainer, weak resultCoordinator] in
      guard let resultContainer, let resultCoordinator else { return }
      resultCoordinator.scheduleLayout(of: resultContainer)
    }
    resultCoordinator.observeStreamingUpdates(from: resultStorage, in: resultContainer)
    resultCoordinator.updateText(
      resultStorage,
      entryID: entryID,
      presentationRevision: resultPresentationRevision,
      latestPresentationDelta: latestPresentationDelta,
      isStreaming: entryState == .streaming,
      in: resultContainer
    )
    if layoutImmediately {
      // The expand transition needs the natural height now so SwiftUI can
      // animate the frame to it; SwiftUI measures that height itself, so the
      // layout must not also publish it as a delta.
      let textWidth = max(1, bounds.width - Layout.actionColumnWidth)
      if abs(resultContainer.frame.width - textWidth) > 0.5 {
        resultContainer.setFrameSize(NSSize(width: textWidth, height: resultContainer.frame.height))
      }
      resultCoordinator.layoutNow(of: resultContainer, publishesHeight: false)
    }

    let tracker: HistoryEntryHoverTrackingNSView
    if let existingTracker = hoverTrackingView {
      tracker = existingTracker
    } else {
      tracker = HistoryEntryHoverTrackingNSView()
      hoverTrackingView = tracker
      addSubview(tracker)
    }
    tracker.onHoverChange = { [weak self] hovering in
      self?.setHovering(hovering)
    }
    tracker.synchronizePublishedHoverState(isHovering)

    let resultAction: StickyHistoryResultActionNSView
    if let existingAction = stickyResultActionView {
      resultAction = existingAction
    } else {
      resultAction = StickyHistoryResultActionNSView()
      stickyResultActionView = resultAction
      addSubview(resultAction)
    }
    resultAction.configure(
      identifier: "history-action-copy-result-\(identifierSuffix)",
      isLongEntry: isLongEntry,
      isVisible: resultStorage.utf16Length > 0 && (showsExpandedActions || isResultCopied),
      isCopied: isResultCopied,
      revealDuration: 0
    ) { [weak self] in
      self?.performExpandedResultCopy()
    }
    resultCoordinator.scheduleLayout(of: resultContainer)
    updatePresentationAccessibility()
    needsLayout = true
  }

  private func releaseResultPresentation() {
    guard let resultContainer else { return }
    resultCoordinator?.detach(from: resultContainer)
    resultContainer.removeFromSuperview()
    HistoryResultTextContainerPool.shared.release(resultContainer)
    self.resultContainer = nil
    resultCoordinator = nil
  }

  func setPresentationActive(_ active: Bool) {
    guard isPresentationActive != active else { return }
    isPresentationActive = active
    isHidden = !active
    if let trackingAreaReference {
      removeTrackingArea(trackingAreaReference)
      self.trackingAreaReference = nil
    }
    if !active {
      removeScrollObservation()
      isHovering = false
      for button in [redoButton, copyButton, chevronButton] {
        button?.conceal()
        button?.resetHoverState()
      }
      updateAccessibilityChildren()
    } else {
      updateTrackingAreas()
      installScrollObservationIfNeeded()
    }
    updateLayerAppearance(animated: false)
  }

  func setActionHandlers(
    onExpand: @escaping @MainActor () -> Void,
    onRedo: @escaping @MainActor () -> Void,
    onCopyResult: @escaping @MainActor () -> Void
  ) {
    self.onExpand = onExpand
    self.onRedo = onRedo
    self.onCopyResult = onCopyResult
  }

  func setHoverManagedExternally(_ managedExternally: Bool) {
    guard isHoverManagedExternally != managedExternally else { return }
    isHoverManagedExternally = managedExternally
    updateTrackingAreas()
    if managedExternally {
      removeScrollObservation()
      setHovering(false)
    } else {
      installScrollObservationIfNeeded()
      refreshHoverState()
    }
  }

  func setResolvedHoverState(_ hovering: Bool) {
    guard isHoverManagedExternally else { return }
    setHovering(isPresentationActive && hovering)
  }

  func representedEntry(in entries: [HistoryEntry]) -> HistoryEntry? {
    entries.first { $0.id == entryID }
  }

  func preferredHeight(for width: CGFloat) -> CGFloat {
    let separator = showsSeparator ? Layout.separatorHeight : 0
    switch presentation {
    case .folded:
      previewView.setTextWidth(max(1, width - Layout.actionColumnWidth))
      return HistoryEntryPencilLayout.historyRowHeight(
        previewLineCount: previewView.naturalLineCount
      ) + separator
    case .current, .manuallyExpanded:
      let sourceLayout = sourcePresentationLayout(for: width)
      let sourceHeight =
        sourceLayout.height > 0 ? sourceLayout.height + Layout.contentSpacing : 0
      let resultHeight =
        resultContainer?.naturalTextHeight ?? HistoryResultTextContainer.minimumHeight
      return Layout.verticalPadding * 2
        + Layout.headerHeight
        + Layout.contentSpacing
        + sourceHeight
        + resultHeight
        + separator
    }
  }

  // MARK: - Geometry

  private var contentHeight: CGFloat {
    max(0, bounds.height - (showsSeparator ? Layout.separatorHeight : 0))
  }

  private func geometry(
    for presentation: HistoryPresentation,
    width: CGFloat
  ) -> PresentationGeometry {
    let modeWidth = ceil(modeAttributedString.size().width)
    let headerY = Layout.verticalPadding
    let textWidth = max(0, width - Layout.actionColumnWidth)
    let modeX = Layout.modeOffset
    let headerRight = max(modeX, width - Layout.actionColumnWidth)
    let actionX = max(0, width - Layout.actionSize)
    let chevronX = max(0, actionX - Layout.actionGap - Layout.actionSize)
    let icon = NSRect(x: 0, y: headerY + Layout.iconOffset, width: 12, height: 12)
    let modeRect = NSRect(x: modeX, y: headerY, width: modeWidth, height: Layout.headerHeight)
    let metadataRect = NSRect(
      x: modeX + modeWidth + Layout.metadataGap,
      y: headerY,
      width: max(0, headerRight - modeX - modeWidth - Layout.metadataGap),
      height: Layout.headerHeight
    )
    let redo = NSRect(
      x: actionX,
      y: headerY + Layout.iconOffset,
      width: Layout.actionSize,
      height: Layout.actionSize
    )
    let chevron = NSRect(
      x: chevronX,
      y: headerY + Layout.iconOffset,
      width: Layout.actionSize,
      height: Layout.actionSize
    )
    let previewNaturalHeight = previewView.naturalTextHeight
    switch presentation {
    case .folded:
      let previewHeight = HistoryEntryPencilLayout.previewHeight(forRowHeight: contentHeight)
      let previewRect = NSRect(
        x: 0,
        y: Layout.contentTop,
        width: textWidth,
        height: previewHeight
      )
      return PresentationGeometry(
        icon: icon,
        mode: modeRect,
        metadata: metadataRect,
        source: NSRect(x: 0, y: Layout.contentTop, width: textWidth, height: 0),
        sourceUsesFade: false,
        sourceAlpha: 0,
        preview: previewRect,
        previewUsesFade: previewNaturalHeight > previewHeight + 0.5,
        result: previewRect,
        redo: redo,
        chevron: chevron,
        copyResult: NSRect(
          x: actionX,
          y: Layout.contentTop + Layout.actionRowOffset,
          width: Layout.actionSize,
          height: Layout.actionSize
        ),
        copySource: NSRect(
          x: actionX,
          y: Layout.contentTop + Layout.actionRowOffset,
          width: Layout.actionSize,
          height: Layout.actionSize
        )
      )
    case .current, .manuallyExpanded:
      let sourceLayout = sourcePresentationLayout(for: width, presentation: presentation)
      let sourceSpacing = sourceLayout.height > 0 ? Layout.contentSpacing : 0
      let resultY = Layout.contentTop + sourceLayout.height + sourceSpacing
      let resultHeight =
        resultContainer?.naturalTextHeight ?? HistoryResultTextContainer.minimumHeight
      return PresentationGeometry(
        icon: icon,
        mode: modeRect,
        metadata: metadataRect,
        source: NSRect(x: 0, y: Layout.contentTop, width: textWidth, height: sourceLayout.height),
        sourceUsesFade: sourceLayout.usesFade,
        sourceAlpha: 1,
        preview: NSRect(
          x: 0,
          y: resultY,
          width: textWidth,
          height: min(Layout.previewHeight, max(HistoryEntryPencilLayout.resultLineHeight, previewNaturalHeight))
        ),
        previewUsesFade: false,
        result: NSRect(x: 0, y: resultY, width: textWidth, height: resultHeight),
        redo: redo,
        chevron: chevron,
        copyResult: NSRect(
          x: actionX,
          y: resultY + Layout.actionRowOffset,
          width: Layout.actionSize,
          height: Layout.actionSize
        ),
        copySource: NSRect(
          x: actionX,
          y: Layout.contentTop + Layout.actionRowOffset,
          width: Layout.actionSize,
          height: Layout.actionSize
        )
      )
    }
  }

  override func layout() {
    super.layout()
    let width = max(1, bounds.width)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    hoverHighlightLayer.frame = NSRect(
      x: -Layout.hoverBleed,
      y: 0,
      width: bounds.width + Layout.hoverBleed * 2,
      height: contentHeight
    )
    separatorLayer.frame = NSRect(
      x: 0,
      y: bounds.maxY - Layout.separatorHeight,
      width: bounds.width,
      height: showsSeparator ? Layout.separatorHeight : 0
    )
    CATransaction.commit()

    if transition == nil {
      if presentation == .folded {
        previewView.setTextWidth(max(1, width - Layout.actionColumnWidth))
      }
      let geometry = geometry(for: presentation, width: width)
      iconView.frame = geometry.icon
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      modeTextLayer.frame = geometry.mode
      metadataTextLayer.frame = geometry.metadata
      CATransaction.commit()
      switch presentation {
      case .folded:
        previewView.frame = geometry.preview
        previewView.setFadeOpacity(geometry.previewUsesFade ? 1 : 0, duration: 0)
        sourceTextField.frame = geometry.source
      case .current, .manuallyExpanded:
        sourceTextField.frame = geometry.source
        applySourceMask(usesFade: geometry.sourceUsesFade, frame: geometry.source)
        sourceTextField.isHidden = geometry.source.height == 0
        resultContainer?.frame = geometry.result
        stickyResultActionView?.frame = NSRect(
          x: 0,
          y: geometry.result.minY,
          width: bounds.width,
          height: geometry.result.height
        )
        if let resultCoordinator, let resultContainer {
          resultCoordinator.scheduleLayout(of: resultContainer)
        }
      }
      redoButton?.frame = geometry.redo
      chevronButton?.frame = geometry.chevron
      copyButton?.frame = geometry.copyResult
      copySourceButton?.frame = geometry.copySource
    }
    hoverTrackingView?.frame = bounds
    if window != nil {
      installScrollObservationIfNeeded()
      refreshHoverState()
    }
  }

  private func applySourceMask(usesFade: Bool, frame: NSRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    sourceFadeLayer.frame = NSRect(origin: .zero, size: frame.size)
    sourceFadeLayer.isHidden = !usesFade
    sourceTextField.layer?.mask = usesFade ? sourceFadeLayer : nil
    CATransaction.commit()
  }

  private func invalidateSourceLayout() {
    measuredSourceWidth = nil
    measuredSourceLayout = .hidden
  }

  private func sourcePresentationLayout(
    for entryWidth: CGFloat,
    presentation: HistoryPresentation? = nil
  ) -> SourcePresentationLayout {
    let textWidth = max(0, entryWidth - Layout.actionColumnWidth)
    let presentation = presentation ?? self.presentation
    guard presentation.isExpanded, !displayedSource.isEmpty, textWidth > 0 else {
      return .hidden
    }
    if let measuredSourceWidth, abs(measuredSourceWidth - textWidth) < 0.5 {
      return measuredSourceLayout
    }

    let measuredBounds = sourceTextField.attributedStringValue.boundingRect(
      with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    #if DEBUG
      sourceMeasurementCountForTesting += 1
    #endif
    let naturalHeight = ceil(max(Layout.sourceLineHeight, measuredBounds.height))
    let layout = SourcePresentationLayout(
      height: min(Layout.sourceMaximumHeight, naturalHeight),
      usesFade: naturalHeight > Layout.sourceMaximumHeight
    )
    measuredSourceWidth = textWidth
    measuredSourceLayout = layout
    return layout
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    for button in [redoButton, copyButton, copySourceButton, chevronButton].compactMap({ $0 })
    where !button.isHidden {
      let buttonPoint = button.convert(point, from: self)
      if let actionHit = button.hitTest(buttonPoint) {
        return actionHit
      }
    }
    return super.hitTest(point)
  }

  override func draw(_ dirtyRect: NSRect) {}

  fileprivate func accessibilityFrame(
    for region: HistoryEntryAccessibilityElement.Region
  ) -> NSRect {
    guard let window else { return .zero }
    let localFrame: NSRect
    switch region {
    case .entry:
      if presentation.isExpanded {
        localFrame = NSRect(
          x: 0,
          y: Layout.verticalPadding,
          width: bounds.width,
          height: Layout.headerHeight
        )
      } else {
        localFrame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
      }
    case .preview:
      localFrame = geometry(for: .folded, width: max(1, bounds.width)).preview
    }
    return window.convertToScreen(convert(localFrame, to: nil))
  }

  private func updateLayerScale() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    modeTextLayer.contentsScale = scale
    metadataTextLayer.contentsScale = scale
  }

  /// Hovering a record at rest tints the whole row over the icon-in duration;
  /// the preview fade follows the tint so the clipped line dissolves into it.
  private func updateLayerAppearance(animated: Bool) {
    let highlighted = isHovering && presentation == .folded && transition == nil
    let duration = animated ? CidaMotion.resolvedDuration(CidaMotion.iconInSeconds, in: window) : 0
    CATransaction.begin()
    if duration > 0 {
      CATransaction.setAnimationDuration(duration)
      CATransaction.setAnimationTimingFunction(CidaMotion.easeOut)
    } else {
      CATransaction.setDisableActions(true)
    }
    hoverHighlightLayer.opacity = highlighted ? 1 : 0
    CATransaction.commit()
    previewView.setFadeColor(
      highlighted ? Self.hoverHighlightColor : Self.backgroundColor,
      animated: duration > 0
    )
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaReference {
      removeTrackingArea(trackingAreaReference)
    }
    guard isPresentationActive, !isHoverManagedExternally else {
      trackingAreaReference = nil
      return
    }
    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    trackingAreaReference = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    if window == nil {
      setHovering(isPresentationActive)
    } else {
      refreshHoverState()
    }
  }

  override func mouseMoved(with event: NSEvent) {
    refreshHoverState()
  }

  override func mouseExited(with event: NSEvent) {
    if window == nil {
      setHovering(false)
    } else {
      refreshHoverState()
    }
  }

  func refreshHoverState() {
    guard !isHoverManagedExternally else { return }
    guard
      isPresentationActive,
      !isHidden,
      let window,
      window.isKeyWindow
    else {
      setHovering(false)
      return
    }

    let mouseLocation = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    setHovering(
      bounds.contains(mouseLocation)
        && visibleRect.intersects(bounds)
        && visibleRect.contains(mouseLocation)
    )
  }

  private func installScrollObservationIfNeeded() {
    guard isPresentationActive, !isHoverManagedExternally else { return }
    guard let clipView = enclosingScrollView?.contentView else { return }
    guard observedClipView !== clipView else { return }
    removeScrollObservation()
    observedClipView = clipView
    clipView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(clipViewBoundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: clipView
    )
  }

  private func removeScrollObservation() {
    NotificationCenter.default.removeObserver(self)
    observedClipView = nil
  }

  @objc
  private func clipViewBoundsDidChange(_ notification: Notification) {
    refreshHoverState()
  }

  private func setHovering(_ hovering: Bool) {
    guard isHovering != hovering else { return }
    isHovering = hovering
    updateActionVisibility()
    updateLayerAppearance(animated: true)
    needsLayout = true
  }

  override func mouseDown(with event: NSEvent) {
    #if DEBUG
      mouseDownCountForTesting &+= 1
    #endif
    guard isPresentationActive else { return }
    let location = convert(event.locationInWindow, from: nil)
    guard bounds.contains(location) else { return }
    if performVisibleAction(at: location) { return }
    switch HistoryRenderContract(presentation: presentation).disclosureAction {
    case .expand:
      onExpand?()
    case .collapse:
      let headerY = Layout.verticalPadding
      let headerRect = NSRect(
        x: 0,
        y: headerY,
        width: bounds.width,
        height: Layout.headerHeight
      )
      if headerRect.contains(location) {
        onCollapse?()
      }
    case .none:
      break
    }
  }

  @discardableResult
  func performVisibleAction(at location: NSPoint) -> Bool {
    for button in [redoButton, copyButton, copySourceButton].compactMap({ $0 })
    where !button.isHidden && button.frame.insetBy(dx: -6, dy: -6).contains(location) {
      button.performClick(nil)
      return true
    }
    return false
  }

  override func accessibilityPerformPress() -> Bool {
    guard isPresentationActive else { return false }
    switch HistoryRenderContract(presentation: presentation).disclosureAction {
    case .expand:
      onExpand?()
      return true
    case .collapse:
      onCollapse?()
      return true
    case .none:
      return false
    }
  }

  private func makeModeAttributedString() -> NSAttributedString {
    NSAttributedString(
      string: mode.title,
      attributes: [
        .font: Self.modeFont,
        .foregroundColor: Self.accentColor,
      ]
    )
  }

  private func makeMetadataAttributedString() -> NSAttributedString {
    NSAttributedString(
      string: metadata,
      attributes: [
        .font: Self.metadataFont,
        .foregroundColor: Self.tertiaryTextColor,
      ]
    )
  }

  private var identifierSuffix: String {
    entryID.uuidString.lowercased()
  }

  // MARK: - Actions

  private func updateActionVisibility() {
    let showsActions =
      transition == nil
      && HistoryEntryActionPolicy.showsActions(
        isHovering: isPresentationActive && isHovering,
        state: entryState
      )
    let revealDuration = pendingActionRevealDuration
    pendingActionRevealDuration = CidaMotion.iconInSeconds
    let buttons = ensureActionButtons()
    setActionVisible(buttons.redo, showsActions, revealDuration: revealDuration)

    let disclosure = HistoryRenderContract(presentation: presentation).disclosureAction
    if disclosure != .none {
      let chevron = ensureChevronButton()
      let description = disclosure == .expand ? "展开这条历史记录" : "收起这条历史记录"
      if chevron.accessibilityLabel() != description {
        let icon: LucideIconName = disclosure == .expand ? .chevronDown : .chevronUp
        chevron.image = Self.describedIcon(icon, description: description)
        chevron.iconImage = LucideIconAsset.image(for: icon)
        chevron.setAccessibilityLabel(description)
        chevron.setAccessibilityHelp(description)
      }
      setActionVisible(chevron, showsActions, revealDuration: revealDuration)
    } else {
      chevronButton?.conceal()
    }

    switch presentation {
    case .folded:
      setActionVisible(buttons.copy, showsActions && !preview.isEmpty, revealDuration: revealDuration)
      copySourceButton?.conceal()
      stickyResultActionView?.isHidden = true
    case .current, .manuallyExpanded:
      buttons.copy.conceal()
      let sourceButton = ensureCopySourceButton()
      setActionVisible(
        sourceButton,
        !displayedSource.isEmpty && (showsActions || isSourceCopied),
        revealDuration: revealDuration
      )
      if let stickyResultActionView, let resultStorage {
        stickyResultActionView.isHidden = transition != nil
        stickyResultActionView.configure(
          identifier: "history-action-copy-result-\(identifierSuffix)",
          isLongEntry: isLongEntry,
          isVisible: resultStorage.utf16Length > 0 && (showsActions || isResultCopied),
          isCopied: isResultCopied,
          revealDuration: revealDuration
        ) { [weak self] in
          self?.performExpandedResultCopy()
        }
      }
    }
    updateAccessibilityChildren()
    needsLayout = true
  }

  private func setActionVisible(
    _ button: HistoryEntryActionButton,
    _ visible: Bool,
    revealDuration: TimeInterval
  ) {
    if visible {
      button.reveal(duration: revealDuration)
    } else {
      button.conceal(duration: CidaMotion.iconInSeconds)
    }
    button.refreshHoverState()
  }

  private var showsExpandedActions: Bool {
    transition == nil
      && HistoryEntryActionPolicy.showsActions(
        isHovering: isPresentationActive && isHovering,
        state: entryState
      )
  }

  private func ensureActionButtons() -> (
    redo: HistoryEntryActionButton,
    copy: HistoryEntryActionButton
  ) {
    if let redoButton, let copyButton {
      return (redoButton, copyButton)
    }

    let redo = makeActionButton(
      icon: .rotateCounterclockwise,
      label: "重新处理",
      identifier: "history-action-redo-\(identifierSuffix)",
      action: #selector(redo(_:))
    )
    let copy = makeActionButton(
      icon: .copy,
      label: "复制结果",
      identifier: "history-action-copy-result-\(identifierSuffix)",
      action: #selector(copyResult(_:))
    )
    addSubview(redo)
    addSubview(copy)
    redoButton = redo
    copyButton = copy
    needsLayout = true
    updateAccessibilityChildren()
    return (redo, copy)
  }

  private func ensureCopySourceButton() -> HistoryEntryActionButton {
    if let copySourceButton { return copySourceButton }
    let button = makeActionButton(
      icon: .copy,
      label: "复制原文",
      identifier: "history-action-copy-source-\(identifierSuffix)",
      action: #selector(copySource(_:))
    )
    button.setAccessibilityValue("idle")
    addSubview(button)
    copySourceButton = button
    return button
  }

  private func ensureChevronButton() -> HistoryEntryActionButton {
    if let chevronButton { return chevronButton }
    let button = makeActionButton(
      icon: .chevronDown,
      label: "展开历史记录",
      identifier: "history-action-disclose-\(identifierSuffix)",
      action: #selector(toggleDisclosure(_:))
    )
    addSubview(button)
    chevronButton = button
    return button
  }

  private func updateAccessibilityChildren() {
    guard isPresentationActive else {
      setAccessibilityChildren([])
      return
    }
    var children: [Any]
    let contract = HistoryRenderContract(presentation: presentation)
    switch contract.content {
    case .foldedPreview:
      children = [expandAccessibilityElement, previewAccessibilityElement]
    case .sourceAndResult:
      children = contract.disclosureAction == .collapse ? [expandAccessibilityElement] : []
      if !displayedSource.isEmpty {
        children.append(sourceTextField)
      }
      if let resultContainer {
        children.append(resultContainer)
      }
    }
    for button in [redoButton, copyButton, copySourceButton, chevronButton] {
      if let button, !button.isHidden {
        children.append(button)
      }
    }
    if let stickyResultActionView,
      !stickyResultActionView.isHidden,
      let actionButton = stickyResultActionView.accessibilityActionButton
    {
      children.append(actionButton)
    }
    setAccessibilityChildren(children)
  }

  private func updatePresentationAccessibility() {
    previewAccessibilityElement.setAccessibilityIdentifier(
      "history-collapsed-result-\(identifierSuffix)"
    )
    previewAccessibilityElement.setAccessibilityValue(preview)
    setAccessibilityIdentifier("history-entry-\(identifierSuffix)")

    let contract = HistoryRenderContract(presentation: presentation)
    setAccessibilityLabel("\(contract.accessibilityLabelPrefix)，\(mode.title)，\(metadata)")
    setAccessibilityValue(contract.accessibilityValue)

    switch contract.disclosureAction {
    case .expand:
      expandAccessibilityElement.setAccessibilityIdentifier(
        "history-expand-\(identifierSuffix)"
      )
      expandAccessibilityElement.setAccessibilityLabel("展开历史记录")
      expandAccessibilityElement.setAccessibilityHelp("显示原文和完整结果")
      expandAccessibilityElement.setAccessibilityValue(preview)
    case .collapse, .none:
      expandAccessibilityElement.setAccessibilityIdentifier(
        "history-collapse-\(identifierSuffix)"
      )
      expandAccessibilityElement.setAccessibilityLabel("收起历史记录")
      expandAccessibilityElement.setAccessibilityHelp("隐藏原文和完整结果")
      expandAccessibilityElement.setAccessibilityValue(metadata)
    }
    updateAccessibilityChildren()
  }

  private func makeActionButton(
    icon: LucideIconName,
    label: String,
    identifier: String,
    action: Selector
  ) -> HistoryEntryActionButton {
    let button = HistoryEntryActionButton(frame: .zero)
    button.target = self
    button.action = action
    button.normalTintColor = Self.tertiaryTextColor
    button.hoverTintColor = Self.secondaryTextColor
    button.isHidden = true
    button.setAccessibilityElement(true)
    button.setAccessibilityRole(.button)
    let accessibilityDescription =
      switch label {
      case "重新处理": "重新处理这条历史记录"
      case "复制原文": "复制这条历史记录的完整原文"
      case "展开历史记录": "展开这条历史记录"
      default: "复制这条历史记录的完整结果"
      }
    button.image = Self.describedIcon(icon, description: accessibilityDescription)
    button.iconImage = LucideIconAsset.image(for: icon)
    button.setAccessibilityLabel(accessibilityDescription)
    button.setAccessibilityHelp(accessibilityDescription)
    button.setAccessibilityIdentifier(identifier)
    return button
  }

  /// A copy of the shared icon carrying the button's description for the
  /// accessibility audit; the copy is never drawn.
  private static func describedIcon(_ icon: LucideIconName, description: String) -> NSImage? {
    let image = LucideIconAsset.image(for: icon)?.copy() as? NSImage
    image?.isTemplate = true
    image?.accessibilityDescription = description
    return image
  }

  @objc
  private func redo(_ sender: NSButton) {
    onRedo?()
  }

  @objc
  private func toggleDisclosure(_ sender: NSButton) {
    switch HistoryRenderContract(presentation: presentation).disclosureAction {
    case .expand:
      onExpand?()
    case .collapse:
      onCollapse?()
    case .none:
      break
    }
  }

  @objc
  private func copyResult(_ sender: NSButton) {
    onCopyResult?()
    copyResetWorkItem?.cancel()
    (sender as? HistoryEntryActionButton)?.showIcon(
      LucideIconAsset.image(for: .check),
      feedbackTint: Self.accentColor,
      swapDuration: CidaMotion.iconSwapSeconds
    )
    sender.setAccessibilityLabel("已复制这条历史记录的完整结果")
    let entryID = self.entryID
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.entryID == entryID else { return }
      self.resetCopyFeedback()
      self.copyResetWorkItem = nil
    }
    copyResetWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(CidaMotion.copiedHoldMilliseconds),
      execute: workItem
    )
  }

  @objc
  private func copySource(_ sender: NSButton) {
    onCopySource?()
    sourceCopyResetWorkItem?.cancel()
    isSourceCopied = true
    (sender as? HistoryEntryActionButton)?.showIcon(
      LucideIconAsset.image(for: .check),
      feedbackTint: Self.accentColor,
      swapDuration: CidaMotion.iconSwapSeconds
    )
    sender.setAccessibilityLabel("已复制这条历史记录的完整原文")
    sender.setAccessibilityValue("copied")
    updateActionVisibility()
    let entryID = self.entryID
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.entryID == entryID else { return }
      self.isSourceCopied = false
      self.resetSourceCopyFeedback()
      self.updateActionVisibility()
      self.sourceCopyResetWorkItem = nil
    }
    sourceCopyResetWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(CidaMotion.copiedHoldMilliseconds),
      execute: workItem
    )
  }

  private func performExpandedResultCopy() {
    guard (resultStorage?.utf16Length ?? 0) > 0 else { return }
    onCopyResult?()
    resultCopyResetWorkItem?.cancel()
    isResultCopied = true
    updateActionVisibility()
    let entryID = self.entryID
    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.entryID == entryID else { return }
      self.isResultCopied = false
      self.updateActionVisibility()
      self.resultCopyResetWorkItem = nil
    }
    resultCopyResetWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(CidaMotion.copiedHoldMilliseconds),
      execute: workItem
    )
  }

  private func resetCopyFeedback() {
    copyButton?.showIcon(
      LucideIconAsset.image(for: .copy),
      feedbackTint: nil,
      swapDuration: CidaMotion.iconSwapSeconds
    )
    copyButton?.setAccessibilityLabel("复制这条历史记录的完整结果")
  }

  private func resetSourceCopyFeedback() {
    copySourceButton?.showIcon(
      LucideIconAsset.image(for: .copy),
      feedbackTint: nil,
      swapDuration: CidaMotion.iconSwapSeconds
    )
    copySourceButton?.setAccessibilityLabel("复制这条历史记录的完整原文")
    copySourceButton?.setAccessibilityValue("idle")
  }
}

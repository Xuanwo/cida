import AppKit
import CoreImage
import QuartzCore

@MainActor
protocol HistoryResultHeightChangeHosting: AnyObject {
  func historyResultHeightWillChange(by delta: CGFloat, animated: Bool)
}

/// The Pencil `Entry Result` text style shared by the expanded result renderer
/// and the folded preview, so folding never changes glyph placement.
@MainActor
enum HistoryResultTextStyle {
  static let attributes: [NSAttributedString.Key: Any] = {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.minimumLineHeight = HistoryEntryPencilLayout.resultLineHeight
    paragraphStyle.maximumLineHeight = HistoryEntryPencilLayout.resultLineHeight
    return [
      .font: CidaDesign.appKitBody(16),
      .foregroundColor: CidaDesign.Palette.textPrimary.appKit,
      .paragraphStyle: paragraphStyle.copy() as! NSParagraphStyle,
    ]
  }()
}

@MainActor
final class HistoryResultTextCoordinator: NSObject {
  private var entryID: UUID?
  private var renderedPresentationRevision = 0
  private var pendingPresentationRevision = 0
  private var renderedUTF16Length = 0
  private weak var pendingLayoutContainer: HistoryResultTextContainer?
  private var layoutTask: Task<Void, Never>?
  private var isPerformingLayout = false
  private var lastLayoutUptime = 0.0
  private weak var observedResultStorage: HistoryResultStorage?
  private weak var observedContainer: HistoryResultTextContainer?

  private static let minimumLayoutInterval = 0.1

  override init() {
    super.init()
  }

  deinit {
    layoutTask?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  func detach(from container: HistoryResultTextContainer) {
    layoutTask?.cancel()
    layoutTask = nil
    pendingLayoutContainer = nil
    NotificationCenter.default.removeObserver(
      self,
      name: .cidaHistoryResultStorageDidAppend,
      object: observedResultStorage
    )
    observedResultStorage = nil
    if observedContainer === container {
      observedContainer = nil
    }
    entryID = nil
    renderedPresentationRevision = 0
    pendingPresentationRevision = 0
    renderedUTF16Length = 0
    lastLayoutUptime = 0
    container.onWidthChange = nil
    container.onLineWrap = nil
  }

  func observeStreamingUpdates(
    from resultStorage: HistoryResultStorage,
    in container: HistoryResultTextContainer
  ) {
    observedContainer = container
    container.onLineWrap = { [weak self, weak container] in
      guard let self, let container else { return }
      self.layoutNow(of: container)
    }
    guard observedResultStorage !== resultStorage else { return }

    NotificationCenter.default.removeObserver(
      self,
      name: .cidaHistoryResultStorageDidAppend,
      object: observedResultStorage
    )
    observedResultStorage = resultStorage
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(resultStorageDidAppend(_:)),
      name: .cidaHistoryResultStorageDidAppend,
      object: resultStorage
    )
  }

  @objc
  private func resultStorageDidAppend(_ notification: Notification) {
    guard
      let resultStorage = notification.object as? HistoryResultStorage,
      resultStorage === observedResultStorage,
      let container = observedContainer
    else {
      return
    }

    if let revision = notification.userInfo?[
      HistoryResultStorageNotificationKey.presentationRevision
    ] as? Int {
      pendingPresentationRevision = max(pendingPresentationRevision, revision)
    }
    container.setStreaming(true)
    // Glyphs are presented on this display pulse; only the natural-height
    // document layout stays coalesced.
    flushPendingResult(to: container)
    scheduleStreamingLayout(of: container)
  }

  func updateText(
    _ resultStorage: HistoryResultStorage,
    entryID: UUID,
    presentationRevision: Int,
    latestPresentationDelta: String?,
    isStreaming: Bool,
    in container: HistoryResultTextContainer
  ) {
    guard self.entryID == entryID else {
      replaceText(
        resultStorage.string,
        entryID: entryID,
        presentationRevision: presentationRevision,
        isStreaming: isStreaming,
        in: container
      )
      return
    }

    if presentationRevision > renderedPresentationRevision,
      let pendingSuffix = resultStorage.suffix(fromUTF16Offset: renderedUTF16Length)
    {
      // Record the rendered range before appending: a wrapped line lays out
      // synchronously and re-enters the coordinator through `layoutNow`.
      renderedPresentationRevision = presentationRevision
      renderedUTF16Length = resultStorage.utf16Length
      container.append(pendingSuffix, isStreaming: isStreaming)
      container.setStreaming(isStreaming)
      return
    }

    if presentationRevision == renderedPresentationRevision {
      container.setStreaming(isStreaming)
      return
    }
    replaceText(
      resultStorage.string,
      entryID: entryID,
      presentationRevision: presentationRevision,
      isStreaming: isStreaming,
      in: container
    )
  }

  func replaceText(
    _ text: String,
    entryID: UUID,
    presentationRevision: Int,
    isStreaming: Bool,
    in container: HistoryResultTextContainer
  ) {
    self.entryID = entryID
    renderedPresentationRevision = presentationRevision
    pendingPresentationRevision = presentationRevision
    renderedUTF16Length = (text as NSString).length
    container.replaceText(text)
    container.setStreaming(isStreaming)
  }

  func scheduleLayout(of container: HistoryResultTextContainer) {
    guard container.hasPendingDocumentLayout else { return }
    pendingLayoutContainer = container
    guard layoutTask == nil else { return }

    let elapsed = ProcessInfo.processInfo.systemUptime - lastLayoutUptime
    let delay = max(0, Self.minimumLayoutInterval - elapsed)
    layoutTask = Task { @MainActor [weak self] in
      if delay > 0 {
        try? await Task.sleep(for: .milliseconds(Int64(ceil(delay * 1_000))))
      }
      guard !Task.isCancelled, let self else { return }
      self.layoutTask = nil
      self.performPendingLayout()
    }
  }

  /// Bypasses the coalescing interval, e.g. when a streamed line wraps and the
  /// record must grow on this pulse rather than up to 100 ms later.
  func layoutNow(of container: HistoryResultTextContainer, publishesHeight: Bool = true) {
    layoutTask?.cancel()
    layoutTask = nil
    pendingLayoutContainer = container
    // A wrap detected while this coordinator is already flushing is covered by
    // the layout pass that is in progress.
    guard !isPerformingLayout else { return }
    performPendingLayout(publishesHeight: publishesHeight)
  }

  private func scheduleStreamingLayout(of container: HistoryResultTextContainer) {
    pendingLayoutContainer = container
    guard layoutTask == nil else { return }

    let elapsed = ProcessInfo.processInfo.systemUptime - lastLayoutUptime
    guard lastLayoutUptime == 0 || elapsed >= Self.minimumLayoutInterval else {
      return
    }
    performPendingLayout()
  }

  private func performPendingLayout(publishesHeight: Bool = true) {
    guard !isPerformingLayout, let container = pendingLayoutContainer else { return }
    isPerformingLayout = true
    defer { isPerformingLayout = false }
    pendingLayoutContainer = nil
    flushPendingResult(to: container)
    guard container.hasPendingDocumentLayout else {
      container.commitCompletedGlyphReveals()
      return
    }
    lastLayoutUptime = ProcessInfo.processInfo.systemUptime
    let previousHeight = container.naturalTextHeight
    let height = container.updateDocumentLayout()
    if publishesHeight, abs(previousHeight - height) > 0.5 {
      container.scheduleNaturalHeightPublication(heightDelta: height - previousHeight)
    }
    container.updateStreamingCaretFrame()
  }

  private func flushPendingResult(to container: HistoryResultTextContainer) {
    guard
      let resultStorage = observedResultStorage,
      let pendingSuffix = resultStorage.suffix(fromUTF16Offset: renderedUTF16Length)
    else {
      return
    }
    renderedPresentationRevision = max(
      renderedPresentationRevision,
      pendingPresentationRevision
    )
    if !pendingSuffix.isEmpty {
      renderedUTF16Length = resultStorage.utf16Length
      container.append(pendingSuffix, isStreaming: true)
    }
  }
}

struct StreamGlyphFadeStyle: Equatable, Sendable {
  let opacity: CGFloat
  let blurRadius: CGFloat
}

/// Pencil `motion-char-in-ms`: each presented glyph run fades in from
/// transparent and unblurs from `motion-blur-char-px` over one ease-out.
enum StreamGlyphFadeAnimation {
  static let duration = CidaMotion.characterInSeconds

  static func style(elapsed: CFTimeInterval) -> StreamGlyphFadeStyle {
    let progress = min(1, max(0, elapsed / duration))
    let easedProgress = 1 - pow(1 - progress, 3)
    return StreamGlyphFadeStyle(
      opacity: CGFloat(easedProgress),
      blurRadius: CidaMotion.characterBlurRadius * CGFloat(1 - easedProgress)
    )
  }
}

@MainActor
final class StreamingResultTextView: NSTextView {}

@MainActor
final class HistoryResultTextContainerPool {
  static let shared = HistoryResultTextContainerPool()
  static let defaultReserveCount = 3

  private var available: [HistoryResultTextContainer] = []
  private var leasedIdentifiers: Set<ObjectIdentifier> = []

  private init() {}

  func prewarm(minimumAvailableCount: Int = defaultReserveCount) {
    guard minimumAvailableCount > available.count else { return }
    for _ in available.count..<minimumAvailableCount {
      available.append(HistoryResultTextContainer())
    }
  }

  func acquire() -> HistoryResultTextContainer {
    let container = available.popLast() ?? HistoryResultTextContainer()
    leasedIdentifiers.insert(ObjectIdentifier(container))
    return container
  }

  func release(_ container: HistoryResultTextContainer) {
    let identifier = ObjectIdentifier(container)
    guard leasedIdentifiers.remove(identifier) != nil else { return }
    container.prepareForReuse()
    available.append(container)
  }

  #if DEBUG
    var availableContainerIdentifiersForTesting: Set<ObjectIdentifier> {
      Set(available.map(ObjectIdentifier.init))
    }

    var leasedContainerCountForTesting: Int {
      leasedIdentifiers.count
    }
  #endif
}

@MainActor
final class HistoryResultTextContainer: NSView {
  static let minimumHeight = HistoryEntryPencilLayout.resultLineHeight
  private static let minimumStreamingTextViewCapacity: CGFloat = 1_024

  private let renderingView: StreamingResultRenderingView
  private var selectionTextView: StreamingResultTextView?
  private var selectionTextStorage: NSTextStorage?
  private var selectionLayoutManager: NSLayoutManager?
  private var selectionTextContainer: NSTextContainer?
  var onWidthChange: (() -> Void)?
  /// Called when an appended run started a new line, so the record can grow on
  /// the same display pulse.
  var onLineWrap: (() -> Void)?
  private(set) var naturalTextHeight = HistoryResultTextContainer.minimumHeight
  private(set) var contentTextHeight = HistoryResultTextContainer.minimumHeight

  private let caretLayer = CALayer()
  private let contentEndLayoutView = ResultContentEndLayoutView()
  private var revealFragments: [GlyphRevealFragmentView] = []
  private var revealCompletionWorkItem: DispatchWorkItem?
  private var isStreaming = false
  private var needsFullTextLayout = true
  private var pendingTextLayoutRange: NSRange?
  private var intrinsicSizeInvalidationIsScheduled = false
  private var pendingNaturalHeightDelta: CGFloat = 0
  private var pendingNaturalHeightAnimated = false
  private var naturalHeightPublicationGeneration = 0
  private var streamingTextViewHeightCapacity: CGFloat = 0
  private var selectionIsActive = false
  private var resultAccessibilityIdentifier: String?

  private(set) var fullReplacementCount = 0
  private(set) var incrementalAppendCount = 0
  private(set) var documentLayoutCount = 0

  var streamingCaretIsVisible: Bool {
    isStreaming && caretLayer.opacity > 0
  }

  var streamingCaretFrame: CGRect {
    caretLayer.frame
  }

  var renderedString: String {
    renderingView.textStorage.string
  }

  var textView: StreamingResultTextView {
    materializeSelectionTextView()
  }

  var hasPendingDocumentLayout: Bool {
    needsFullTextLayout || pendingTextLayoutRange != nil
  }

  #if DEBUG
    var glyphRevealFragmentCountForTesting: Int {
      revealFragments.count
    }
    var glyphRevealAnimationForTesting: CABasicAnimation? {
      revealFragments.last?.layer?.animation(forKey: GlyphRevealFragmentView.opacityAnimationKey)
        as? CABasicAnimation
    }
    var glyphRevealBlurAnimationForTesting: CABasicAnimation? {
      revealFragments.last?.layer?.animation(forKey: GlyphRevealFragmentView.blurAnimationKey)
        as? CABasicAnimation
    }
    var glyphRevealBlurRadiusForTesting: CGFloat {
      revealFragments.last?.modelBlurRadius ?? 0
    }
    var glyphRevealCommittedLengthForTesting: Int {
      renderingView.revealCommittedUTF16Length ?? renderingView.textStorage.length
    }
    var glyphRevealFragmentFramesForTesting: [CGRect] {
      revealFragments.map(\.frame)
    }
    var streamingVisibleFragmentFramesForTesting: [CGRect] {
      renderingView.visibleFragmentFramesForTesting
    }
  #endif

  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: naturalTextHeight)
  }

  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = abs(frame.width - newSize.width) > 0.5
    super.setFrameSize(newSize)
    if widthChanged {
      needsFullTextLayout = true
      onWidthChange?()
    }
  }

  override init(frame frameRect: NSRect) {
    renderingView = StreamingResultRenderingView()
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true

    renderingView.autoresizingMask = [.width]
    renderingView.setAccessibilityLabel("处理结果")
    renderingView.isHidden = false
    renderingView.setAccessibilityElement(true)
    addSubview(renderingView)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("处理结果区域")

    caretLayer.backgroundColor = CidaDesign.Palette.accent.appKit.cgColor
    caretLayer.cornerRadius = 1
    caretLayer.opacity = 0
    renderingView.layer?.addSublayer(caretLayer)

    addSubview(contentEndLayoutView)
    #if DEBUG
      contentEndLayoutView.setAccessibilityElement(true)
      contentEndLayoutView.setAccessibilityRole(.group)
      contentEndLayoutView.setAccessibilityLabel("Result content end")
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func mouseDown(with event: NSEvent) {
    guard !isStreaming else { return }
    activateSelection()
    let textView = textView
    _ = window?.makeFirstResponder(textView)
    textView.mouseDown(with: event)
  }

  func append(_ suffix: String, isStreaming: Bool = false) {
    guard !suffix.isEmpty else { return }
    guard let textStorage else { return }
    let appendedRange = NSRange(location: textStorage.length, length: suffix.utf16.count)
    let previousLastLine = renderingView.lastTextLineFrame()
    let attributedSuffix = NSAttributedString(string: suffix, attributes: textAttributes())
    renderingView.append(attributedSuffix)
    if selectionIsActive {
      selectionTextStorage?.append(attributedSuffix)
    }
    incrementalAppendCount &+= 1
    pendingTextLayoutRange =
      pendingTextLayoutRange.map {
        NSUnionRange($0, appendedRange)
      } ?? appendedRange

    guard isStreaming else { return }

    // Streamed glyphs are laid out on the pulse that presents them so the
    // caret, the reveal fragments, and any wrap are visible immediately.
    renderingView.ensureLayout(forCharacterRange: appendedRange)
    let lastLine = renderingView.lastTextLineFrame()
    let wrapped =
      previousLastLine.map { previous in
        lastLine.map { abs($0.minY - previous.minY) > 0.5 } ?? false
      } ?? false
    let animates =
      window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if animates {
      beginGlyphReveal(characterRange: appendedRange)
    } else {
      renderingView.setNeedsDisplay(
        renderingView.boundingRect(forCharacterRange: appendedRange).insetBy(dx: -2, dy: -2)
      )
    }
    if wrapped {
      repositionGlyphReveals()
      if let previousLastLine, let lastLine {
        renderingView.setNeedsDisplay(previousLastLine.union(lastLine).insetBy(dx: -2, dy: -2))
      }
    }
    updateStreamingCaretFrame()
    if wrapped {
      onLineWrap?()
    }
  }

  #if DEBUG
    func setContentEndAccessibilityIdentifier(_ identifier: String) {
      contentEndLayoutView.setAccessibilityIdentifier(identifier)
    }
  #endif

  func setResultAccessibilityIdentifier(_ identifier: String) {
    guard resultAccessibilityIdentifier != identifier else { return }
    resultAccessibilityIdentifier = identifier
    selectionTextView?.setAccessibilityIdentifier(identifier)
    renderingView.setAccessibilityIdentifier(identifier)
  }

  func replaceText(_ text: String) {
    cancelGlyphReveals()
    deactivateSelection(clearMaterializedText: true)
    let attributedText = NSAttributedString(string: text, attributes: textAttributes())
    renderingView.replaceText(with: attributedText)
    needsFullTextLayout = true
    pendingTextLayoutRange = nil
    fullReplacementCount &+= 1
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onWidthChange = nil
    onLineWrap = nil
    naturalHeightPublicationGeneration &+= 1
    intrinsicSizeInvalidationIsScheduled = false
    pendingNaturalHeightDelta = 0
    pendingNaturalHeightAnimated = false
    isStreaming = false
    needsFullTextLayout = true
    pendingTextLayoutRange = nil
    naturalTextHeight = Self.minimumHeight
    contentTextHeight = Self.minimumHeight
    streamingTextViewHeightCapacity = min(
      streamingTextViewHeightCapacity,
      Self.minimumStreamingTextViewCapacity
    )
    selectionIsActive = false
    if let selectionTextView, window?.firstResponder === selectionTextView {
      window?.makeFirstResponder(nil)
    }
    selectionTextView?.removeFromSuperview()
    selectionTextView = nil
    selectionTextStorage = nil
    selectionLayoutManager = nil
    selectionTextContainer = nil
    cancelGlyphReveals()
    renderingView.replaceText(with: NSAttributedString())
    renderingView.isHidden = false
    renderingView.setAccessibilityElement(true)
    resultAccessibilityIdentifier = nil
    renderingView.setAccessibilityIdentifier(nil)
    #if DEBUG
      contentEndLayoutView.setAccessibilityIdentifier(nil)
    #endif
    caretLayer.removeAllAnimations()
    caretLayer.opacity = 0
    contentEndLayoutView.frame = .zero
    fullReplacementCount = 0
    incrementalAppendCount = 0
    documentLayoutCount = 0
  }

  func setStreaming(_ streaming: Bool) {
    guard isStreaming != streaming else { return }
    isStreaming = streaming
    if streaming {
      deactivateSelection(clearMaterializedText: true)
    }
    if streaming {
      caretLayer.opacity = 1
      updateCaretPulse()
    } else {
      // Pencil T3: the caret fades over motion-cursor-out-ms while the last
      // revealed glyphs finish their own fade.
      scheduleFinalGlyphRevealCommit()
      caretLayer.removeAnimation(forKey: "waiting-pulse")
      if window == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        caretLayer.opacity = 0
      } else {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = caretLayer.presentation()?.opacity ?? caretLayer.opacity
        fade.toValue = 0
        fade.duration = CidaMotion.cursorOutSeconds
        caretLayer.add(fade, forKey: "completion-fade")
        caretLayer.opacity = 0
      }
    }
    updateStreamingCaretFrame()
  }

  func updateDocumentLayout() -> CGFloat {
    documentLayoutCount &+= 1
    let availableWidth = max(1, bounds.width)
    let previousContentTextHeight = contentTextHeight
    let requiresFullRedraw = needsFullTextLayout
    renderingView.setTextContainerWidth(availableWidth)
    selectionTextView?.textContainer?.containerSize = NSSize(
      width: availableWidth,
      height: CGFloat.greatestFiniteMagnitude
    )

    if needsFullTextLayout {
      renderingView.ensureLayoutForDocument()
      needsFullTextLayout = false
      pendingTextLayoutRange = nil
    } else if let pendingTextLayoutRange {
      renderingView.ensureLayout(forCharacterRange: pendingTextLayoutRange)
      self.pendingTextLayoutRange = nil
    }
    let usedRect = renderingView.usageBounds
    contentTextHeight = max(
      Self.minimumHeight,
      ceil(
        usedRect.height + StreamingResultRenderingView.verticalTextInset * 2
      )
    )
    // The caret fits inside the last laid-out line. Keeping the outer height
    // identical before and after completion prevents a second history relayout
    // roughly one coalescing interval after the terminal stream update.
    naturalTextHeight = contentTextHeight
    let textViewHeight = allocatedTextViewHeight(for: naturalTextHeight)
    if let selectionTextView,
      abs(selectionTextView.frame.height - textViewHeight) > 0.5
    {
      selectionTextView.setFrameSize(
        NSSize(width: availableWidth, height: textViewHeight)
      )
      selectionTextView.setFrameOrigin(.zero)
    }
    renderingView.setFrameSize(
      NSSize(width: availableWidth, height: textViewHeight)
    )
    renderingView.setFrameOrigin(.zero)
    renderingView.invalidateTextLayout(
      previousContentHeight: previousContentTextHeight,
      contentHeight: contentTextHeight,
      requiresFullRedraw: requiresFullRedraw
    )
    contentEndLayoutView.frame = NSRect(
      x: min(max(0, usedRect.maxX), max(0, availableWidth - 2)),
      y: max(0, usedRect.maxY + StreamingResultRenderingView.verticalTextInset - 2),
      width: 2,
      height: 2
    )
    if requiresFullRedraw {
      repositionGlyphReveals()
    }
    commitCompletedGlyphReveals()
    return naturalTextHeight
  }

  private func allocatedTextViewHeight(for naturalHeight: CGFloat) -> CGFloat {
    if isStreaming, streamingTextViewHeightCapacity < naturalHeight {
      var capacity = max(
        Self.minimumStreamingTextViewCapacity,
        streamingTextViewHeightCapacity
      )
      while capacity < naturalHeight {
        capacity *= 2
      }
      streamingTextViewHeightCapacity = capacity
    }
    return max(naturalHeight, streamingTextViewHeightCapacity)
  }

  private func activateSelection() {
    guard !isStreaming, !selectionIsActive else { return }
    let textView = materializeSelectionTextView()
    selectionTextStorage?.setAttributedString(renderingView.textStorage)
    selectionIsActive = true
    textView.isSelectable = true
    renderingView.isHidden = true
    renderingView.setAccessibilityElement(false)
    textView.isHidden = false
    textView.setAccessibilityElement(true)
    textView.needsDisplay = true
  }

  private func deactivateSelection(clearMaterializedText: Bool) {
    guard
      selectionIsActive
        || (clearMaterializedText && (selectionTextStorage?.length ?? 0) > 0)
    else {
      return
    }
    if let selectionTextView, window?.firstResponder === selectionTextView {
      window?.makeFirstResponder(nil)
    }
    selectionIsActive = false
    selectionTextView?.isSelectable = false
    selectionTextView?.isHidden = true
    selectionTextView?.setAccessibilityElement(false)
    renderingView.isHidden = false
    renderingView.setAccessibilityElement(true)
    if clearMaterializedText {
      selectionTextStorage?.setAttributedString(NSAttributedString())
    }
  }

  #if DEBUG
    var selectionTextViewIsMaterializedForTesting: Bool {
      selectionTextView != nil
    }

    var selectionTextIsMaterializedForTesting: Bool {
      (selectionTextStorage?.length ?? 0) > 0
    }

    func activateSelectionForTesting() {
      activateSelection()
    }
  #endif

  func scheduleNaturalHeightPublication(heightDelta: CGFloat) {
    pendingNaturalHeightDelta += heightDelta
    // Pencil `motion-height-ms`: a streaming record grows with the height
    // transition; width relayouts and completed records resize immediately.
    pendingNaturalHeightAnimated =
      pendingNaturalHeightAnimated
      || (isStreaming && window != nil
        && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    guard !intrinsicSizeInvalidationIsScheduled else { return }
    intrinsicSizeInvalidationIsScheduled = true
    let generation = naturalHeightPublicationGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.naturalHeightPublicationGeneration == generation else { return }
      self.intrinsicSizeInvalidationIsScheduled = false
      let publishedHeightDelta = self.pendingNaturalHeightDelta
      let animated = self.pendingNaturalHeightAnimated
      self.pendingNaturalHeightDelta = 0
      self.pendingNaturalHeightAnimated = false
      var ancestor = self.superview
      while let current = ancestor {
        if let hostingView = current as? any HistoryResultHeightChangeHosting {
          hostingView.historyResultHeightWillChange(by: publishedHeightDelta, animated: animated)
          break
        }
        ancestor = current.superview
      }
      self.invalidateIntrinsicContentSize()
    }
  }

  func updateStreamingCaretFrame() {
    guard isStreaming else { return }
    let length = textStorage?.length ?? 0
    let origin: CGPoint
    if length == 0 {
      origin = CGPoint(x: 0, y: StreamingResultRenderingView.verticalTextInset + 3)
    } else if let lastLineFrame = renderingView.lastTextLineFrame() {
      origin = CGPoint(
        x: lastLineFrame.maxX + 3,
        y: lastLineFrame.minY + max(0, (lastLineFrame.height - CidaMotion.cursorHeight) / 2)
      )
    } else {
      let usageBounds = renderingView.usageBounds
      origin = CGPoint(
        x: usageBounds.maxX + 3,
        y: max(0, usageBounds.maxY - CidaMotion.cursorHeight)
      )
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    caretLayer.frame = CGRect(
      origin: origin,
      size: CGSize(width: CidaMotion.cursorWidth, height: CidaMotion.cursorHeight)
    )
    caretLayer.opacity = 1
    CATransaction.commit()
    updateCaretPulse()
  }

  private func updateCaretPulse() {
    guard isStreaming else { return }
    let shouldPulse =
      window != nil
      && (textStorage?.length ?? 0) == 0
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if shouldPulse, caretLayer.animation(forKey: "waiting-pulse") == nil {
      let pulse = CABasicAnimation(keyPath: "opacity")
      pulse.fromValue = CidaMotion.cursorMinimumOpacity
      pulse.toValue = 1
      pulse.duration = CidaMotion.breatheHalfCycleSeconds
      pulse.autoreverses = true
      pulse.repeatCount = .infinity
      pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      caretLayer.add(pulse, forKey: "waiting-pulse")
    } else if !shouldPulse {
      caretLayer.removeAnimation(forKey: "waiting-pulse")
    }
  }

  // MARK: - Glyph reveal

  private func beginGlyphReveal(characterRange: NSRange) {
    let fragment = GlyphRevealFragmentView(
      renderingView: renderingView,
      characterRange: characterRange,
      completesAt: CACurrentMediaTime() + StreamGlyphFadeAnimation.duration
    )
    if renderingView.revealCommittedUTF16Length == nil {
      renderingView.revealCommittedUTF16Length = characterRange.location
    }
    renderingView.addSubview(fragment)
    fragment.updateFrame()
    fragment.startReveal(duration: StreamGlyphFadeAnimation.duration)
    revealFragments.append(fragment)
  }

  private func repositionGlyphReveals() {
    for fragment in revealFragments {
      fragment.updateFrame()
    }
  }

  /// Fragments whose fade finished draw exactly what the rendering view would,
  /// so committing them is invisible and can ride the coalesced layout tick.
  func commitCompletedGlyphReveals(now: CFTimeInterval = CACurrentMediaTime()) {
    guard !revealFragments.isEmpty else { return }
    var committedLength = renderingView.revealCommittedUTF16Length ?? 0
    var dirtyRect = CGRect.null
    while let fragment = revealFragments.first, fragment.completesAt <= now + 0.000_5 {
      committedLength = max(committedLength, NSMaxRange(fragment.characterRange))
      dirtyRect = dirtyRect.union(fragment.frame)
      fragment.removeFromSuperview()
      revealFragments.removeFirst()
    }
    if revealFragments.isEmpty {
      renderingView.revealCommittedUTF16Length = nil
    } else {
      renderingView.revealCommittedUTF16Length = committedLength
    }
    if !dirtyRect.isNull {
      renderingView.setNeedsDisplay(dirtyRect)
    }
  }

  private func scheduleFinalGlyphRevealCommit() {
    revealCompletionWorkItem?.cancel()
    revealCompletionWorkItem = nil
    guard let last = revealFragments.last else { return }
    let delay = max(0, last.completesAt - CACurrentMediaTime())
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.revealCompletionWorkItem = nil
      self.commitCompletedGlyphReveals(now: .greatestFiniteMagnitude)
    }
    revealCompletionWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func cancelGlyphReveals() {
    revealCompletionWorkItem?.cancel()
    revealCompletionWorkItem = nil
    guard !revealFragments.isEmpty else {
      renderingView.revealCommittedUTF16Length = nil
      return
    }
    var dirtyRect = CGRect.null
    for fragment in revealFragments {
      dirtyRect = dirtyRect.union(fragment.frame)
      fragment.removeFromSuperview()
    }
    revealFragments.removeAll()
    renderingView.revealCommittedUTF16Length = nil
    if !dirtyRect.isNull {
      renderingView.setNeedsDisplay(dirtyRect)
    }
  }

  private var textStorage: NSTextStorage? {
    renderingView.textStorage
  }

  private func textAttributes() -> [NSAttributedString.Key: Any] {
    HistoryResultTextStyle.attributes
  }

  private func materializeSelectionTextView() -> StreamingResultTextView {
    if let selectionTextView {
      return selectionTextView
    }

    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(
      containerSize: NSSize(
        width: max(1, bounds.width),
        height: CGFloat.greatestFiniteMagnitude
      )
    )
    layoutManager.allowsNonContiguousLayout = true
    layoutManager.backgroundLayoutEnabled = false
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)

    let textView = StreamingResultTextView(frame: .zero, textContainer: textContainer)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = 0
    textView.drawsBackground = false
    textView.isEditable = false
    textView.isSelectable = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = false
    textView.usesFindBar = true
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isAutomaticTextCompletionEnabled = false
    textView.enabledTextCheckingTypes = 0
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = false
    textView.textContainerInset = NSSize(
      width: 0,
      height: StreamingResultRenderingView.verticalTextInset
    )
    textView.minSize = NSSize(width: 0, height: Self.minimumHeight)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.autoresizingMask = [.width]
    textView.setAccessibilityLabel("处理结果")
    if let resultAccessibilityIdentifier {
      textView.setAccessibilityIdentifier(resultAccessibilityIdentifier)
    }
    textView.isHidden = true
    textView.setAccessibilityElement(false)
    textView.wantsLayer = true
    textView.layerContentsRedrawPolicy = .onSetNeedsDisplay
    textView.layerContentsPlacement = .topLeft
    let height = allocatedTextViewHeight(for: naturalTextHeight)
    textView.frame = NSRect(x: 0, y: 0, width: max(1, bounds.width), height: height)
    addSubview(textView)

    selectionTextStorage = textStorage
    selectionLayoutManager = layoutManager
    selectionTextContainer = textContainer
    selectionTextView = textView
    return textView
  }
}

/// One presented glyph run during streaming. It paints its glyphs with the
/// shared layout manager at their document positions, so the rendering view can
/// skip them until the fade completes and then take over without any shift.
@MainActor
private final class GlyphRevealFragmentView: NSView {
  static let opacityAnimationKey = "glyph-reveal"
  static let blurAnimationKey = "glyph-reveal-blur"
  /// Room for the blur to spread beyond the glyph bounds.
  private static let margin: CGFloat = 6

  let characterRange: NSRange
  let completesAt: CFTimeInterval
  private weak var renderingView: StreamingResultRenderingView?
  private let blurFilter: CIFilter
  private(set) var modelBlurRadius: CGFloat = 0

  override var isFlipped: Bool { true }

  init(
    renderingView: StreamingResultRenderingView,
    characterRange: NSRange,
    completesAt: CFTimeInterval
  ) {
    self.renderingView = renderingView
    self.characterRange = characterRange
    self.completesAt = completesAt
    let filter = CIFilter(name: "CIGaussianBlur")!
    filter.name = "glyphRevealBlur"
    filter.setValue(CidaMotion.characterBlurRadius, forKey: kCIInputRadiusKey)
    blurFilter = filter
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  func updateFrame() {
    guard let renderingView else { return }
    let bounding = renderingView.boundingRect(forCharacterRange: characterRange)
    let nextFrame = bounding.insetBy(dx: -Self.margin, dy: -Self.margin).integral
    guard frame != nextFrame else { return }
    frame = nextFrame
    needsDisplay = true
  }

  func startReveal(duration: TimeInterval) {
    guard let layer else { return }
    contentFilters = [blurFilter]
    layer.setValue(CidaMotion.characterBlurRadius, forKeyPath: "filters.glyphRevealBlur.inputRadius")
    let initial = StreamGlyphFadeAnimation.style(elapsed: 0)

    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = Float(initial.opacity)
    opacity.toValue = 1
    opacity.duration = duration
    opacity.timingFunction = CidaMotion.easeOut
    layer.add(opacity, forKey: Self.opacityAnimationKey)
    alphaValue = 1

    let blur = CABasicAnimation(keyPath: "filters.glyphRevealBlur.inputRadius")
    blur.fromValue = initial.blurRadius
    blur.toValue = 0
    blur.duration = duration
    blur.timingFunction = CidaMotion.easeOut
    layer.add(blur, forKey: Self.blurAnimationKey)
    layer.setValue(0, forKeyPath: "filters.glyphRevealBlur.inputRadius")
    modelBlurRadius = 0
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let renderingView else { return }
    renderingView.drawGlyphs(
      forCharacterRange: characterRange,
      at: CGPoint(x: -frame.origin.x, y: -frame.origin.y)
    )
  }
}

@MainActor
private final class StreamingResultRenderingView: NSView {
  static let verticalTextInset: CGFloat = 0

  let textStorage: NSTextStorage
  private let layoutManager: NSLayoutManager

  private let textContainer: NSTextContainer
  private var lastDrawnFragmentFrames: [CGRect] = []
  /// While reveal fragments are alive, only glyphs before this UTF-16 offset
  /// are painted here; `nil` paints everything.
  var revealCommittedUTF16Length: Int?

  var usageBounds: CGRect {
    layoutManager.usedRect(for: textContainer)
  }

  #if DEBUG
    var visibleFragmentFramesForTesting: [CGRect] {
      lastDrawnFragmentFrames
    }
  #endif

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(
      containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    container.lineFragmentPadding = 0
    layoutManager.allowsNonContiguousLayout = true
    layoutManager.backgroundLayoutEnabled = false
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)

    textStorage = storage
    self.layoutManager = layoutManager
    textContainer = container
    super.init(frame: frameRect)

    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.masksToBounds = true
    setAccessibilityRole(.textArea)
  }

  convenience init() {
    self.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func accessibilityValue() -> Any? {
    textStorage.string
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let visibleTextRect = dirtyRect.offsetBy(dx: 0, dy: -Self.verticalTextInset)
    var glyphRange = layoutManager.glyphRange(
      forBoundingRect: visibleTextRect,
      in: textContainer
    )
    lastDrawnFragmentFrames.removeAll(keepingCapacity: true)
    layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
      _, usedRect, _, _, _ in
      let frame = usedRect.offsetBy(dx: 0, dy: Self.verticalTextInset)
      if frame.intersects(dirtyRect) {
        self.lastDrawnFragmentFrames.append(frame)
      }
    }
    if let revealCommittedUTF16Length, revealCommittedUTF16Length < textStorage.length {
      let committedGlyphCount =
        revealCommittedUTF16Length <= 0
        ? 0
        : layoutManager.glyphIndexForCharacter(at: revealCommittedUTF16Length)
      glyphRange = NSIntersectionRange(
        glyphRange,
        NSRange(location: 0, length: committedGlyphCount)
      )
    }
    guard glyphRange.length > 0 else { return }
    let origin = CGPoint(x: 0, y: Self.verticalTextInset)
    layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
    layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
  }

  func setTextContainerWidth(_ width: CGFloat) {
    guard abs(textContainer.size.width - width) > 0.5 else { return }
    textContainer.size = NSSize(
      width: width,
      height: CGFloat.greatestFiniteMagnitude
    )
    layoutManager.invalidateLayout(
      forCharacterRange: NSRange(location: 0, length: textStorage.length),
      actualCharacterRange: nil
    )
  }

  func append(_ attributedString: NSAttributedString) {
    textStorage.append(attributedString)
  }

  func replaceText(with attributedString: NSAttributedString) {
    textStorage.setAttributedString(attributedString)
  }

  func ensureLayoutForDocument() {
    guard textStorage.length > 0 else { return }
    layoutManager.ensureLayout(for: textContainer)
  }

  func ensureLayout(forCharacterRange range: NSRange) {
    guard
      range.location >= 0,
      range.length > 0,
      NSMaxRange(range) <= textStorage.length
    else {
      return
    }
    layoutManager.ensureLayout(forCharacterRange: range)
  }

  func lastTextLineFrame() -> CGRect? {
    let glyphCount = layoutManager.numberOfGlyphs
    guard glyphCount > 0 else { return nil }
    return layoutManager.lineFragmentUsedRect(
      forGlyphAt: glyphCount - 1,
      effectiveRange: nil
    ).offsetBy(dx: 0, dy: Self.verticalTextInset)
  }

  func boundingRect(forCharacterRange range: NSRange) -> CGRect {
    guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return .zero }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return .zero }
    return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
      .offsetBy(dx: 0, dy: Self.verticalTextInset)
  }

  func drawGlyphs(forCharacterRange range: NSRange, at origin: CGPoint) {
    guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return }
    let textOrigin = CGPoint(x: origin.x, y: origin.y + Self.verticalTextInset)
    layoutManager.drawBackground(forGlyphRange: glyphRange, at: textOrigin)
    layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: textOrigin)
  }

  func invalidateTextLayout(
    previousContentHeight: CGFloat,
    contentHeight: CGFloat,
    requiresFullRedraw: Bool
  ) {
    guard !requiresFullRedraw else {
      needsDisplay = true
      return
    }
    let dirtyTop = max(0, min(previousContentHeight, contentHeight) - 28)
    let dirtyBottom = max(previousContentHeight, contentHeight) + Self.verticalTextInset
    setNeedsDisplay(
      NSRect(
        x: 0,
        y: dirtyTop,
        width: max(1, bounds.width),
        height: max(1, dirtyBottom - dirtyTop)
      )
    )
  }
}

@MainActor
private final class ResultContentEndLayoutView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

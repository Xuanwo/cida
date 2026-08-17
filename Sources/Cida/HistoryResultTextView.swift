import AppKit
import CoreImage
import QuartzCore
import SwiftUI

@MainActor
protocol HistoryResultHeightChangeHosting: AnyObject {
  func historyResultHeightWillChange(by delta: CGFloat)
}

struct HistoryResultTextView: View {
  let entryID: UUID
  let resultStorage: HistoryResultStorage
  let presentationRevision: Int
  let latestPresentationDelta: String?
  let isStreaming: Bool

  var body: some View {
    NativeHistoryResultTextView(
      entryID: entryID,
      resultStorage: resultStorage,
      presentationRevision: presentationRevision,
      latestPresentationDelta: latestPresentationDelta,
      isStreaming: isStreaming
    )
  }

  @MainActor
  final class Coordinator: NSObject {
    private var entryID: UUID?
    private var renderedPresentationRevision = 0
    private var pendingPresentationRevision = 0
    private var renderedUTF16Length = 0
    private weak var pendingLayoutContainer: HistoryResultTextContainer?
    private var layoutTask: Task<Void, Never>?
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
    }

    func observeStreamingUpdates(
      from resultStorage: HistoryResultStorage,
      in container: HistoryResultTextContainer
    ) {
      observedContainer = container
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
        container.append(pendingSuffix, isStreaming: isStreaming)
        renderedPresentationRevision = presentationRevision
        renderedUTF16Length = resultStorage.utf16Length
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

    private func scheduleStreamingLayout(of container: HistoryResultTextContainer) {
      pendingLayoutContainer = container
      guard layoutTask == nil else { return }

      let elapsed = ProcessInfo.processInfo.systemUptime - lastLayoutUptime
      guard lastLayoutUptime == 0 || elapsed >= Self.minimumLayoutInterval else {
        return
      }
      performPendingLayout()
    }

    private func performPendingLayout() {
      guard let container = pendingLayoutContainer else { return }
      pendingLayoutContainer = nil
      flushPendingResult(to: container)
      guard container.hasPendingDocumentLayout else { return }
      lastLayoutUptime = ProcessInfo.processInfo.systemUptime
      let previousHeight = container.naturalTextHeight
      let height = container.updateDocumentLayout()
      if abs(previousHeight - height) > 0.5 {
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
      if !pendingSuffix.isEmpty {
        container.append(pendingSuffix, isStreaming: true)
        renderedUTF16Length = resultStorage.utf16Length
      }
      renderedPresentationRevision = max(
        renderedPresentationRevision,
        pendingPresentationRevision
      )
    }
  }
}

private struct NativeHistoryResultTextView: NSViewRepresentable {
  let entryID: UUID
  let resultStorage: HistoryResultStorage
  let presentationRevision: Int
  let latestPresentationDelta: String?
  let isStreaming: Bool

  func makeCoordinator() -> HistoryResultTextView.Coordinator {
    HistoryResultTextView.Coordinator()
  }

  func makeNSView(context: Context) -> HistoryResultTextContainer {
    let container = HistoryResultTextContainerPool.shared.acquire()
    container.setResultAccessibilityIdentifier("history-result-\(entryID.uuidString)")
    #if DEBUG
      container.setContentEndAccessibilityIdentifier(
        "history-result-content-end-\(entryID.uuidString)"
      )
    #endif
    installWidthRelayout(
      on: container,
      coordinator: context.coordinator
    )
    context.coordinator.replaceText(
      resultStorage.string,
      entryID: entryID,
      presentationRevision: presentationRevision,
      isStreaming: isStreaming,
      in: container
    )
    context.coordinator.observeStreamingUpdates(
      from: resultStorage,
      in: container
    )
    context.coordinator.scheduleLayout(of: container)
    return container
  }

  func updateNSView(_ container: HistoryResultTextContainer, context: Context) {
    container.setResultAccessibilityIdentifier("history-result-\(entryID.uuidString)")
    #if DEBUG
      container.setContentEndAccessibilityIdentifier(
        "history-result-content-end-\(entryID.uuidString)"
      )
    #endif
    installWidthRelayout(
      on: container,
      coordinator: context.coordinator
    )
    context.coordinator.observeStreamingUpdates(
      from: resultStorage,
      in: container
    )
    context.coordinator.updateText(
      resultStorage,
      entryID: entryID,
      presentationRevision: presentationRevision,
      latestPresentationDelta: latestPresentationDelta,
      isStreaming: isStreaming,
      in: container
    )
    if !isStreaming {
      context.coordinator.scheduleLayout(of: container)
    }
  }

  static func dismantleNSView(
    _ container: HistoryResultTextContainer,
    coordinator: HistoryResultTextView.Coordinator
  ) {
    coordinator.detach(from: container)
    HistoryResultTextContainerPool.shared.release(container)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView container: HistoryResultTextContainer,
    context _: Context
  ) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    return CGSize(width: width, height: container.naturalTextHeight)
  }

  private func installWidthRelayout(
    on container: HistoryResultTextContainer,
    coordinator: HistoryResultTextView.Coordinator
  ) {
    container.onWidthChange = { [weak container, weak coordinator] in
      guard let container, let coordinator else { return }
      coordinator.scheduleLayout(of: container)
    }
  }

}

struct StreamGlyphFadeStyle: Equatable, Sendable {
  let opacity: CGFloat
  let blurRadius: CGFloat
}

enum StreamGlyphFadeAnimation {
  static let duration = CidaMotion.characterInSeconds

  static func style(elapsed: CFTimeInterval) -> StreamGlyphFadeStyle {
    let progress = min(1, max(0, elapsed / duration))
    let easedProgress = 1 - pow(1 - progress, 3)
    return StreamGlyphFadeStyle(
      opacity: CGFloat(0.82 + 0.18 * easedProgress),
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
  static let minimumHeight: CGFloat = 26
  private static let minimumStreamingTextViewCapacity: CGFloat = 1_024

  private let renderingView: StreamingResultRenderingView
  private var selectionTextView: StreamingResultTextView?
  private var selectionTextStorage: NSTextStorage?
  private var selectionLayoutManager: NSLayoutManager?
  private var selectionTextContainer: NSTextContainer?
  var onWidthChange: (() -> Void)?
  private(set) var naturalTextHeight = HistoryResultTextContainer.minimumHeight
  private(set) var contentTextHeight = HistoryResultTextContainer.minimumHeight

  private let caretLayer = CALayer()
  private let tailRevealLayer = CAGradientLayer()
  private let tailRevealBlurFilter: CIFilter = {
    let filter = CIFilter(name: "CIGaussianBlur")!
    filter.name = "glyphRevealBlur"
    filter.setValue(0, forKey: kCIInputRadiusKey)
    return filter
  }()
  private let contentEndLayoutView = ResultContentEndLayoutView()
  private var isStreaming = false
  private var needsFullTextLayout = true
  private var pendingTextLayoutRange: NSRange?
  private var intrinsicSizeInvalidationIsScheduled = false
  private var pendingNaturalHeightDelta: CGFloat = 0
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
    var glyphRevealLayerCountForTesting: Int {
      tailRevealLayer.animation(forKey: "glyph-reveal") == nil ? 0 : 1
    }
    var glyphRevealAnimationForTesting: CABasicAnimation? {
      tailRevealLayer.animation(forKey: "glyph-reveal") as? CABasicAnimation
    }
    var glyphRevealBlurAnimationForTesting: CABasicAnimation? {
      tailRevealLayer.animation(forKey: "glyph-reveal-blur") as? CABasicAnimation
    }
    var glyphRevealBlurRadiusForTesting: CGFloat {
      CGFloat(
        (tailRevealBlurFilter.value(forKey: kCIInputRadiusKey) as? NSNumber)?.doubleValue ?? 0
      )
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

    renderingView.autoresizingMask = [.width]
    renderingView.setAccessibilityLabel("处理结果")
    renderingView.isHidden = false
    renderingView.setAccessibilityElement(true)
    addSubview(renderingView)

    tailRevealLayer.colors = [
      glyphRevealColor.withAlphaComponent(0).cgColor,
      glyphRevealColor.cgColor,
    ]
    tailRevealLayer.locations = [0, 0.35]
    tailRevealLayer.startPoint = CGPoint(x: 0.5, y: 0)
    tailRevealLayer.endPoint = CGPoint(x: 0.5, y: 1)
    tailRevealLayer.masksToBounds = true
    tailRevealLayer.backgroundFilters = [tailRevealBlurFilter]
    tailRevealLayer.opacity = 0
    renderingView.layer?.addSublayer(tailRevealLayer)

    caretLayer.backgroundColor =
      NSColor(
        red: 46 / 255,
        green: 107 / 255,
        blue: 79 / 255,
        alpha: 1
      ).cgColor
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
    let shouldAnimate =
      isStreaming
      && window != nil
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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

    if shouldAnimate {
      restartTailReveal()
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
    naturalHeightPublicationGeneration &+= 1
    intrinsicSizeInvalidationIsScheduled = false
    pendingNaturalHeightDelta = 0
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
    tailRevealLayer.removeAllAnimations()
    tailRevealLayer.opacity = 0
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
      cancelGlyphReveals()
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
    updateTailRevealFrame()
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
    guard !intrinsicSizeInvalidationIsScheduled else { return }
    intrinsicSizeInvalidationIsScheduled = true
    let generation = naturalHeightPublicationGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.naturalHeightPublicationGeneration == generation else { return }
      self.intrinsicSizeInvalidationIsScheduled = false
      let publishedHeightDelta = self.pendingNaturalHeightDelta
      self.pendingNaturalHeightDelta = 0
      var ancestor = self.superview
      while let current = ancestor {
        if let hostingView = current as? any HistoryResultHeightChangeHosting {
          hostingView.historyResultHeightWillChange(by: publishedHeightDelta)
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
        y: lastLineFrame.minY + max(0, (lastLineFrame.height - 20) / 2)
      )
    } else {
      let usageBounds = renderingView.usageBounds
      origin = CGPoint(
        x: usageBounds.maxX + 3,
        y: max(0, usageBounds.maxY - 20)
      )
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    caretLayer.frame = CGRect(origin: origin, size: CGSize(width: 2, height: 20))
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

  private func restartTailReveal() {
    updateTailRevealFrame()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    tailRevealLayer.removeAnimation(forKey: "glyph-reveal")
    tailRevealLayer.opacity = 0
    CATransaction.commit()

    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1 - StreamGlyphFadeAnimation.style(elapsed: 0).opacity
    animation.toValue = 0
    animation.duration = StreamGlyphFadeAnimation.duration
    animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
    tailRevealLayer.add(animation, forKey: "glyph-reveal")

    let blurAnimation = CABasicAnimation(
      keyPath: "backgroundFilters.glyphRevealBlur.inputRadius"
    )
    blurAnimation.fromValue = StreamGlyphFadeAnimation.style(elapsed: 0).blurRadius
    blurAnimation.toValue = 0
    blurAnimation.duration = StreamGlyphFadeAnimation.duration
    blurAnimation.timingFunction = animation.timingFunction
    tailRevealLayer.add(blurAnimation, forKey: "glyph-reveal-blur")
  }

  private func updateTailRevealFrame() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    tailRevealLayer.frame = CGRect(
      x: 0,
      y: max(0, contentTextHeight - 30),
      width: max(0, renderingView.frame.width),
      height: min(30, contentTextHeight)
    )
    CATransaction.commit()
  }

  private func cancelGlyphReveals() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    tailRevealLayer.removeAllAnimations()
    tailRevealBlurFilter.setValue(0, forKey: kCIInputRadiusKey)
    tailRevealLayer.opacity = 0
    CATransaction.commit()
  }

  private var glyphRevealColor: NSColor {
    NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 248 / 255, alpha: 1)
  }

  private var textStorage: NSTextStorage? {
    renderingView.textStorage
  }

  private static let resultTextAttributes: [NSAttributedString.Key: Any] = {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.minimumLineHeight = 26
    paragraphStyle.maximumLineHeight = 26
    return [
      .font: CidaDesign.appKitBody(16),
      .foregroundColor: NSColor(
        calibratedRed: 26 / 255,
        green: 26 / 255,
        blue: 24 / 255,
        alpha: 1
      ),
      .paragraphStyle: paragraphStyle.copy() as! NSParagraphStyle,
    ]
  }()

  private func textAttributes() -> [NSAttributedString.Key: Any] {
    Self.resultTextAttributes
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
    textView.textContainerInset = NSSize(width: 0, height: 2)
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

@MainActor
private final class StreamingResultRenderingView: NSView {
  static let verticalTextInset: CGFloat = 2

  let textStorage: NSTextStorage
  private let layoutManager: NSLayoutManager

  private let textContainer: NSTextContainer
  private var lastDrawnFragmentFrames: [CGRect] = []

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
    let glyphRange = layoutManager.glyphRange(
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

import AppKit
import SwiftUI

enum HistoryEntryActionPolicy {
  static func presentationState(
    isHovering: Bool,
    state: HistoryEntryState,
    copiedAction: RecordAction? = nil
  ) -> RecordActionPresentationState {
    if let copiedAction {
      return .copied(copiedAction)
    }
    return isHovering && state != .streaming ? .visible : .hidden
  }

  static func showsActions(isHovering: Bool, state: HistoryEntryState) -> Bool {
    presentationState(isHovering: isHovering, state: state) == .visible
  }
}

enum HistoryEntryPencilLayout {
  static let actionIconSize: CGFloat = 12
  static let actionGap: CGFloat = 12
  static let actionColumnWidth = actionIconSize + actionGap
  static let foldedHorizontalInset: CGFloat = 0
  static let foldedVerticalInset: CGFloat = 10
  static let foldedHeaderHeight: CGFloat = 16
  static let foldedPreviewHeight: CGFloat = 52
  static let foldedContentSpacing: CGFloat = 8
  static let latestSourceLineLimit = 2
  static let latestSourceLineHeight: CGFloat = 13 * 1.55
  static let latestSourcePreviewHeight = ceil(
    latestSourceLineHeight * CGFloat(latestSourceLineLimit)
  )
  static let latestSourceFadeHeight: CGFloat = 20
  static let foldedHeight =
    foldedVerticalInset * 2 + foldedHeaderHeight + foldedContentSpacing + foldedPreviewHeight
  static let foldedRowStride = foldedHeight + 1
}

private enum ComposerLayout {
  static func editorHeight(
    for metrics: ComposerTextMetrics,
    availableHeight: CGFloat
  ) -> CGFloat {
    switch metrics.presentationState {
    case .compact:
      return 27
    case .document:
      return min(220, max(150, availableHeight * 0.275))
    case .multiline(let visibleLineCount):
      return CGFloat(min(5, max(2, visibleLineCount)) * 26 + 16)
    }
  }
}

struct MainWindowView: View {
  let model: AppModel
  let automaticallyFocusInput: Bool
  let animatesHistoryTransitions: Bool
  let openSettings: @MainActor () -> Void
  @State private var composerMetrics: ComposerTextMetrics

  init(
    model: AppModel,
    automaticallyFocusInput: Bool = true,
    animatesHistoryTransitions: Bool = true,
    openSettings: @escaping @MainActor () -> Void = {}
  ) {
    self.model = model
    self.automaticallyFocusInput = automaticallyFocusInput
    self.animatesHistoryTransitions = animatesHistoryTransitions
    self.openSettings = openSettings
    _composerMetrics = State(initialValue: ComposerTextMetrics(text: model.inputText))
  }

  var body: some View {
    WindowSurface {
      GeometryReader { geometry in
        VStack(spacing: 0) {
          MainTitlebar(
            model: model,
            openSettings: openSettings
          )
          ZStack(alignment: .bottom) {
            HistoryStream(
              model: model,
              animatesTransitions: animatesHistoryTransitions
            )
            .padding(
              .bottom,
              Self.compactComposerHeight
                + composerHeightDelta(
                  for: composerMetrics,
                  availableHeight: geometry.size.height
                )
            )
            .animation(
              .easeOut(duration: CidaMotion.heightSeconds),
              value: composerMetrics.presentationState
            )

            Composer(
              model: model,
              automaticallyFocusInput: automaticallyFocusInput,
              availableHeight: geometry.size.height,
              inputMetrics: $composerMetrics
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
          }
          .frame(maxHeight: .infinity)
          .background(CidaDesign.background)
        }
        .background(CidaDesign.background)
      }
    }
    .alert(
      "处理失败",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { presented in
          if !presented { model.errorMessage = nil }
        }
      )
    ) {
      Button("好") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private static let compactComposerHeight: CGFloat = 101

  private func composerHeightDelta(
    for metrics: ComposerTextMetrics,
    availableHeight: CGFloat
  ) -> CGFloat {
    let editorHeight = ComposerLayout.editorHeight(
      for: metrics,
      availableHeight: availableHeight
    )
    return max(0, editorHeight + 74 - Self.compactComposerHeight)
  }
}

private struct MainTitlebar: View {
  let model: AppModel
  let openSettings: @MainActor () -> Void

  var body: some View {
    ZStack {
      HStack {
        Color.clear.frame(width: 66, height: 16)
        Spacer(minLength: 20)
        ModelStatusChip(model: model, openSettings: openSettings)
      }
      .padding(.horizontal, 16)

      Text("辞达")
        .font(CidaDesign.brand(15, weight: .semibold))
        .tracking(3)
        .foregroundStyle(CidaDesign.accent)
        .accessibilityAddTraits(.isHeader)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 46)
  }
}

private struct ModelStatusChip: View {
  @Bindable var model: AppModel
  let openSettings: @MainActor () -> Void

  var body: some View {
    Button(action: openSettings) {
      HStack(spacing: 6) {
        Circle()
          .fill(CidaDesign.accent)
          .frame(width: 6, height: 6)
        Text(model.modelStatus)
          .font(CidaDesign.mainUI(11.5, weight: .medium))
          .lineLimit(1)
      }
      .foregroundStyle(CidaDesign.accent)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(CidaDesign.accentSoft)
      .clipShape(Capsule())
    }
    .buttonStyle(HoverFadeButtonStyle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("当前模型 \(model.modelStatus)")
    .accessibilityHint("打开设置")
    .accessibilityIdentifier("model-settings-button")
  }
}

private struct HistoryStream: View {
  nonisolated static let coordinateSpaceName = "history-scroll-viewport"

  let model: AppModel
  let animatesTransitions: Bool

  var body: some View {
    GeometryReader { _ in
      NativeHistoryScrollView(
        rootView: AnyView(
          HistoryEntriesDocument(
            model: model,
            animatesTransitions: animatesTransitions
          )
          .coordinateSpace(name: Self.coordinateSpaceName)
        ),
        rootIdentity: ObjectIdentifier(model)
      )
    }
    .clipped()
  }
}

private struct NativeHistoryScrollView: NSViewRepresentable {
  let rootView: AnyView
  let rootIdentity: ObjectIdentifier

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> HistoryNativeScrollView {
    let scrollView = HistoryNativeScrollView()
    context.coordinator.install(
      in: scrollView,
      rootView: rootView,
      rootIdentity: rootIdentity
    )
    return scrollView
  }

  func updateNSView(_ scrollView: HistoryNativeScrollView, context: Context) {
    context.coordinator.update(
      rootView: rootView,
      rootIdentity: rootIdentity,
      in: scrollView
    )
  }

  @MainActor
  final class Coordinator {
    private weak var scrollView: HistoryNativeScrollView?
    private let documentView = FlippedHistoryDocumentView()
    private let hostingView = ResizingHistoryHostingView(rootView: AnyView(EmptyView()))
    private var resizeIsScheduled = false
    private var isResizingDocument = false
    private var measuredNaturalContentHeight: CGFloat?
    private var allocatedHostingHeight: CGFloat = 0
    private var installedRootIdentity: ObjectIdentifier?

    func install(
      in scrollView: HistoryNativeScrollView,
      rootView: AnyView,
      rootIdentity: ObjectIdentifier
    ) {
      self.scrollView = scrollView
      installedRootIdentity = rootIdentity
      scrollView.onLayout = { [weak self] in
        self?.resizeDocument()
      }
      hostingView.sizingOptions = [.intrinsicContentSize]
      hostingView.rootView = rootView
      hostingView.onIntrinsicSizeInvalidation = { [weak self] in
        self?.scheduleResize()
      }
      hostingView.onResultHeightChange = { [weak self] delta in
        self?.applyResultHeightChange(delta)
      }
      documentView.setAccessibilityElement(false)
      hostingView.setAccessibilityLabel("历史记录内容")
      documentView.addSubview(hostingView)
      scrollView.documentView = documentView
      resizeDocument()
    }

    func update(
      rootView: AnyView,
      rootIdentity: ObjectIdentifier,
      in scrollView: HistoryNativeScrollView
    ) {
      self.scrollView = scrollView
      if installedRootIdentity != rootIdentity {
        installedRootIdentity = rootIdentity
        hostingView.rootView = rootView
      }
      scheduleResize()
    }

    private func scheduleResize() {
      guard !resizeIsScheduled else { return }
      resizeIsScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.resizeIsScheduled = false
        self.resizeDocument()
      }
    }

    private func resizeDocument() {
      guard let scrollView, !isResizingDocument else { return }
      isResizingDocument = true
      defer { isResizingDocument = false }
      let width = max(1, scrollView.contentSize.width)
      if abs(hostingView.frame.width - width) > 0.5 {
        hostingView.setFrameSize(
          NSSize(width: width, height: max(1, hostingView.frame.height))
        )
      }
      hostingView.layoutSubtreeIfNeeded()
      let naturalContentHeight = max(1, ceil(hostingView.fittingSize.height))
      measuredNaturalContentHeight = naturalContentHeight
      applyContentHeight(naturalContentHeight, width: width, in: scrollView)
    }

    private func applyResultHeightChange(_ delta: CGFloat) {
      guard let scrollView, let measuredNaturalContentHeight else {
        scheduleResize()
        return
      }
      let updatedHeight = max(1, measuredNaturalContentHeight + delta)
      self.measuredNaturalContentHeight = updatedHeight
      applyContentHeight(
        updatedHeight,
        width: max(1, scrollView.contentSize.width),
        in: scrollView
      )
    }

    private func applyContentHeight(
      _ naturalContentHeight: CGFloat,
      width: CGFloat,
      in scrollView: HistoryNativeScrollView
    ) {
      let documentHeight = max(
        scrollView.contentSize.height + HistoryNativeScrollView.scrollGeometryRunway,
        ceil(naturalContentHeight)
      )
      let documentSize = NSSize(width: width, height: documentHeight)
      if documentView.frame.size != documentSize {
        documentView.setFrameSize(documentSize)
      }
      let requiredHostingHeight = max(documentHeight, ceil(naturalContentHeight))
      if allocatedHostingHeight < requiredHostingHeight {
        let growthCapacity = max(
          scrollView.contentSize.height,
          min(max(requiredHostingHeight, 1_024), 8_192)
        )
        allocatedHostingHeight = ceil(requiredHostingHeight + growthCapacity)
      }
      let hostingSize = NSSize(width: width, height: allocatedHostingHeight)
      if hostingView.frame.size != hostingSize {
        hostingView.setFrameSize(hostingSize)
      }
      hostingView.setFrameOrigin(
        NSPoint(x: 0, y: documentHeight - allocatedHostingHeight)
      )
      CidaScrollIndicator.installed(in: scrollView)?.refresh()
    }

  }
}

@MainActor
final class HistoryNativeScrollView: NSScrollView {
  static let scrollGeometryRunway: CGFloat = 1
  var onLayout: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    drawsBackground = false
    contentView.drawsBackground = false
    borderType = .noBorder
    hasHorizontalScroller = false
    hasVerticalScroller = false
    horizontalScrollElasticity = .none
    verticalScrollElasticity = .automatic
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    onLayout?()
  }
}

@MainActor
private final class FlippedHistoryDocumentView: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
final class ResizingHistoryHostingView: NSHostingView<AnyView>, HistoryResultHeightChangeHosting {
  var onIntrinsicSizeInvalidation: (() -> Void)?
  var onResultHeightChange: ((CGFloat) -> Void)?
  private var suppressesNextIntrinsicResize = false

  func historyResultHeightWillChange(by delta: CGFloat) {
    suppressesNextIntrinsicResize = true
    onResultHeightChange?(delta)
  }

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    guard !suppressesNextIntrinsicResize else {
      suppressesNextIntrinsicResize = false
      return
    }
    onIntrinsicSizeInvalidation?()
  }
}

private struct HistoryEntriesDocument: View {
  @Bindable var model: AppModel
  let animatesTransitions: Bool

  var body: some View {
    let persistedPages = model.persistedHistoryPages
    let sessionEntries = model.sessionHistoryEntries

    VStack(spacing: 0) {
      Spacer(minLength: 0)
      VStack(spacing: 0) {
        HistoryPlaceholderRunway(entryCount: model.unloadedHistoryEntryCount)
        olderHistoryLoader
        longDocumentScrollRunway
        ForEach(persistedPages) { page in
          HistoryEntryPageDocument(
            entries: page.entries,
            standaloneEntryIDs: standaloneEntryIDs(in: page.entries),
            model: model,
            animatesTransitions: animatesTransitions
          )
          .equatable()
        }
        HistoryEntryPageDocument(
          entries: sessionEntries,
          standaloneEntryIDs: standaloneEntryIDs(in: sessionEntries),
          model: model,
          animatesTransitions: animatesTransitions
        )
        .equatable()
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 28)
    .padding(.top, 8)
    .padding(.bottom, 16)
    .background {
      HistoryFollowController(
        model: model
      )
    }
  }

  private func standaloneEntryIDs(in entries: [HistoryEntry]) -> Set<UUID> {
    var entryIDs = Set(
      entries.lazy.filter { model.isHistoryEntryManuallyExpanded($0.id) }.map(\.id)
    )
    entryIDs.formUnion(
      entries.lazy.filter {
        $0.isLatestInHistory || $0.id == model.automaticallyFoldingHistoryEntryID
      }.map(\.id)
    )
    return entryIDs
  }

  private var longDocumentScrollRunway: some View {
    // Keep the document structure stable when a newly submitted entry first
    // crosses the long-document threshold. Changing the view tree in the same
    // frame as insertion is visible as a hitch on a 120 Hz display.
    Color.clear.frame(height: 64)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var olderHistoryLoader: some View {
    if model.hasOlderHistory {
      Color.clear
        .frame(height: 1)
        .onGeometryChange(for: Bool.self) { geometry in
          geometry.frame(in: .named(HistoryStream.coordinateSpaceName)).maxY >= -512
        } action: { isNearViewport in
          guard isNearViewport else { return }
          model.loadOlderHistoryIfNeeded()
        }
        .accessibilityHidden(true)
    }
  }
}

private struct HistoryEntryPageDocument: View, Equatable {
  private struct Segment: Identifiable {
    enum Content {
      case folded([HistoryEntry])
      case standalone(HistoryEntry)
    }

    let id: UUID
    let content: Content
  }

  let entries: [HistoryEntry]
  let standaloneEntryIDs: Set<UUID>
  let model: AppModel
  let animatesTransitions: Bool

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.entries.count == rhs.entries.count
      && lhs.entries.first?.id == rhs.entries.first?.id
      && lhs.entries.last?.id == rhs.entries.last?.id
      && lhs.standaloneEntryIDs == rhs.standaloneEntryIDs
      && lhs.animatesTransitions == rhs.animatesTransitions
  }

  var body: some View {
    let segments = makeSegments()
    VStack(spacing: 0) {
      ForEach(segments) { segment in
        switch segment.content {
        case .folded(let foldedEntries):
          VirtualizedFoldedHistoryList(entries: foldedEntries, model: model)
            .frame(maxWidth: .infinity)
            .frame(
              height: CGFloat(foldedEntries.count) * HistoryEntryPencilLayout.foldedRowStride
            )
        case .standalone(let entry):
          HistoryEntryView(
            entry: entry,
            model: model,
            animatesTransitions: animatesTransitions
          )
          .id(entry.id)
        }
      }
    }
  }

  private func makeSegments() -> [Segment] {
    var segments: [Segment] = []
    var foldedEntries: [HistoryEntry] = []

    func flushFoldedEntries() {
      guard let first = foldedEntries.first else { return }
      segments.append(Segment(id: first.id, content: .folded(foldedEntries)))
      foldedEntries.removeAll(keepingCapacity: true)
    }

    for entry in entries {
      if standaloneEntryIDs.contains(entry.id) {
        flushFoldedEntries()
        segments.append(Segment(id: entry.id, content: .standalone(entry)))
      } else {
        foldedEntries.append(entry)
      }
    }
    flushFoldedEntries()
    return segments
  }
}

private struct HistoryFollowController: View {
  @Bindable var model: AppModel

  var body: some View {
    HistoryScrollTrackingView(
      followRevision: model.historyScrollRevision,
      forcePinRevision: model.historyForcePinRevision,
      onLiveScroll: { model.historyDidLiveScroll() },
      onEndLiveScroll: { model.historyDidEndLiveScroll() }
    )
    .frame(width: 0, height: 0)
  }
}

private struct HistoryEntryView: View {
  private let standaloneEntry: HistoryEntry?
  let model: AppModel
  let animatesTransitions: Bool
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  init(entry: HistoryEntry, model: AppModel, animatesTransitions: Bool) {
    standaloneEntry = entry
    self.model = model
    self.animatesTransitions = animatesTransitions
  }

  private var entry: HistoryEntry {
    standaloneEntry!
  }

  private var isExpanded: Bool {
    model.isHistoryEntryExpanded(entry)
  }

  private var isLatestEntry: Bool {
    entry.isLatestInHistory
  }

  var body: some View {
    let presentation: HistoryEntryNSView.Presentation =
      isExpanded ? .expanded(isLatest: isLatestEntry) : .folded
    let _ = entry.state
    let _ = entry.presentationRevision
    let _ = entry.metadata

    NativeHistoryEntryView(
      entry: entry,
      presentation: presentation,
      showsSeparator: !isLatestEntry,
      onExpand: {
        model.expandHistoryEntry(entry.id)
      },
      onCollapse: {
        model.collapseHistoryEntry(entry.id)
      },
      onRedo: {
        model.redo(entry)
      },
      onCopySource: {
        model.copySource(entry)
      },
      onCopyResult: {
        guard entry.resultUTF16Length > 0 else { return }
        model.copyResult(entry)
      }
    )
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .animation(historyTransitionAnimation, value: presentation)
  }

  private var historyTransitionAnimation: Animation? {
    guard animatesTransitions, !accessibilityReduceMotion else { return nil }
    return .easeOut(duration: CidaMotion.historyFoldSeconds)
  }

}

@MainActor
final class StickyHistoryResultActionNSView: NSView {
  private static let normalTint = NSColor(
    srgbRed: 138 / 255,
    green: 138 / 255,
    blue: 131 / 255,
    alpha: 1
  )
  private static let hoverTint = NSColor(
    srgbRed: 26 / 255,
    green: 26 / 255,
    blue: 24 / 255,
    alpha: 1
  )
  private static let copiedTint = NSColor(
    srgbRed: 46 / 255,
    green: 107 / 255,
    blue: 79 / 255,
    alpha: 1
  )

  private let actionButton = StickyHistoryResultActionButton()
  private weak var observedClipView: NSClipView?
  nonisolated(unsafe) private var localMouseDownMonitor: Any?
  private var action: (@MainActor () -> Void)?
  private var configuredIdentifier = ""
  private var isLongEntry = false
  private var isActionVisible = false
  private var requestedVisibility = false
  private var isShowingCopyFeedback = false

  var hasLocalMouseDownMonitorForTesting: Bool {
    localMouseDownMonitor != nil
  }

  var accessibilityActionButton: NSButton? {
    isActionVisible ? actionButton : nil
  }

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(false)
    actionButton.target = self
    actionButton.action = #selector(performAction(_:))
    actionButton.accessibilityOwner = self
    actionButton.normalTintColor = Self.normalTint
    actionButton.hoverTintColor = Self.hoverTint
    actionButton.isHidden = true
    addSubview(actionButton)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let localMouseDownMonitor {
      NSEvent.removeMonitor(localMouseDownMonitor)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isActionVisible, containsActionPoint(point) else { return nil }
    return self
  }

  override func mouseDown(with event: NSEvent) {
    performAction(self)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      removeLocalMouseDownMonitor()
      return
    }
    installScrollObservationIfNeeded()
    installLocalMouseDownMonitor()
    updateActionFrame()
    DispatchQueue.main.async { [weak self] in
      self?.installScrollObservationIfNeeded()
      self?.installLocalMouseDownMonitor()
      self?.updateActionFrame()
    }
  }

  override func layout() {
    super.layout()
    installScrollObservationIfNeeded()
    updateActionFrame()
  }

  func configure(
    identifier: String,
    isLongEntry: Bool,
    isVisible: Bool,
    isCopied: Bool,
    action: @escaping @MainActor () -> Void
  ) {
    if configuredIdentifier != identifier {
      configuredIdentifier = identifier
      resetCopyFeedback()
    }
    self.action = action
    self.isLongEntry = isLongEntry
    requestedVisibility = isVisible
    actionButton.setAccessibilityIdentifier(identifier)
    updateCopyFeedback(isCopied)
    applyVisibility()
    updateActionFrame()
  }

  static func actionOriginY(
    bounds: NSRect,
    visibleRect: NSRect,
    isLongEntry: Bool
  ) -> CGFloat {
    let inset: CGFloat = 4
    let maximumTop = max(inset, bounds.height - HistoryEntryPencilLayout.actionIconSize - inset)
    let visibleTop = visibleRect.isNull ? inset : visibleRect.minY + inset
    return isLongEntry ? min(max(visibleTop, inset), maximumTop) : inset
  }

  private func installScrollObservationIfNeeded() {
    guard let clipView = enclosingScrollView?.contentView else { return }
    guard observedClipView !== clipView else { return }
    NotificationCenter.default.removeObserver(self)
    observedClipView = clipView
    clipView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(clipViewBoundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: clipView
    )
  }

  @objc
  private func clipViewBoundsDidChange(_ notification: Notification) {
    updateActionFrame()
  }

  private func updateActionFrame() {
    let visibleRect =
      observedClipView.map { convert($0.bounds, from: $0) }
      ?? visibleRect
    let originY = Self.actionOriginY(
      bounds: bounds,
      visibleRect: bounds.intersection(visibleRect),
      isLongEntry: isLongEntry
    )
    actionButton.frame = NSRect(
      x: max(0, bounds.width - HistoryEntryPencilLayout.actionIconSize),
      y: originY,
      width: HistoryEntryPencilLayout.actionIconSize,
      height: HistoryEntryPencilLayout.actionIconSize
    )
  }

  private var actionHitFrame: NSRect {
    actionButton.frame.insetBy(dx: -6, dy: -6)
  }

  private func containsActionPoint(_ point: NSPoint) -> Bool {
    let hitFrame = actionHitFrame
    return point.x >= hitFrame.minX && point.x <= hitFrame.maxX
      && point.y >= hitFrame.minY && point.y <= hitFrame.maxY
  }

  private func installLocalMouseDownMonitor() {
    guard window != nil, localMouseDownMonitor == nil else { return }
    localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
      [weak self] event in
      guard let self, self.isActionVisible else { return event }
      let localPoint = self.convert(event.locationInWindow, from: nil)
      guard self.containsActionPoint(localPoint) else { return event }
      self.performAction(self)
      return nil
    }
  }

  private func removeLocalMouseDownMonitor() {
    guard let localMouseDownMonitor else { return }
    NSEvent.removeMonitor(localMouseDownMonitor)
    self.localMouseDownMonitor = nil
  }

  func detach() {
    NotificationCenter.default.removeObserver(self)
    removeLocalMouseDownMonitor()
    observedClipView = nil
    action = nil
  }

  fileprivate func actionButtonAccessibilityFrame() -> NSRect {
    guard let window else { return .zero }
    return window.convertToScreen(convert(actionButton.frame, to: nil))
  }

  @objc
  private func performAction(_ sender: Any?) {
    action?()
    updateCopyFeedback(true)
  }

  private func updateCopyFeedback(_ isCopied: Bool) {
    isShowingCopyFeedback = isCopied
    actionButton.reportedAccessibilityValue = isCopied ? "copied" : "idle"
    actionButton.setAccessibilityLabel(isCopied ? "已复制结果" : "复制结果")
    actionButton.setAccessibilityValue(isCopied ? "copied" : "idle")
    actionButton.iconImage = LucideIconAsset.image(for: isCopied ? .check : .copy)
    actionButton.setFeedbackTint(isCopied ? Self.copiedTint : nil)
  }

  private func resetCopyFeedback() {
    updateCopyFeedback(false)
  }

  private func applyVisibility() {
    let pointerIsOverAction: Bool
    if let window {
      let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
      pointerIsOverAction = actionButton.frame.contains(pointer)
    } else {
      pointerIsOverAction = false
    }
    let visible = requestedVisibility || isShowingCopyFeedback || pointerIsOverAction
    isActionVisible = visible
    actionButton.isHidden = !visible
    actionButton.setAccessibilityElement(visible)
    if visible {
      actionButton.setAccessibilityRole(.button)
    }
  }
}

private final class StickyHistoryResultActionButton: HistoryEntryActionButton,
  @unchecked Sendable
{
  nonisolated(unsafe) weak var accessibilityOwner: StickyHistoryResultActionNSView?
  nonisolated(unsafe) var reportedAccessibilityValue = "idle"

  nonisolated override func accessibilityFrame() -> NSRect {
    let owner = accessibilityOwner
    return MainActor.assumeIsolated {
      owner?.actionButtonAccessibilityFrame() ?? .zero
    }
  }

  nonisolated override func accessibilityValue() -> Any? {
    reportedAccessibilityValue
  }
}

@MainActor
final class HistoryEntryHoverTrackingNSView: NSView {
  var onHoverChange: ((Bool) -> Void)?

  private weak var observedClipView: NSClipView?
  private weak var observedWindow: NSWindow?
  private weak var trackingAreaHostView: NSView?
  private var trackingAreaReference: NSTrackingArea?
  nonisolated(unsafe) private var localMouseMonitor: Any?
  private var lastPublishedHovering: Bool?
  private var pendingHoverPublication: Bool?
  private var hoverPublicationIsScheduled = false
  private var isActive = true

  var hasLocalMouseMonitorForTesting: Bool {
    localMouseMonitor != nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let localMouseMonitor {
      NSEvent.removeMonitor(localMouseMonitor)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else {
      removeTrackingAreaReference()
      removeLocalMouseMonitor()
      removeWindowObservation()
      setHovering(false)
      return
    }
    window.acceptsMouseMovedEvents = true
    installWindowObservationIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.installScrollObservationIfNeeded()
      self?.installTrackingArea()
      self?.installLocalMouseMonitor()
      self?.refreshHoverState()
    }
  }

  override func layout() {
    super.layout()
    installScrollObservationIfNeeded()
    installWindowObservationIfNeeded()
    installTrackingArea()
    installLocalMouseMonitor()
    refreshHoverState()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    installScrollObservationIfNeeded()
    installTrackingArea()
  }

  private func installTrackingArea() {
    let hostView: NSView = observedClipView ?? self
    guard isActive else {
      removeTrackingAreaReference()
      return
    }
    guard trackingAreaReference == nil || trackingAreaHostView !== hostView else { return }
    removeTrackingAreaReference()
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    hostView.addTrackingArea(trackingArea)
    trackingAreaHostView = hostView
    trackingAreaReference = trackingArea
  }

  private func removeTrackingAreaReference() {
    if let trackingAreaReference, let trackingAreaHostView {
      trackingAreaHostView.removeTrackingArea(trackingAreaReference)
    }
    trackingAreaReference = nil
    trackingAreaHostView = nil
  }

  private func installLocalMouseMonitor() {
    guard isActive, window != nil, localMouseMonitor == nil else { return }
    localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
      [weak self] event in
      guard let self else { return event }
      self.refreshHoverState()
      return event
    }
  }

  private func removeLocalMouseMonitor() {
    guard let localMouseMonitor else { return }
    NSEvent.removeMonitor(localMouseMonitor)
    self.localMouseMonitor = nil
  }

  private func installWindowObservationIfNeeded() {
    guard let window, observedWindow !== window else { return }
    removeWindowObservation()
    observedWindow = window
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: window
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidResignKey(_:)),
      name: NSWindow.didResignKeyNotification,
      object: window
    )
  }

  private func removeWindowObservation() {
    guard let observedWindow else { return }
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.didBecomeKeyNotification,
      object: observedWindow
    )
    NotificationCenter.default.removeObserver(
      self,
      name: NSWindow.didResignKeyNotification,
      object: observedWindow
    )
    self.observedWindow = nil
  }

  @objc
  private func windowDidBecomeKey(_ notification: Notification) {
    window?.acceptsMouseMovedEvents = true
    refreshHoverState()
  }

  @objc
  private func windowDidResignKey(_ notification: Notification) {
    setHovering(false)
  }

  override func mouseEntered(with event: NSEvent) {
    refreshHoverState(atWindowPoint: event.locationInWindow)
  }

  override func mouseMoved(with event: NSEvent) {
    refreshHoverState(atWindowPoint: event.locationInWindow)
  }

  override func mouseExited(with event: NSEvent) {
    refreshHoverState(atWindowPoint: event.locationInWindow)
  }

  func refreshHoverState() {
    guard isActive, !isHiddenOrHasHiddenAncestor, let window, window.isKeyWindow else {
      setHovering(false)
      return
    }
    refreshHoverState(atWindowPoint: window.mouseLocationOutsideOfEventStream)
  }

  func refreshHoverState(atWindowPoint windowPoint: NSPoint) {
    guard isActive, !isHiddenOrHasHiddenAncestor, let window, window.isKeyWindow else {
      setHovering(false)
      return
    }
    let entryRectInWindow = convert(bounds, to: nil)
    let viewportRectInWindow =
      observedClipView.map { clipView in
        clipView.convert(clipView.bounds, to: nil)
      } ?? entryRectInWindow
    setHovering(
      Self.containsHoverPoint(
        windowPoint,
        entryRectInWindow: entryRectInWindow,
        viewportRectInWindow: viewportRectInWindow
      )
    )
  }

  static func containsHoverPoint(
    _ point: NSPoint,
    entryRectInWindow: NSRect,
    viewportRectInWindow: NSRect
  ) -> Bool {
    let interactiveEntryRect = entryRectInWindow.insetBy(
      dx: -HistoryEntryPencilLayout.actionIconSize,
      dy: 0
    )
    let visibleEntryRect = interactiveEntryRect.intersection(viewportRectInWindow)
    return !visibleEntryRect.isNull && visibleEntryRect.contains(point)
  }

  func setActive(_ active: Bool) {
    guard isActive != active else { return }
    isActive = active
    updateTrackingAreas()
    if active {
      installLocalMouseMonitor()
      DispatchQueue.main.async { [weak self] in
        self?.refreshHoverState()
      }
    } else {
      removeLocalMouseMonitor()
      setHovering(false)
    }
  }

  func detach() {
    NotificationCenter.default.removeObserver(self)
    removeTrackingAreaReference()
    removeLocalMouseMonitor()
    observedClipView = nil
    observedWindow = nil
    pendingHoverPublication = nil
    onHoverChange = nil
  }

  private func installScrollObservationIfNeeded() {
    guard let clipView = enclosingScrollView?.contentView else { return }
    guard observedClipView !== clipView else { return }
    if let observedClipView {
      NotificationCenter.default.removeObserver(
        self,
        name: NSView.boundsDidChangeNotification,
        object: observedClipView
      )
    }
    removeTrackingAreaReference()
    observedClipView = clipView
    clipView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(clipViewBoundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: clipView
    )
  }

  @objc
  private func clipViewBoundsDidChange(_ notification: Notification) {
    refreshHoverState()
  }

  private func setHovering(_ hovering: Bool) {
    guard pendingHoverPublication != hovering else { return }
    if pendingHoverPublication == nil, lastPublishedHovering == hovering { return }
    pendingHoverPublication = hovering
    guard !hoverPublicationIsScheduled else { return }
    hoverPublicationIsScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.hoverPublicationIsScheduled = false
      guard let hovering = self.pendingHoverPublication else { return }
      self.pendingHoverPublication = nil
      self.lastPublishedHovering = hovering
      self.onHoverChange?(hovering)
    }
  }

  func synchronizePublishedHoverState(_ hovering: Bool) {
    lastPublishedHovering = hovering
  }

  #if DEBUG
    func publishHoverStateForTesting(_ hovering: Bool) {
      setHovering(hovering)
    }
  #endif
}

private struct Composer: View {
  @Bindable var model: AppModel
  let automaticallyFocusInput: Bool
  let availableHeight: CGFloat
  @FocusState private var isInputFocused: Bool
  @Binding var inputMetrics: ComposerTextMetrics

  init(
    model: AppModel,
    automaticallyFocusInput: Bool,
    availableHeight: CGFloat,
    inputMetrics: Binding<ComposerTextMetrics>
  ) {
    self.model = model
    self.automaticallyFocusInput = automaticallyFocusInput
    self.availableHeight = availableHeight
    _inputMetrics = inputMetrics
  }

  var body: some View {
    VStack(spacing: 12) {
      ZStack(alignment: .topLeading) {
        if !inputMetrics.hasText {
          Text("输入内容,回车\(model.mode == .translate ? "翻译" : "改进")…")
            .font(CidaDesign.body(16))
            .foregroundStyle(CidaDesign.textTertiary)
            .padding(.leading, 28)
            .padding(.top, 3)
            .allowsHitTesting(false)
        }

        ComposerTextEditor(
          text: $model.inputText,
          metrics: $inputMetrics,
          isFocused: $isInputFocused,
          resetRevision: model.inputResetRevision,
          currentResetRevision: { model.inputResetRevision },
          onSubmit: submit,
          onVirtualDocumentChange: { document, utf16Count, hasNonWhitespace in
            model.stageInputDocument(
              document,
              utf16Count: utf16Count,
              hasNonWhitespace: hasNonWhitespace
            )
          }
        )
      }
      .frame(maxWidth: .infinity)
      .frame(height: editorHeight(for: inputMetrics))
      .animation(
        .easeOut(duration: CidaMotion.heightSeconds),
        value: inputMetrics.presentationState
      )

      HStack(spacing: 12) {
        HStack(spacing: 8) {
          ModeSegmentedControl(model: model)
          OutputHint(model: model)
        }

        Spacer(minLength: 8)

        HStack(spacing: 12) {
          if inputMetrics.presentationState.showsDocumentChrome {
            Text("\(inputMetrics.formattedCharacterCount) 字")
              .font(CidaDesign.mainUI(11.5))
              .foregroundStyle(CidaDesign.textTertiary)
              .accessibilityLabel("输入了 \(inputMetrics.formattedCharacterCount) 个字符")
          }

          if inputMetrics.isImportingLargeDocument {
            HStack(spacing: 6) {
              ProgressView().controlSize(.mini)
              Text("正在载入长文本…")
            }
            .font(CidaDesign.mainUI(11, weight: .medium))
            .foregroundStyle(CidaDesign.accent)
          }

          Button {
            if model.isProcessing {
              model.cancelProcessing()
            } else {
              _ = submit()
            }
          } label: {
            ZStack {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CidaDesign.accent)
              RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(CidaDesign.accentForeground)
                .frame(width: 10, height: 10)
                .opacity(model.isProcessing ? 1 : 0)
              LucideIcon(.arrowUp, size: 15)
                .foregroundStyle(.white)
                .opacity(model.isProcessing ? 0 : 1)
            }
            .frame(width: 30, height: 30)
            .animation(.easeOut(duration: CidaMotion.iconSwapSeconds), value: model.isProcessing)
          }
          .buttonStyle(HoverFadeButtonStyle())
          .disabled(
            !model.isProcessing
              && (!inputMetrics.hasNonWhitespace || inputMetrics.isImportingLargeDocument)
          )
          .accessibilityLabel(
            model.isProcessing ? "停止生成" : (model.mode == .translate ? "翻译" : "改进")
          )
          .accessibilityIdentifier("composer-submit-button")
        }
      }
      .padding(.horizontal, 28)
      .frame(height: 30)
    }
    .padding(.vertical, 16)
    .background(CidaDesign.surface)
    .overlay(alignment: .top) { Hairline() }
    .onAppear {
      guard automaticallyFocusInput else { return }
      Task { @MainActor in
        await Task.yield()
        isInputFocused = true
      }
    }
    .onChange(of: model.inputFocusRequestID) {
      isInputFocused = true
    }
    .onChange(of: model.inputResetRevision) {
      guard model.inputText.isEmpty else { return }
      inputMetrics = ComposerTextMetrics(text: "")
    }
  }

  private func editorHeight(for metrics: ComposerTextMetrics) -> CGFloat {
    ComposerLayout.editorHeight(for: metrics, availableHeight: availableHeight)
  }

  private func submit() -> Bool {
    let didSubmit = model.submit()
    if didSubmit {
      inputMetrics = ComposerTextMetrics(text: "")
    }
    return didSubmit
  }
}

private struct HistoryScrollTrackingView: NSViewRepresentable {
  let followRevision: Int
  let forcePinRevision: Int
  let onLiveScroll: @MainActor () -> Void
  let onEndLiveScroll: @MainActor () -> Void

  func makeNSView(context: Context) -> HistoryScrollTrackingNSView {
    let view = HistoryScrollTrackingNSView()
    view.onLiveScroll = onLiveScroll
    view.onEndLiveScroll = onEndLiveScroll
    view.followContentGrowth(revision: followRevision)
    view.forceFollowToBottom(revision: forcePinRevision)
    return view
  }

  func updateNSView(_ view: HistoryScrollTrackingNSView, context: Context) {
    view.onLiveScroll = onLiveScroll
    view.onEndLiveScroll = onEndLiveScroll
    view.installObservationIfNeeded()
    view.followContentGrowth(revision: followRevision)
    view.forceFollowToBottom(revision: forcePinRevision)
  }
}

@MainActor
private final class HistoryScrollTrackingNSView: NSView {
  var onLiveScroll: (@MainActor () -> Void)?
  var onEndLiveScroll: (@MainActor () -> Void)?
  private weak var observedScrollView: NSScrollView?
  private weak var observedDocumentView: NSView?
  private var followState = HistoryFollowState.followingBottom
  private var isFollowScheduled = false
  private var lastFollowRevision: Int?
  private var lastForcePinRevision: Int?
  private var lastAccessibilityState: String?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    installObservationIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.installObservationIfNeeded()
    }
  }

  func installObservationIfNeeded() {
    guard let scrollView = enclosingScrollView, let documentView = scrollView.documentView else {
      return
    }
    CidaScrollIndicator.install(on: scrollView, configuration: .history)
    scrollView.setAccessibilityIdentifier("history-scroll-view")
    scrollView.setAccessibilityLabel("历史记录")
    guard observedScrollView !== scrollView || observedDocumentView !== documentView else { return }
    removeObservations()
    observedScrollView = scrollView
    observedDocumentView = documentView
    lastAccessibilityState = nil
    documentView.postsFrameChangedNotifications = true

    let center = NotificationCenter.default
    for name in [
      NSScrollView.willStartLiveScrollNotification,
      NSScrollView.didLiveScrollNotification,
      NSScrollView.didEndLiveScrollNotification,
    ] {
      center.addObserver(
        self,
        selector: #selector(scrollViewDidLiveScroll(_:)),
        name: name,
        object: scrollView
      )
    }
    center.addObserver(
      self,
      selector: #selector(documentFrameDidChange(_:)),
      name: NSView.frameDidChangeNotification,
      object: documentView
    )
    if followState == .followingBottom {
      scheduleFollowToBottom()
    }
    updateAccessibilityState()
  }

  func forceFollowToBottom(revision: Int) {
    guard revision != lastForcePinRevision else { return }
    lastForcePinRevision = revision
    followState = .followingBottom
    updateAccessibilityState()
    scheduleFollowToBottom()
  }

  func followContentGrowth(revision: Int) {
    guard revision != lastFollowRevision else { return }
    lastFollowRevision = revision
    guard followState == .followingBottom else { return }
    scheduleFollowToBottom()
  }

  @objc
  private func scrollViewDidLiveScroll(_ notification: Notification) {
    if notification.name == NSScrollView.didEndLiveScrollNotification {
      onEndLiveScroll?()
    } else {
      onLiveScroll?()
    }
    reportPinnedState()
  }

  @objc
  private func documentFrameDidChange(_ notification: Notification) {
    guard followState == .followingBottom else { return }
    scheduleFollowToBottom()
  }

  private func reportPinnedState() {
    guard let scrollView = observedScrollView, let documentView = scrollView.documentView else {
      return
    }
    let visibleRect = scrollView.contentView.documentVisibleRect
    let isPinned =
      documentView.isFlipped
      ? visibleRect.maxY >= documentView.bounds.maxY - 24
      : visibleRect.minY <= documentView.bounds.minY + 24
    let nextState: HistoryFollowState = isPinned ? .followingBottom : .detached
    guard nextState != followState else { return }
    followState = nextState
    updateAccessibilityState()
  }

  private func scheduleFollowToBottom() {
    guard !isFollowScheduled else { return }
    isFollowScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.isFollowScheduled = false
      guard self.followState == .followingBottom else { return }
      self.scrollToBottom()
    }
  }

  private func scrollToBottom() {
    guard let scrollView = observedScrollView, let documentView = scrollView.documentView else {
      return
    }
    let clipView = scrollView.contentView
    let visibleHeight = clipView.documentVisibleRect.height
    let originY =
      documentView.isFlipped
      ? max(documentView.bounds.minY, documentView.bounds.maxY - visibleHeight)
      : documentView.bounds.minY
    guard abs(clipView.documentVisibleRect.minY - originY) > 0.5 else { return }
    clipView.scroll(to: NSPoint(x: clipView.documentVisibleRect.minX, y: originY))
    scrollView.reflectScrolledClipView(clipView)
  }

  private func updateAccessibilityState() {
    let state = followState == .followingBottom ? "bottom" : "detached"
    guard state != lastAccessibilityState else { return }
    lastAccessibilityState = state
    observedScrollView?.setAccessibilityValue(state)
  }

  private func removeObservations() {
    NotificationCenter.default.removeObserver(self)
  }
}

private struct ModeSegmentedControl: View {
  @Bindable var model: AppModel

  var body: some View {
    HStack(spacing: 2) {
      ForEach(ProcessingMode.allCases, id: \.self) { mode in
        Button {
          model.setMode(mode)
        } label: {
          Text(mode.title)
            .font(CidaDesign.mainUI(11.5, weight: model.mode == mode ? .semibold : .medium))
            .foregroundStyle(model.mode == mode ? CidaDesign.textPrimary : CidaDesign.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background {
              if model.mode == mode {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                  .fill(CidaDesign.surface)
                  .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                      .strokeBorder(CidaDesign.border, lineWidth: 1)
                  }
              }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
      }
    }
    .padding(2)
    .background(CidaDesign.surfaceDim)
    .clipShape(.rect(cornerRadius: 7, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("处理模式")
  }
}

private struct OutputHint: View {
  @Bindable var model: AppModel

  @ViewBuilder
  var body: some View {
    if model.mode == .translate {
      Button {
        model.swapLanguages()
      } label: {
        HStack(spacing: 6) {
          Text(model.sourceLanguage.title)
          LucideIcon(.arrowLeftRight, size: 11)
          Text(model.targetLanguage.title)
        }
        .modifier(OutputHintStyle())
      }
      .buttonStyle(HoverFadeButtonStyle())
      .accessibilityLabel("交换源语言与目标语言")
    } else {
      HStack(spacing: 6) {
        LucideIcon(.scanText, size: 11)
        Text(model.outputHint)
      }
      .modifier(OutputHintStyle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(model.outputHint)
      .accessibilityIdentifier("improvement-output-hint")
    }
  }
}

private struct OutputHintStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(CidaDesign.mainUI(11.5, weight: .medium))
      .foregroundStyle(CidaDesign.textTertiary)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
  }
}

import AppKit
import QuartzCore
import SwiftUI

struct NativeHistoryEntryView: NSViewRepresentable {
  let entry: HistoryEntry
  let presentation: HistoryEntryNSView.Presentation
  let showsSeparator: Bool
  let onExpand: @MainActor () -> Void
  let onCollapse: @MainActor () -> Void
  let onRedo: @MainActor () -> Void
  let onCopySource: @MainActor () -> Void
  let onCopyResult: @MainActor () -> Void

  func makeNSView(context: Context) -> HistoryEntryNSView {
    let view = HistoryEntryNSView()
    configure(view)
    return view
  }

  func updateNSView(_ view: HistoryEntryNSView, context: Context) {
    configure(view)
  }

  static func dismantleNSView(_ view: HistoryEntryNSView, coordinator: Void) {
    view.detachStandalonePresentation()
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView view: HistoryEntryNSView,
    context _: Context
  ) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    return CGSize(width: width, height: view.preferredHeight(for: width))
  }

  private func configure(_ view: HistoryEntryNSView) {
    switch presentation {
    case .folded:
      view.configure(
        entryID: entry.id,
        mode: entry.mode,
        metadata: entry.metadata,
        preview: entry.resultStorage.foldedPreview,
        state: entry.state,
        showsSeparator: showsSeparator,
        onExpand: onExpand,
        onRedo: onRedo,
        onCopyResult: onCopyResult
      )
    case .expanded(let isLatest):
      view.configureExpanded(
        entryID: entry.id,
        mode: entry.mode,
        metadata: entry.metadata,
        source: entry.source,
        preview: entry.resultStorage.foldedPreview,
        resultStorage: entry.resultStorage,
        presentationRevision: entry.presentationRevision,
        latestPresentationDelta: entry.latestPresentationDelta,
        state: entry.state,
        isLatest: isLatest,
        isLongEntry: entry.isLongDocument,
        showsSeparator: showsSeparator,
        onCollapse: onCollapse,
        onRedo: onRedo,
        onCopySource: onCopySource,
        onCopyResult: onCopyResult
      )
    }
  }
}

struct VirtualizedFoldedHistoryList: NSViewRepresentable {
  let entries: [HistoryEntry]
  let model: AppModel

  func makeNSView(context: Context) -> VirtualizedFoldedHistoryListNSView {
    let view = VirtualizedFoldedHistoryListNSView()
    configure(view)
    return view
  }

  func updateNSView(_ view: VirtualizedFoldedHistoryListNSView, context: Context) {
    configure(view)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView _: VirtualizedFoldedHistoryListNSView,
    context _: Context
  ) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    return CGSize(
      width: width,
      height: CGFloat(entries.count) * HistoryEntryPencilLayout.foldedRowStride
    )
  }

  private func configure(_ view: VirtualizedFoldedHistoryListNSView) {
    view.configure(
      entries: entries,
      onExpand: { entry in
        model.expandHistoryEntry(entry.id)
      },
      onRedo: { entry in
        model.redo(entry)
      },
      onCopyResult: { entry in
        model.copyResult(entry)
      }
    )
  }
}

struct HistoryPlaceholderRunway: NSViewRepresentable {
  static let maximumHeight: CGFloat = 2_000_000

  let entryCount: Int

  func makeNSView(context: Context) -> HistoryPlaceholderRunwayNSView {
    let view = HistoryPlaceholderRunwayNSView()
    view.configure(entryCount: entryCount)
    return view
  }

  func updateNSView(_ view: HistoryPlaceholderRunwayNSView, context: Context) {
    view.configure(entryCount: entryCount)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView _: HistoryPlaceholderRunwayNSView,
    context _: Context
  ) -> CGSize? {
    guard let width = proposal.width, width > 0 else { return nil }
    return CGSize(width: width, height: Self.height(for: entryCount))
  }

  static func height(for entryCount: Int) -> CGFloat {
    min(
      maximumHeight,
      CGFloat(max(0, entryCount)) * HistoryEntryPencilLayout.foldedRowStride
    )
  }
}

@MainActor
final class HistoryPlaceholderRunwayNSView: NSView {
  private var entryCount = 0
  private weak var observedClipView: NSClipView?
  private let placeholderLayer = CAShapeLayer()
  private let separatorLayer = CAShapeLayer()
  private var renderedRowRange: Range<Int> = 0..<0
  private var renderedWidth: CGFloat = 0

  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(
      width: NSView.noIntrinsicMetric,
      height: HistoryPlaceholderRunway.height(for: entryCount)
    )
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    layer?.backgroundColor =
      NSColor(
        srgbRed: 250 / 255,
        green: 250 / 255,
        blue: 248 / 255,
        alpha: 1
      ).cgColor
    placeholderLayer.fillColor =
      NSColor(
        srgbRed: 181 / 255,
        green: 183 / 255,
        blue: 176 / 255,
        alpha: 0.22
      ).cgColor
    separatorLayer.fillColor =
      NSColor(
        srgbRed: 225 / 255,
        green: 225 / 255,
        blue: 220 / 255,
        alpha: 0.7
      ).cgColor
    for shapeLayer in [placeholderLayer, separatorLayer] {
      shapeLayer.actions = [
        "bounds": NSNull(),
        "position": NSNull(),
        "path": NSNull(),
      ]
      layer?.addSublayer(shapeLayer)
    }
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("更早的历史记录正在按需载入")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func configure(entryCount: Int) {
    let boundedCount = max(0, entryCount)
    guard boundedCount != self.entryCount else { return }
    self.entryCount = boundedCount
    invalidateIntrinsicContentSize()
    renderedRowRange = 0..<0
    updatePlaceholderLayers()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    installObservationIfNeeded()
    updatePlaceholderLayers()
    DispatchQueue.main.async { [weak self] in
      self?.installObservationIfNeeded()
      self?.updatePlaceholderLayers()
    }
  }

  override func layout() {
    super.layout()
    installObservationIfNeeded()
    updatePlaceholderLayers()
  }

  private func installObservationIfNeeded() {
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
    updatePlaceholderLayers()
  }

  private func updatePlaceholderLayers() {
    guard entryCount > 0, bounds.width > 0, bounds.height > 0 else {
      placeholderLayer.path = nil
      separatorLayer.path = nil
      renderedRowRange = 0..<0
      return
    }

    let stride = HistoryEntryPencilLayout.foldedRowStride
    let viewportRect =
      observedClipView.map { convert($0.bounds, from: $0) }
      ?? NSRect(
        x: 0,
        y: max(0, bounds.maxY - 1_024),
        width: bounds.width,
        height: min(1_024, bounds.height)
      )
    let visibleRect = viewportRect.intersection(bounds)
    let targetRect =
      visibleRect.isNull
      ? NSRect(
        x: 0,
        y: max(0, bounds.maxY - 1_024),
        width: bounds.width,
        height: min(1_024, bounds.height)
      )
      : visibleRect.insetBy(dx: 0, dy: -stride * 2).intersection(bounds)
    let firstRow = max(0, Int(floor(targetRect.minY / stride)))
    let lastRow = min(
      Int(ceil(bounds.height / stride)),
      Int(ceil(targetRect.maxY / stride)) + 1
    )
    guard firstRow < lastRow else {
      placeholderLayer.path = nil
      separatorLayer.path = nil
      renderedRowRange = 0..<0
      return
    }
    let rowRange = firstRow..<lastRow
    guard rowRange != renderedRowRange || abs(renderedWidth - bounds.width) > 0.5 else {
      return
    }
    renderedRowRange = rowRange
    renderedWidth = bounds.width

    let placeholderPath = CGMutablePath()
    let separatorPath = CGMutablePath()
    for row in rowRange {
      let originY = CGFloat(row) * stride
      placeholderPath.addRoundedRect(
        in: CGRect(x: 10, y: originY + 15, width: 108, height: 6),
        cornerWidth: 3,
        cornerHeight: 3
      )
      placeholderPath.addRoundedRect(
        in: CGRect(
          x: 10,
          y: originY + 43,
          width: max(80, min(360, bounds.width * 0.42)),
          height: 7
        ),
        cornerWidth: 3.5,
        cornerHeight: 3.5
      )
      placeholderPath.addRoundedRect(
        in: CGRect(
          x: 10,
          y: originY + 66,
          width: max(60, min(260, bounds.width * 0.3)),
          height: 7
        ),
        cornerWidth: 3.5,
        cornerHeight: 3.5
      )
      separatorPath.addRect(
        CGRect(x: 0, y: originY + stride - 1, width: bounds.width, height: 1)
      )
    }
    placeholderLayer.path = placeholderPath
    separatorLayer.path = separatorPath
  }
}

@MainActor
private final class FlippedHistoryRowsContainer: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
final class VirtualizedFoldedHistoryListNSView: NSView {
  private struct EntryVersion: Equatable {
    let id: UUID
    let state: HistoryEntryState
    let presentationRevision: Int
  }

  private var entries: [HistoryEntry] = []
  private var entryIDs: [UUID] = []
  private var entryVersions: [EntryVersion] = []
  private var rowOffsets: [CGFloat] = []
  private var rowHeights: [CGFloat] = []
  private var measuredWidth: CGFloat?
  private var measuredHeight: CGFloat = 0
  private weak var observedClipView: NSClipView?
  private var activeRange: Range<Int> = 0..<0
  private var activeRows: [HistoryEntryNSView] = []
  private var scratchRows: [HistoryEntryNSView] = []
  private var recycledRows: [HistoryEntryNSView] = []
  private var trackingAreaReference: NSTrackingArea?
  private let rowsContainer = FlippedHistoryRowsContainer()
  private var onExpand: ((HistoryEntry) -> Void)?
  private var onRedo: ((HistoryEntry) -> Void)?
  private var onCopyResult: ((HistoryEntry) -> Void)?

  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(
      width: NSView.noIntrinsicMetric,
      height: preferredHeight(for: max(1, bounds.width))
    )
  }

  var materializedRowCount: Int { activeRows.count }
  #if DEBUG
    var materializedRowsForTesting: [HistoryEntryNSView] { activeRows }
    var pooledRowCountForTesting: Int { rowsContainer.subviews.count }
  #endif
  private(set) var configurationCount = 0
  private(set) var rowMeasurementCount = 0

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(rowsContainer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    entries: [HistoryEntry],
    onExpand: @escaping (HistoryEntry) -> Void,
    onRedo: @escaping (HistoryEntry) -> Void,
    onCopyResult: @escaping (HistoryEntry) -> Void
  ) {
    let nextIDs = entries.map(\.id)
    let nextVersions = entries.map {
      EntryVersion(
        id: $0.id,
        state: $0.state,
        presentationRevision: $0.presentationRevision
      )
    }
    guard nextVersions != entryVersions else {
      installObservationIfNeeded()
      updateVisibleRows()
      return
    }

    configurationCount += 1
    let entriesChanged = nextIDs != entryIDs
    let previousEntryCount = entryIDs.count
    let onlyAppendsEntries =
      entriesChanged
      && previousEntryCount < nextIDs.count
      && zip(entryIDs, nextIDs).allSatisfy(==)
    self.entries = entries
    entryIDs = nextIDs
    entryVersions = nextVersions
    self.onExpand = onExpand
    self.onRedo = onRedo
    self.onCopyResult = onCopyResult
    if entriesChanged {
      if onlyAppendsEntries {
        appendMeasurementsIfPossible(startingAt: previousEntryCount)
      } else {
        recycleAllRows()
        measuredWidth = nil
      }
      invalidateIntrinsicContentSize()
      needsLayout = true
    } else {
      reconfigureActiveRows()
    }
    installObservationIfNeeded()
    updateVisibleRows()
  }

  func preferredHeight(for width: CGFloat) -> CGFloat {
    measureRowsIfNeeded(width: max(1, width))
    return measuredHeight
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    DispatchQueue.main.async { [weak self] in
      self?.installObservationIfNeeded()
      self?.updateVisibleRows()
    }
  }

  override func layout() {
    super.layout()
    measureRowsIfNeeded(width: max(1, bounds.width))
    updateVisibleRows()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaReference {
      removeTrackingArea(trackingAreaReference)
    }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    trackingAreaReference = trackingArea
  }

  override func mouseEntered(with event: NSEvent) {
    updateResolvedHoverStates()
  }

  override func mouseMoved(with event: NSEvent) {
    updateResolvedHoverStates()
  }

  override func mouseExited(with event: NSEvent) {
    updateResolvedHoverStates()
  }

  private func installObservationIfNeeded() {
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
    updateVisibleRows()
  }

  private func measureRowsIfNeeded(width: CGFloat) {
    guard measuredWidth != width || rowHeights.count != entries.count else { return }
    measuredWidth = width
    rowOffsets.removeAll(keepingCapacity: true)
    rowHeights.removeAll(keepingCapacity: true)
    rowOffsets.reserveCapacity(entries.count)
    rowHeights.reserveCapacity(entries.count)

    var offset: CGFloat = 0
    for entry in entries {
      rowOffsets.append(offset)
      let height = measuredRowHeight(for: entry, width: width)
      rowHeights.append(height)
      offset += height
    }
    measuredHeight = offset
  }

  private func appendMeasurementsIfPossible(startingAt index: Int) {
    guard
      measuredWidth != nil,
      rowOffsets.count == index,
      rowHeights.count == index
    else {
      self.measuredWidth = nil
      return
    }

    var offset = measuredHeight
    rowOffsets.reserveCapacity(entries.count)
    rowHeights.reserveCapacity(entries.count)
    for _ in entries[index...] {
      rowOffsets.append(offset)
      rowHeights.append(HistoryEntryPencilLayout.foldedRowStride)
      offset += HistoryEntryPencilLayout.foldedRowStride
    }
    measuredHeight = offset
  }

  private func measuredRowHeight(for _: HistoryEntry, width _: CGFloat) -> CGFloat {
    rowMeasurementCount += 1
    return HistoryEntryPencilLayout.foldedRowStride
  }

  private func updateVisibleRows() {
    guard !entries.isEmpty else {
      recycleAllRows()
      return
    }
    measureRowsIfNeeded(width: max(1, bounds.width))
    guard let clipView = observedClipView ?? enclosingScrollView?.contentView else { return }

    let visibleRect = convert(clipView.bounds, from: clipView)
    let overscan = max(visibleRect.height, 240)
    var minimumY = visibleRect.minY - overscan
    var maximumY = visibleRect.maxY + overscan
    if minimumY < 0 {
      maximumY -= minimumY
      minimumY = 0
    }
    if maximumY > measuredHeight {
      minimumY -= maximumY - measuredHeight
      maximumY = measuredHeight
    }
    minimumY = max(0, minimumY)
    maximumY = min(measuredHeight, maximumY)
    let lowerBound = firstRowEnding(after: minimumY)
    let upperBound = firstRowStarting(atOrAfter: maximumY)
    guard lowerBound < upperBound else {
      recycleAllRows()
      return
    }

    let nextRange = lowerBound..<upperBound
    if nextRange != activeRange {
      updateActiveRows(for: nextRange)
    }
    // Keep AppKit backing coordinates near the viewport while the outer view
    // continues to represent the complete virtual document height.
    let baseOffset = rowOffsets[nextRange.lowerBound]
    let finalIndex = nextRange.index(before: nextRange.endIndex)
    let maximumOffset = rowOffsets[finalIndex] + rowHeights[finalIndex]
    rowsContainer.frame = NSRect(
      x: 0,
      y: baseOffset,
      width: bounds.width,
      height: maximumOffset - baseOffset
    )
    for (offset, row) in activeRows.enumerated() {
      let index = nextRange.lowerBound + offset
      let nextFrame = NSRect(
        x: 0,
        y: rowOffsets[index] - baseOffset,
        width: bounds.width,
        height: rowHeights[index]
      )
      if row.frame != nextFrame {
        row.frame = nextFrame
      }
    }
    updateResolvedHoverStates()
  }

  private func updateActiveRows(for nextRange: Range<Int>) {
    for (offset, row) in activeRows.enumerated() {
      let index = activeRange.lowerBound + offset
      guard !nextRange.contains(index) else { continue }
      row.prepareForReuse()
      recycledRows.append(row)
    }

    scratchRows.removeAll(keepingCapacity: true)
    scratchRows.reserveCapacity(max(scratchRows.capacity, nextRange.count))
    for index in nextRange {
      if activeRange.contains(index) {
        scratchRows.append(activeRows[index - activeRange.lowerBound])
      } else {
        scratchRows.append(dequeueRow(for: index))
      }
    }
    activeRows.removeAll(keepingCapacity: true)
    swap(&activeRows, &scratchRows)
    activeRange = nextRange
    for row in recycledRows {
      row.isHidden = true
    }
  }

  private func dequeueRow(for index: Int) -> HistoryEntryNSView {
    let row: HistoryEntryNSView
    if let recycledRow = recycledRows.popLast() {
      row = recycledRow
    } else {
      row = makeRow()
      rowsContainer.addSubview(row)
    }
    let entry = entries[index]
    row.isHidden = false
    row.configureContent(
      entryID: entry.id,
      mode: entry.mode,
      metadata: entry.metadata,
      preview: entry.resultStorage.foldedPreview,
      state: entry.state,
      showsSeparator: true
    )
    return row
  }

  private func reconfigureActiveRows() {
    for (offset, row) in activeRows.enumerated() {
      let index = activeRange.lowerBound + offset
      guard entries.indices.contains(index) else { continue }
      let entry = entries[index]
      row.configureContent(
        entryID: entry.id,
        mode: entry.mode,
        metadata: entry.metadata,
        preview: entry.resultStorage.foldedPreview,
        state: entry.state,
        showsSeparator: true
      )
    }
  }

  private func makeRow() -> HistoryEntryNSView {
    let row = HistoryEntryNSView()
    row.setHoverManagedExternally(true)
    row.setActionHandlers(
      onExpand: { [weak self, weak row] in
        guard let self, let entry = row?.representedEntry(in: self.entries) else { return }
        self.onExpand?(entry)
      },
      onRedo: { [weak self, weak row] in
        guard let self, let entry = row?.representedEntry(in: self.entries) else { return }
        self.onRedo?(entry)
      },
      onCopyResult: { [weak self, weak row] in
        guard let self, let entry = row?.representedEntry(in: self.entries) else { return }
        self.onCopyResult?(entry)
      }
    )
    return row
  }

  private func updateResolvedHoverStates() {
    var hoveredIndex: Int?
    if let window,
      window.isKeyWindow,
      let clipView = observedClipView ?? enclosingScrollView?.contentView
    {
      let viewport = convert(clipView.bounds, from: clipView)
      let mouseLocation = convert(window.mouseLocationOutsideOfEventStream, from: nil)
      if viewport.contains(mouseLocation), bounds.contains(mouseLocation) {
        let candidate = firstRowEnding(after: mouseLocation.y)
        if activeRange.contains(candidate),
          rowOffsets[candidate] <= mouseLocation.y,
          mouseLocation.y < rowOffsets[candidate] + rowHeights[candidate]
        {
          hoveredIndex = candidate
        }
      }
    }

    for (offset, row) in activeRows.enumerated() {
      row.setResolvedHoverState(activeRange.lowerBound + offset == hoveredIndex)
    }
  }

  private func recycleAllRows() {
    guard !activeRows.isEmpty else {
      activeRange = 0..<0
      rowsContainer.frame = .zero
      return
    }
    for row in activeRows {
      row.prepareForReuse()
      row.isHidden = true
      recycledRows.append(row)
    }
    activeRows.removeAll(keepingCapacity: true)
    activeRange = 0..<0
    rowsContainer.frame = .zero
  }

  private func firstRowEnding(after position: CGFloat) -> Int {
    var lower = 0
    var upper = rowOffsets.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if rowOffsets[middle] + rowHeights[middle] <= position {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  private func firstRowStarting(atOrAfter position: CGFloat) -> Int {
    var lower = 0
    var upper = rowOffsets.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if rowOffsets[middle] < position {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }
}

@MainActor
class HistoryEntryActionButton: NSButton {
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

  override func layout() {
    super.layout()
    iconView.frame = bounds
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

@MainActor
final class HistoryEntryNSView: NSControl, HistoryResultHeightChangeHosting {
  enum Presentation: Equatable {
    case folded
    case expanded(isLatest: Bool)

    var isExpanded: Bool {
      if case .expanded = self { return true }
      return false
    }

    var isLatest: Bool {
      if case .expanded(let isLatest) = self { return isLatest }
      return false
    }
  }

  private enum Layout {
    static let foldedHorizontalInset = HistoryEntryPencilLayout.foldedHorizontalInset
    static let foldedVerticalInset = HistoryEntryPencilLayout.foldedVerticalInset
    static let expandedInset: CGFloat = 0
    static let expandedVerticalPadding: CGFloat = 16
    static let headerHeight = HistoryEntryPencilLayout.foldedHeaderHeight
    static let contentSpacing = HistoryEntryPencilLayout.foldedContentSpacing
    static let previewHeight = HistoryEntryPencilLayout.foldedPreviewHeight
    static let previewLineSpacing: CGFloat = 9.6
    static let actionSize = HistoryEntryPencilLayout.actionIconSize
    static let actionColumnWidth = HistoryEntryPencilLayout.actionColumnWidth
    static let foldedPreferredHeight = HistoryEntryPencilLayout.foldedHeight
    static let sourceHeight = HistoryEntryPencilLayout.latestSourcePreviewHeight
    static let sourceFadeHeight = HistoryEntryPencilLayout.latestSourceFadeHeight
  }

  private static let accentColor = NSColor(
    srgbRed: 46 / 255,
    green: 107 / 255,
    blue: 79 / 255,
    alpha: 1
  )
  private static let backgroundColor = NSColor(
    srgbRed: 250 / 255,
    green: 250 / 255,
    blue: 248 / 255,
    alpha: 1
  )
  private static let foldedBackgroundColor = NSColor(
    srgbRed: 250 / 255,
    green: 250 / 255,
    blue: 248 / 255,
    alpha: 1
  )
  private static let foldedHoverColor = NSColor(
    srgbRed: 241 / 255,
    green: 241 / 255,
    blue: 236 / 255,
    alpha: 1
  )
  private static let primaryTextColor = NSColor(
    srgbRed: 26 / 255,
    green: 26 / 255,
    blue: 24 / 255,
    alpha: 1
  )
  private static let tertiaryTextColor = NSColor(
    srgbRed: 181 / 255,
    green: 181 / 255,
    blue: 174 / 255,
    alpha: 1
  )
  private static let secondaryTextColor = NSColor(
    srgbRed: 138 / 255,
    green: 138 / 255,
    blue: 131 / 255,
    alpha: 1
  )
  private static let borderColor = NSColor(
    srgbRed: 232 / 255,
    green: 232 / 255,
    blue: 227 / 255,
    alpha: 1
  )
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
  private static let previewFont = CidaDesign.appKitBody(16)
  private let iconView = NSImageView()
  private let modeTextLayer = CATextLayer()
  private let metadataTextLayer = CATextLayer()
  private let previewTextLayer = CATextLayer()
  private let fadeLayer = CAGradientLayer()
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
    element.setAccessibilityParent(self)
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
  private var stickyResultActionView: StickyHistoryResultActionNSView?
  private var hoverTrackingView: HistoryEntryHoverTrackingNSView?
  private var resultContainer: HistoryResultTextContainer?
  private var resultCoordinator: HistoryResultTextCoordinator?
  private var copyResetWorkItem: DispatchWorkItem?
  private var sourceCopyResetWorkItem: DispatchWorkItem?
  private var resultCopyResetWorkItem: DispatchWorkItem?
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
  private(set) var presentation = Presentation.folded
  private var isHovering = false
  private var isSourceCopied = false
  private var isResultCopied = false
  private var isPresentationActive = true
  private var isHoverManagedExternally = false
  private var modeAttributedString = NSAttributedString()
  private var metadataAttributedString = NSAttributedString()
  private var previewAttributedString = NSAttributedString()
  private var onExpand: (@MainActor () -> Void)?
  private var onCollapse: (@MainActor () -> Void)?
  private var onRedo: (@MainActor () -> Void)?
  private var onCopySource: (@MainActor () -> Void)?
  private var onCopyResult: (@MainActor () -> Void)?

  #if DEBUG
    var headerModeFrameForTesting: NSRect { modeTextLayer.frame }
    var foldedPreviewFrameForTesting: NSRect { previewTextLayer.frame }
    var sourceFrameForTesting: NSRect { sourceTextField.frame }
    var sourceFadeFrameForTesting: NSRect { sourceFadeLayer.frame }
    var resultFrameForTesting: NSRect { resultContainer?.frame ?? .zero }
    var resultContainerForTesting: HistoryResultTextContainer? { resultContainer }
    var hasExpandHandlerForTesting: Bool { onExpand != nil }
    private(set) var mouseDownCountForTesting = 0
    var headerRendererIdentityForTesting: ObjectIdentifier {
      ObjectIdentifier(modeTextLayer)
    }
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
    layer?.cornerRadius = 8
    layer?.masksToBounds = true

    for textLayer in [modeTextLayer, metadataTextLayer, previewTextLayer] {
      textLayer.alignmentMode = .left
      textLayer.contentsGravity = .topLeft
      textLayer.truncationMode = .end
      textLayer.actions = Self.disabledLayerActions
      layer?.addSublayer(textLayer)
    }
    previewTextLayer.isWrapped = true
    previewTextLayer.truncationMode = .none
    previewTextLayer.masksToBounds = true
    fadeLayer.actions = Self.disabledLayerActions
    sourceFadeLayer.actions = Self.disabledLayerActions
    separatorLayer.actions = Self.disabledLayerActions
    separatorLayer.backgroundColor = Self.borderColor.cgColor
    layer?.addSublayer(fadeLayer)
    layer?.addSublayer(separatorLayer)
    updateLayerAppearance()
    updateLayerScale()

    iconView.imageScaling = .scaleProportionallyDown
    iconView.contentTintColor = Self.accentColor
    addSubview(iconView)

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
    sourceTextField.layer?.mask = sourceFadeLayer
    sourceTextField.isHidden = true
    addSubview(sourceTextField)

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("历史记录")
    previewAccessibilityElement.setAccessibilityRole(.staticText)
    previewAccessibilityElement.setAccessibilityParent(self)
    updateAccessibilityChildren()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
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
    setPresentation(.folded)
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
    isLatest: Bool,
    isLongEntry: Bool,
    showsSeparator: Bool,
    onCollapse: @escaping @MainActor () -> Void,
    onRedo: @escaping @MainActor () -> Void,
    onCopySource: @escaping @MainActor () -> Void,
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
    displayedSource = String(source.prefix(420))
    self.resultStorage = resultStorage
    resultPresentationRevision = presentationRevision
    self.latestPresentationDelta = latestPresentationDelta
    self.isLongEntry = isLongEntry
    self.onCollapse = onCollapse
    self.onRedo = onRedo
    self.onCopySource = onCopySource
    self.onCopyResult = onCopyResult
    setHoverManagedExternally(true)
    setPresentation(.expanded(isLatest: isLatest))
    configureExpandedContent()
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
    self.entryID = entryID
    self.mode = mode
    self.metadata = metadata
    self.preview = preview
    self.showsSeparator = showsSeparator
    entryState = state

    if contentChanged {
      iconView.image = LucideIconAsset.image(for: mode == .translate ? .languages : .sparkles)
      modeAttributedString = makeModeAttributedString()
      metadataAttributedString = makeMetadataAttributedString()
      previewAttributedString = makePreviewAttributedString()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      modeTextLayer.string = modeAttributedString
      metadataTextLayer.string = metadataAttributedString
      previewTextLayer.string = previewAttributedString
      CATransaction.commit()
      updateLayerAppearance()
      needsLayout = true
    }

    redoButton?.setAccessibilityIdentifier("history-action-redo-\(identifierSuffix)")
    copyButton?.setAccessibilityIdentifier("history-action-copy-result-\(identifierSuffix)")
    copySourceButton?.setAccessibilityIdentifier(
      "history-action-copy-source-\(identifierSuffix)"
    )
    updatePresentationAccessibility()
    updateActionVisibility()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
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
    isHovering = false
    isSourceCopied = false
    isResultCopied = false
    redoButton?.isHidden = true
    redoButton?.resetHoverState()
    copyButton?.isHidden = true
    copyButton?.resetHoverState()
    copySourceButton?.isHidden = true
    copySourceButton?.resetHoverState()
    presentation = .folded
    displayedSource = ""
    resultStorage = nil
    resultPresentationRevision = 0
    latestPresentationDelta = nil
    isLongEntry = false
    onCollapse = nil
    onCopySource = nil
    updateAccessibilityChildren()
    updateLayerAppearance()
    needsLayout = true
  }

  func detachStandalonePresentation() {
    prepareForReuse()
    removeScrollObservation()
  }

  func historyResultHeightWillChange(by delta: CGFloat) {
    invalidateIntrinsicContentSize()
    needsLayout = true
    var ancestor = superview
    while let current = ancestor {
      if let hostingView = current as? any HistoryResultHeightChangeHosting {
        hostingView.historyResultHeightWillChange(by: delta)
        break
      }
      ancestor = current.superview
    }
  }

  private func setPresentation(_ nextPresentation: Presentation) {
    let changed = presentation != nextPresentation
    presentation = nextPresentation

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
      sourceFadeLayer.isHidden = true
      copySourceButton?.isHidden = true
      previewTextLayer.isHidden = false
      fadeLayer.isHidden = preview.isEmpty
    case .expanded(let isLatest):
      previewTextLayer.isHidden = true
      fadeLayer.isHidden = true
      sourceTextField.isHidden = !isLatest
      sourceFadeLayer.isHidden = !isLatest
      hoverTrackingView?.setActive(true)
      stickyResultActionView?.isHidden = false
    }

    if changed {
      invalidateIntrinsicContentSize()
      needsLayout = true
    }
    updateLayerAppearance()
    updatePresentationAccessibility()
    updateActionVisibility()
  }

  private func configureExpandedContent() {
    guard presentation.isExpanded, let resultStorage else { return }
    let sourceParagraphStyle = NSMutableParagraphStyle()
    sourceParagraphStyle.lineSpacing = 3
    sourceParagraphStyle.lineBreakMode = .byWordWrapping
    sourceTextField.attributedStringValue = NSAttributedString(
      string: displayedSource,
      attributes: [
        .font: CidaDesign.appKitBody(13),
        .foregroundColor: Self.tertiaryTextColor,
        .paragraphStyle: sourceParagraphStyle,
      ]
    )
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
    tracker.setActive(true)

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
      isCopied: isResultCopied
    ) { [weak self] in
      self?.performExpandedResultCopy()
    }
    resultAction.isHidden = false
    resultContainer.isHidden = false
    sourceTextField.isHidden = !presentation.isLatest
    sourceFadeLayer.isHidden = !presentation.isLatest
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
      redoButton?.isHidden = true
      redoButton?.resetHoverState()
      copyButton?.isHidden = true
      copyButton?.resetHoverState()
      updateAccessibilityChildren()
    } else {
      updateTrackingAreas()
      installScrollObservationIfNeeded()
    }
    updateLayerAppearance()
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

  func preferredHeight(for _: CGFloat) -> CGFloat {
    switch presentation {
    case .folded:
      return Layout.foldedPreferredHeight
    case .expanded(let isLatest):
      let sourceHeight = isLatest ? Layout.sourceHeight + Layout.contentSpacing : 0
      let resultHeight =
        resultContainer?.naturalTextHeight ?? HistoryResultTextContainer.minimumHeight
      return Layout.expandedVerticalPadding * 2
        + Layout.headerHeight
        + Layout.contentSpacing
        + sourceHeight
        + resultHeight
        + (showsSeparator ? 1 : 0)
    }
  }

  private var showsVisibleActions: Bool {
    redoButton?.isHidden == false || copyButton?.isHidden == false
  }

  private func previewContentRect(contentHeight: CGFloat) -> NSRect {
    let originY = Layout.foldedVerticalInset + Layout.headerHeight + Layout.contentSpacing
    let innerWidth = max(0, bounds.width - Layout.foldedHorizontalInset * 2)
    let width = max(
      0,
      innerWidth - (showsVisibleActions ? Layout.actionColumnWidth : 0)
    )
    return NSRect(
      x: Layout.foldedHorizontalInset,
      y: originY,
      width: width,
      height: max(
        0,
        min(Layout.previewHeight, contentHeight - originY - Layout.foldedVerticalInset)
      )
    )
  }

  override func layout() {
    super.layout()
    let contentHeight = max(0, bounds.height - (showsSeparator ? 1 : 0))
    let contentInset =
      presentation.isExpanded ? Layout.expandedInset : Layout.foldedHorizontalInset
    let headerY =
      presentation.isExpanded ? Layout.expandedVerticalPadding : Layout.foldedVerticalInset
    iconView.frame = NSRect(
      x: contentInset,
      y: headerY + 2,
      width: 12,
      height: 12
    )
    let modeX = contentInset + 18
    let modeWidth = ceil(modeAttributedString.size().width)
    let headerRight = max(
      modeX,
      bounds.width - contentInset
        - (presentation.isExpanded || showsVisibleActions ? Layout.actionColumnWidth : 0)
    )
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    modeTextLayer.frame = NSRect(
      x: modeX,
      y: headerY,
      width: modeWidth,
      height: Layout.headerHeight
    )
    metadataTextLayer.frame = NSRect(
      x: modeX + modeWidth + 6,
      y: headerY,
      width: max(0, headerRight - modeX - modeWidth - 6),
      height: Layout.headerHeight
    )
    if presentation.isExpanded {
      layoutExpandedContent(headerY: headerY)
    } else {
      let previewRect = previewContentRect(contentHeight: contentHeight)
      previewTextLayer.frame = previewRect
      fadeLayer.frame = NSRect(
        x: previewRect.minX,
        y: max(previewRect.minY, previewRect.maxY - 25),
        width: previewRect.width,
        height: min(25, previewRect.height)
      )
    }
    separatorLayer.frame = NSRect(
      x: 0,
      y: bounds.maxY - 1,
      width: bounds.width,
      height: showsSeparator ? 1 : 0
    )
    CATransaction.commit()
    let actionX = max(
      contentInset,
      bounds.width - contentInset - Layout.actionSize
    )
    redoButton?.frame = NSRect(
      x: actionX,
      y: headerY + 2,
      width: Layout.actionSize,
      height: Layout.actionSize
    )
    if presentation.isExpanded {
      copySourceButton?.frame = NSRect(
        x: actionX,
        y: headerY + Layout.headerHeight + Layout.contentSpacing + 4,
        width: Layout.actionSize,
        height: Layout.actionSize
      )
    } else {
      copyButton?.frame = NSRect(
        x: actionX,
        y: Layout.foldedVerticalInset + Layout.headerHeight + Layout.contentSpacing + 4,
        width: Layout.actionSize,
        height: Layout.actionSize
      )
    }
    if window != nil {
      installScrollObservationIfNeeded()
      refreshHoverState()
    }
  }

  private func layoutExpandedContent(headerY: CGFloat) {
    let sourceY = headerY + Layout.headerHeight + Layout.contentSpacing
    let resultY =
      sourceY
      + (presentation.isLatest ? Layout.sourceHeight + Layout.contentSpacing : 0)
    let resultHeight =
      resultContainer?.naturalTextHeight ?? HistoryResultTextContainer.minimumHeight
    let textWidth = max(0, bounds.width - Layout.actionColumnWidth)

    sourceTextField.frame = NSRect(
      x: 0,
      y: sourceY,
      width: textWidth,
      height: Layout.sourceHeight
    )
    sourceFadeLayer.frame = sourceTextField.bounds
    resultContainer?.frame = NSRect(
      x: 0,
      y: resultY,
      width: textWidth,
      height: resultHeight
    )
    stickyResultActionView?.frame = NSRect(
      x: 0,
      y: resultY,
      width: bounds.width,
      height: resultHeight
    )
    hoverTrackingView?.frame = bounds
    if let resultCoordinator, let resultContainer {
      resultCoordinator.scheduleLayout(of: resultContainer)
    }
  }

  override func draw(_ dirtyRect: NSRect) {}

  fileprivate func accessibilityFrame(
    for region: HistoryEntryAccessibilityElement.Region
  ) -> NSRect {
    guard let window else { return .zero }
    let contentHeight = max(0, bounds.height - (showsSeparator ? 1 : 0))
    let localFrame: NSRect
    switch region {
    case .entry:
      if presentation.isExpanded {
        localFrame = NSRect(
          x: 0,
          y: Layout.expandedVerticalPadding,
          width: bounds.width,
          height: Layout.headerHeight
        )
      } else {
        localFrame = NSRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
      }
    case .preview:
      localFrame = previewContentRect(contentHeight: contentHeight)
    }
    return window.convertToScreen(convert(localFrame, to: nil))
  }

  private func updateLayerScale() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    modeTextLayer.contentsScale = scale
    metadataTextLayer.contentsScale = scale
    previewTextLayer.contentsScale = scale
  }

  private func updateLayerAppearance() {
    let backgroundColor: NSColor
    switch presentation {
    case .folded:
      backgroundColor = isHovering ? Self.foldedHoverColor : Self.foldedBackgroundColor
    case .expanded:
      backgroundColor = Self.backgroundColor
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.cornerRadius = presentation.isExpanded ? 0 : 8
    layer?.backgroundColor = backgroundColor.cgColor
    fadeLayer.colors = [
      backgroundColor.withAlphaComponent(0).cgColor,
      backgroundColor.cgColor,
    ]
    fadeLayer.locations = [0, 1]
    fadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
    fadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
    fadeLayer.isHidden = presentation.isExpanded || preview.isEmpty
    CATransaction.commit()
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
    updateLayerAppearance()
    needsLayout = true
  }

  override func mouseDown(with event: NSEvent) {
    #if DEBUG
      mouseDownCountForTesting &+= 1
    #endif
    guard isPresentationActive else { return }
    let location = convert(event.locationInWindow, from: nil)
    guard bounds.contains(location) else { return }
    switch presentation {
    case .folded:
      onExpand?()
    case .expanded(let isLatest):
      let headerY = Layout.expandedVerticalPadding
      let headerRect = NSRect(
        x: 0,
        y: headerY,
        width: bounds.width,
        height: Layout.headerHeight
      )
      if !isLatest, headerRect.contains(location) {
        onCollapse?()
      }
    }
  }

  override func accessibilityPerformPress() -> Bool {
    guard isPresentationActive else { return false }
    switch presentation {
    case .folded:
      onExpand?()
      return true
    case .expanded(let isLatest):
      guard !isLatest else { return false }
      onCollapse?()
      return true
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

  private func makePreviewAttributedString() -> NSAttributedString {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = Layout.previewLineSpacing
    paragraphStyle.lineBreakMode = .byWordWrapping
    return NSAttributedString(
      string: preview,
      attributes: [
        .font: Self.previewFont,
        .foregroundColor: Self.primaryTextColor,
        .paragraphStyle: paragraphStyle,
      ]
    )
  }

  private var identifierSuffix: String {
    entryID.uuidString.lowercased()
  }

  private func updateActionVisibility() {
    let showsActions = HistoryEntryActionPolicy.showsActions(
      isHovering: isPresentationActive && isHovering,
      state: entryState
    )
    let buttons = ensureActionButtons()
    buttons.redo.isHidden = !showsActions
    buttons.redo.resetHoverState()

    switch presentation {
    case .folded:
      buttons.copy.isHidden = !showsActions || preview.isEmpty
      buttons.copy.resetHoverState()
      copySourceButton?.isHidden = true
      stickyResultActionView?.isHidden = true
    case .expanded(let isLatest):
      buttons.copy.isHidden = true
      buttons.copy.resetHoverState()
      let sourceButton = isLatest ? ensureCopySourceButton() : nil
      sourceButton?.isHidden = !showsActions && !isSourceCopied
      sourceButton?.resetHoverState()
      if let stickyResultActionView, let resultStorage {
        stickyResultActionView.isHidden = false
        stickyResultActionView.configure(
          identifier: "history-action-copy-result-\(identifierSuffix)",
          isLongEntry: isLongEntry,
          isVisible: resultStorage.utf16Length > 0 && (showsActions || isResultCopied),
          isCopied: isResultCopied
        ) { [weak self] in
          self?.performExpandedResultCopy()
        }
      }
    }
    updateAccessibilityChildren()
    needsLayout = true
  }

  private var showsExpandedActions: Bool {
    HistoryEntryActionPolicy.showsActions(
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
    addSubview(button)
    copySourceButton = button
    return button
  }

  private func updateAccessibilityChildren() {
    guard isPresentationActive else {
      setAccessibilityChildren([])
      return
    }
    var children: [Any]
    switch presentation {
    case .folded:
      children = [expandAccessibilityElement, previewAccessibilityElement]
    case .expanded(let isLatest):
      children = isLatest ? [] : [expandAccessibilityElement]
      if isLatest {
        children.append(sourceTextField)
      }
      if let resultContainer {
        children.append(resultContainer)
      }
    }
    if let redoButton, !redoButton.isHidden {
      children.append(redoButton)
    }
    if let copyButton, !copyButton.isHidden {
      children.append(copyButton)
    }
    if let copySourceButton, !copySourceButton.isHidden {
      children.append(copySourceButton)
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

    switch presentation {
    case .folded:
      setAccessibilityLabel("历史记录，\(mode.title)，\(metadata)")
      setAccessibilityValue("collapsed")
      expandAccessibilityElement.setAccessibilityIdentifier(
        "history-expand-\(identifierSuffix)"
      )
      expandAccessibilityElement.setAccessibilityLabel("展开历史记录")
      expandAccessibilityElement.setAccessibilityHelp("显示完整结果")
      expandAccessibilityElement.setAccessibilityValue(preview)
    case .expanded(let isLatest):
      setAccessibilityLabel(
        isLatest
          ? "当前历史记录，\(mode.title)，\(metadata)"
          : "展开的历史记录，\(mode.title)，\(metadata)"
      )
      setAccessibilityValue("expanded")
      expandAccessibilityElement.setAccessibilityIdentifier(
        "history-collapse-\(identifierSuffix)"
      )
      expandAccessibilityElement.setAccessibilityLabel("收起历史记录")
      expandAccessibilityElement.setAccessibilityHelp("隐藏完整结果")
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
    button.setAccessibilityElement(true)
    button.setAccessibilityRole(.button)
    let accessibilityDescription =
      switch label {
      case "重新处理": "重新处理这条历史记录"
      case "复制原文": "复制这条历史记录的完整原文"
      default: "复制这条历史记录的完整结果"
      }
    let describedIcon = LucideIconAsset.image(for: icon)?.copy() as? NSImage
    describedIcon?.isTemplate = true
    describedIcon?.accessibilityDescription = accessibilityDescription
    button.image = describedIcon
    button.iconImage = describedIcon
    button.setAccessibilityLabel(accessibilityDescription)
    button.setAccessibilityHelp(accessibilityDescription)
    button.setAccessibilityIdentifier(identifier)
    return button
  }

  @objc
  private func redo(_ sender: NSButton) {
    onRedo?()
  }

  @objc
  private func copyResult(_ sender: NSButton) {
    onCopyResult?()
    copyResetWorkItem?.cancel()
    (sender as? HistoryEntryActionButton)?.iconImage = LucideIconAsset.image(for: .check)
    (sender as? HistoryEntryActionButton)?.setFeedbackTint(Self.accentColor)
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
    (sender as? HistoryEntryActionButton)?.iconImage = LucideIconAsset.image(for: .check)
    (sender as? HistoryEntryActionButton)?.setFeedbackTint(Self.accentColor)
    sender.setAccessibilityLabel("已复制这条历史记录的完整原文")
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
    copyButton?.iconImage = LucideIconAsset.image(for: .copy)
    copyButton?.setFeedbackTint(nil)
    copyButton?.setAccessibilityLabel("复制这条历史记录的完整结果")
  }

  private func resetSourceCopyFeedback() {
    copySourceButton?.iconImage = LucideIconAsset.image(for: .copy)
    copySourceButton?.setFeedbackTint(nil)
    copySourceButton?.setAccessibilityLabel("复制这条历史记录的完整原文")
  }
}

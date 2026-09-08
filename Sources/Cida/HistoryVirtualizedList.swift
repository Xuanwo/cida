import AppKit
import QuartzCore
import SwiftUI

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
      height: HistoryEntryPencilLayout.foldedListHeight(rowCount: entries.count)
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

  /// Placeholder cards keep the folded stride, including the gap before the
  /// first loaded card.
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
  private let cardLayer = CAShapeLayer()
  private let placeholderLayer = CAShapeLayer()
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
    layer?.backgroundColor = CidaDesign.Palette.background.appKit.cgColor
    cardLayer.fillColor = CidaDesign.Palette.surfaceFold.appKit.cgColor
    placeholderLayer.fillColor = CidaDesign.Palette.placeholder.appKit.cgColor
    for shapeLayer in [cardLayer, placeholderLayer] {
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
      cardLayer.path = nil
      placeholderLayer.path = nil
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
      cardLayer.path = nil
      placeholderLayer.path = nil
      renderedRowRange = 0..<0
      return
    }
    let rowRange = firstRow..<lastRow
    guard rowRange != renderedRowRange || abs(renderedWidth - bounds.width) > 0.5 else {
      return
    }
    renderedRowRange = rowRange
    renderedWidth = bounds.width

    let inset = HistoryEntryPencilLayout.foldedInset
    let cardPath = CGMutablePath()
    let placeholderPath = CGMutablePath()
    for row in rowRange {
      let originY = CGFloat(row) * stride
      cardPath.addRoundedRect(
        in: CGRect(
          x: 0,
          y: originY,
          width: bounds.width,
          height: HistoryEntryPencilLayout.foldedHeight
        ),
        cornerWidth: HistoryEntryPencilLayout.foldedCornerRadius,
        cornerHeight: HistoryEntryPencilLayout.foldedCornerRadius
      )
      placeholderPath.addRoundedRect(
        in: CGRect(x: inset, y: originY + inset + 5, width: 108, height: 6),
        cornerWidth: 3,
        cornerHeight: 3
      )
      placeholderPath.addRoundedRect(
        in: CGRect(
          x: inset,
          y: originY + 43,
          width: max(80, min(360, bounds.width * 0.42)),
          height: 7
        ),
        cornerWidth: 3.5,
        cornerHeight: 3.5
      )
      placeholderPath.addRoundedRect(
        in: CGRect(
          x: inset,
          y: originY + 66,
          width: max(60, min(260, bounds.width * 0.3)),
          height: 7
        ),
        cornerWidth: 3.5,
        cornerHeight: 3.5
      )
    }
    cardLayer.path = cardPath
    placeholderLayer.path = placeholderPath
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
    for (index, entry) in entries.enumerated() {
      if index > 0 {
        offset += HistoryEntryPencilLayout.foldedCardGap
      }
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
      if !rowOffsets.isEmpty {
        offset += HistoryEntryPencilLayout.foldedCardGap
      }
      rowOffsets.append(offset)
      rowHeights.append(HistoryEntryPencilLayout.foldedHeight)
      offset += HistoryEntryPencilLayout.foldedHeight
    }
    measuredHeight = offset
  }

  private func measuredRowHeight(for _: HistoryEntry, width _: CGFloat) -> CGFloat {
    rowMeasurementCount += 1
    return HistoryEntryPencilLayout.foldedHeight
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
      showsSeparator: false
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
        showsSeparator: false
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

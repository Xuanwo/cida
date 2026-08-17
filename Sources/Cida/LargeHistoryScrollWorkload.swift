import AppKit
import os

@MainActor
final class LargeHistoryScrollWorkload {
  static let historyEntryCount = 1_000
  static let minimumScrollDistancePoints: CGFloat = 12_000

  private let model: AppModel
  private let signposter = OSSignposter(subsystem: "com.xuanwo.Cida", category: "Performance")
  private weak var rootView: NSView?
  private weak var historyScrollView: NSScrollView?
  private var scrollDistancePoints: CGFloat = 0

  init(model: AppModel, rootView: NSView) {
    self.model = model
    self.rootView = rootView
    model.replaceHistoryEntries(Self.makeEntries())
  }

  @discardableResult
  func performUpwardScroll() -> Bool {
    let signpostState = signposter.beginInterval("HistoryScrollFrame")
    defer { signposter.endInterval("HistoryScrollFrame", signpostState) }
    return scrollUpward(recordsDistance: true)
  }

  func warmUpUpwardScroll() {
    _ = scrollUpward(recordsDistance: false)
  }

  func resetAfterWarmup() {
    prepareForScrolling()
    scrollDistancePoints = 0
  }

  @discardableResult
  private func scrollUpward(recordsDistance: Bool) -> Bool {
    guard let rootView else { return false }
    rootView.layoutSubtreeIfNeeded()
    guard let scrollView = historyScrollView ?? findHistoryScrollView(in: rootView),
      let documentView = scrollView.documentView
    else {
      return false
    }
    historyScrollView = scrollView

    let clipView = scrollView.contentView
    let visibleRect = clipView.documentVisibleRect
    let maximumOriginY = max(
      documentView.bounds.minY,
      documentView.bounds.maxY - visibleRect.height
    )
    let delta: CGFloat = documentView.isFlipped ? -32 : 32
    let nextOriginY = min(
      maximumOriginY,
      max(documentView.bounds.minY, visibleRect.minY + delta)
    )
    let distance = abs(nextOriginY - visibleRect.minY)
    guard distance > 0.5 else { return false }

    clipView.scroll(to: NSPoint(x: visibleRect.minX, y: nextOriginY))
    scrollView.reflectScrolledClipView(clipView)
    NotificationCenter.default.post(
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )
    rootView.layoutSubtreeIfNeeded()
    rootView.displayIfNeeded()
    if recordsDistance {
      scrollDistancePoints += distance
    }
    return true
  }

  func prepareForScrolling() {
    guard let rootView else { return }
    rootView.layoutSubtreeIfNeeded()
    guard let scrollView = historyScrollView ?? findHistoryScrollView(in: rootView),
      let documentView = scrollView.documentView
    else {
      return
    }
    historyScrollView = scrollView
    let clipView = scrollView.contentView
    let visibleRect = clipView.documentVisibleRect
    let bottomOriginY =
      documentView.isFlipped
      ? max(documentView.bounds.minY, documentView.bounds.maxY - visibleRect.height)
      : documentView.bounds.minY
    clipView.scroll(to: NSPoint(x: visibleRect.minX, y: bottomOriginY))
    scrollView.reflectScrolledClipView(clipView)
    rootView.layoutSubtreeIfNeeded()
    rootView.displayIfNeeded()
  }

  func metrics() -> FramePacingWorkloadMetrics {
    FramePacingWorkloadMetrics(
      completed: model.entries.count == Self.historyEntryCount
        && scrollDistancePoints >= Self.minimumScrollDistancePoints,
      historyEntryCount: model.entries.count,
      scrollDistancePoints: Double(scrollDistancePoints)
    )
  }

  private func findHistoryScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView,
      scrollView.accessibilityIdentifier() == "history-scroll-view"
    {
      return scrollView
    }
    for child in view.subviews {
      if let result = findHistoryScrollView(in: child) {
        return result
      }
    }
    return nil
  }

  private static func makeEntries() -> [HistoryEntry] {
    let persistedResult = String(
      repeating:
        "A persisted translation remains complete while its folded preview stays bounded. ",
      count: 64
    )
    return (0..<historyEntryCount).map { index in
      let isLatest = index == historyEntryCount - 1
      let result =
        isLatest
        ? "The latest result remains naturally expanded at the bottom of history."
        : persistedResult
      return HistoryEntry(
        mode: .translate,
        source: "Persisted source record \(index)",
        result: result,
        detail: "中文 → English",
        timestamp: "18:00",
        reportedSourceCharacterCount: 32,
        reportedResultCharacterCount: (result as NSString).length
      )
    }
  }
}

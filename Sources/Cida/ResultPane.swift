import AppKit
import SwiftUI

/// The result text inside a scroll view. The pane grows with the result until
/// the panel reaches its height budget, then scrolls; while a stream runs it
/// keeps the tail in view unless the user scrolled away.
struct ResultTextView: NSViewRepresentable {
  let record: ResultRecord?
  let generationState: GenerationPresentationState
  let isStale: Bool
  let followRevision: Int
  /// The tallest the text area can get before the pane scrolls instead.
  let maxVisibleHeight: CGFloat
  let onContentHeightChange: @MainActor (CGFloat, Bool) -> Void

  func makeCoordinator() -> ResultTextCoordinator {
    ResultTextCoordinator()
  }

  func makeNSView(context: Context) -> ResultScrollView {
    let scrollView = ResultScrollView()
    scrollView.onContentHeightChange = onContentHeightChange
    return scrollView
  }

  func updateNSView(_ scrollView: ResultScrollView, context: Context) {
    scrollView.onContentHeightChange = onContentHeightChange
    scrollView.maxVisibleHeight = maxVisibleHeight
    let container = scrollView.container
    guard let record else {
      context.coordinator.detach(from: container)
      container.replaceText("")
      container.setStreaming(false)
      return
    }
    let isStreaming = record.phase == .streaming
    if container.language != record.outputLanguage {
      container.language = record.outputLanguage
      context.coordinator.detach(from: container)
    }
    context.coordinator.observeStreamingUpdates(from: record.storage, in: container)
    context.coordinator.updateText(
      record.storage,
      entryID: record.id,
      presentationRevision: record.presentationRevision,
      latestPresentationDelta: record.latestPresentationDelta,
      isStreaming: isStreaming,
      in: container
    )
    container.setResultAccessibilityIdentifier("result-text")
    container.alphaValue = isStale ? 0.55 : 1
    context.coordinator.scheduleLayout(of: container)
    scrollView.setFollowsTail(isStreaming, forceRevision: followRevision)
  }

  static func dismantleNSView(_ scrollView: ResultScrollView, coordinator: ResultTextCoordinator) {
    coordinator.detach(from: scrollView.container)
  }
}

@MainActor
final class ResultScrollView: NSScrollView, ResultHeightChangeHosting {
  let container = ResultTextContainer()
  var onContentHeightChange: @MainActor (CGFloat, Bool) -> Void = { _, _ in }
  /// While the text is shorter than this the pane still grows, so following
  /// the tail would scroll up and then snap back once the pane catches up.
  var maxVisibleHeight: CGFloat = .greatestFiniteMagnitude
  private var followsTail = true
  private var appliedFollowRevision = -1
  private var isStreaming = false

  init() {
    super.init(frame: .zero)
    drawsBackground = false
    borderType = .noBorder
    hasVerticalScroller = false
    hasHorizontalScroller = false
    autohidesScrollers = true
    verticalScrollElasticity = .allowed
    // The indicator hangs past the right edge to line up with the source
    // pane's (`trailingOutset`); the clip view still clips the text.
    clipsToBounds = false
    container.autoresizingMask = [.width]
    documentView = container
    contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(boundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: contentView
    )
    let indicator = CidaScrollIndicator.install(on: self, configuration: .result)
    indicator.refresh()
    setAccessibilityIdentifier("result-scroll-view")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func layout() {
    super.layout()
    let width = contentView.bounds.width
    if abs(container.frame.width - width) > 0.5 {
      container.frame = NSRect(
        x: 0, y: 0, width: width,
        height: max(container.naturalTextHeight, bounds.height))
    }
    resizeDocument()
    if isStreaming, followsTail, paneIsAtItsCap {
      scrollToTail()
    }
    CidaScrollIndicator.installed(in: self)?.refresh()
  }

  func resultHeightWillChange(by delta: CGFloat, animated: Bool) {
    resizeDocument()
    onContentHeightChange(container.naturalTextHeight, animated)
    if isStreaming, followsTail, paneIsAtItsCap {
      scrollToTail()
    }
  }

  /// The visible area has stopped growing, so scrolling is the only way to
  /// show more; before that, `layout()` follows the tail once the frame lands.
  private var paneIsAtItsCap: Bool {
    contentView.bounds.height >= maxVisibleHeight - 0.5
  }

  /// Streaming keeps the tail visible; a forced follow (a new submission)
  /// re-attaches even after the user scrolled away.
  func setFollowsTail(_ streaming: Bool, forceRevision: Int) {
    isStreaming = streaming
    guard forceRevision != appliedFollowRevision else { return }
    let isFirstRevision = appliedFollowRevision < 0
    appliedFollowRevision = forceRevision
    followsTail = true
    // A completed result the panel starts with is read from the top; only a
    // running stream pulls the pane to its tail.
    if streaming, !isFirstRevision {
      scrollToTail()
    }
  }

  override func scrollWheel(with event: NSEvent) {
    super.scrollWheel(with: event)
    guard isStreaming else { return }
    followsTail = isScrolledToTail
  }

  private var isScrolledToTail: Bool {
    let visibleMaxY = contentView.bounds.maxY
    return visibleMaxY >= container.frame.height - 2
  }

  private func resizeDocument() {
    let height = max(container.naturalTextHeight, contentView.bounds.height)
    if abs(container.frame.height - height) > 0.5 {
      container.setFrameSize(NSSize(width: container.frame.width, height: height))
    }
  }

  /// The document's own height: the text plus nothing else.
  var documentHeight: CGFloat {
    container.frame.height
  }

  private func scrollToTail() {
    let target = max(0, container.frame.height - contentView.bounds.height)
    contentView.scroll(to: NSPoint(x: 0, y: target))
    reflectScrolledClipView(contentView)
  }

  @objc
  private func boundsDidChange(_ notification: Notification) {
    CidaScrollIndicator.installed(in: self)?.refresh()
  }
}

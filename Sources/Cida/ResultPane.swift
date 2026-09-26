import AppKit
import SwiftUI

/// The result text inside a scroll view. The pane grows with the result until
/// the panel reaches its height budget, then scrolls; while a stream runs it
/// keeps the tail in view unless the user scrolled away.
///
/// The view's height is the laid-out text, up to `maxVisibleHeight`. A record or
/// a width the text has not been laid out for yet is laid out when SwiftUI asks,
/// so the pane shows a new record at its own height from its first frame; later
/// growth while streaming stays coalesced and reaches SwiftUI through
/// `ResultScrollView.resultHeightDidChange`.
struct ResultTextView: NSViewRepresentable {
  let record: ResultRecord?
  let generationState: GenerationPresentationState
  let isStale: Bool
  let followRevision: Int
  /// The tallest the text area can get before the pane scrolls instead.
  let maxVisibleHeight: CGFloat

  func makeCoordinator() -> ResultTextCoordinator {
    ResultTextCoordinator()
  }

  func makeNSView(context: Context) -> ResultScrollView {
    ResultScrollView()
  }

  func updateNSView(_ scrollView: ResultScrollView, context: Context) {
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
    // A new record, or the same one set in another face: the document is replaced.
    let replacesDocument = context.coordinator.entryID != record.id
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
    container.setDimmed(isStale, animated: !replacesDocument)
    if replacesDocument {
      // The previous document must not be what the pane scrolls or shows.
      context.coordinator.layoutForSizing(container, width: container.frame.width)
      scrollView.documentDidReplace()
    }
    context.coordinator.scheduleLayout(of: container)
    scrollView.setFollowsTail(isStreaming, forceRevision: followRevision)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView scrollView: ResultScrollView, context: Context
  ) -> CGSize? {
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? scrollView.container.frame.width
    context.coordinator.layoutForSizing(scrollView.container, width: width)
    return CGSize(
      width: width, height: min(scrollView.container.naturalTextHeight, maxVisibleHeight))
  }

  static func dismantleNSView(_ scrollView: ResultScrollView, coordinator: ResultTextCoordinator) {
    coordinator.detach(from: scrollView.container)
  }
}

@MainActor
final class ResultScrollView: OverlayScrollView, ResultHeightChangeHosting {
  let container = ResultTextContainer()
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
    // System overlay scroll bar (`OverlayScrollView`), on the same edge as the
    // source pane's: the scroll view spans the pane and the container insets
    // its text.
    hasVerticalScroller = true
    hasHorizontalScroller = false
    autohidesScrollers = true
    verticalScrollElasticity = .allowed
    container.autoresizingMask = [.width]
    documentView = container
    setAccessibilityIdentifier("result-scroll-view")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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
  }

  /// The text's natural height changed: SwiftUI asks `ResultTextView` for the
  /// new size.
  func resultHeightDidChange(by delta: CGFloat) {
    resizeDocument()
    invalidateIntrinsicContentSize()
    if isStreaming, followsTail, paneIsAtItsCap {
      scrollToTail()
    }
  }

  /// The document was replaced: it is read from its top, and it is sized now, so
  /// a tail follow in the same update scrolls the new document rather than the
  /// old one.
  func documentDidReplace() {
    resizeDocument()
    contentView.scroll(to: .zero)
    reflectScrolledClipView(contentView)
    invalidateIntrinsicContentSize()
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
}

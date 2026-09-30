import AppKit
import SwiftUI

/// The result text inside a scroll view. The pane grows with the result until
/// the panel reaches its height budget, then scrolls. A result is read from its
/// start: a stream grows below the fold, and the pane follows the tail only
/// after the user scrolls down to it. An edge with text beyond it fades.
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
    scrollView.isStreaming = isStreaming
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
  var isStreaming = false
  /// Set only by the user scrolling to the end of a streaming result: text
  /// arrives faster than it is read, so pulling the pane to the tail on its
  /// own would carry the reader away from where they are reading.
  private var followsTail = false
  private let topFade = ResultEdgeFadeView(edge: .top)
  private let bottomFade = ResultEdgeFadeView(edge: .bottom)

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
    // Over the text, under the scroll bar.
    addSubview(topFade, positioned: .above, relativeTo: contentView)
    addSubview(bottomFade, positioned: .above, relativeTo: contentView)
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
    layoutEdgeFades()
  }

  override func reflectScrolledClipView(_ clipView: NSClipView) {
    super.reflectScrolledClipView(clipView)
    layoutEdgeFades()
  }

  /// Each fade is as deep as the text hidden beyond its edge, up to
  /// `ResultFade.length`, so it shrinks away as the user scrolls to that end
  /// instead of vanishing at the last point.
  private func layoutEdgeFades() {
    let clip = contentView.frame
    let visible = contentView.bounds
    let hiddenAbove = max(0, visible.minY)
    let hiddenBelow = max(0, container.frame.height - visible.maxY)
    for (fade, hidden) in [(topFade, hiddenAbove), (bottomFade, hiddenBelow)] {
      let depth = min(hidden, CidaDesign.ResultFade.length).rounded()
      fade.isHidden = depth < 1
      let atTop = (fade.edge == .top) == isFlipped
      let frame = NSRect(
        x: clip.minX, y: atTop ? clip.minY : clip.maxY - depth, width: clip.width, height: depth)
      guard frame != fade.frame else { continue }
      fade.frame = frame
      fade.needsDisplay = true
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

  /// The document was replaced: it is sized now and read from its top.
  func documentDidReplace() {
    followsTail = false
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

  override func scrollWheel(with event: NSEvent) {
    super.scrollWheel(with: event)
    guard isStreaming else { return }
    // While the pane still grows the whole document is in view, which is not
    // the user reaching the end.
    followsTail = paneIsAtItsCap && isScrolledToTail
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
    layoutEdgeFades()
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

/// Paper laid over one edge of the result pane where the result continues
/// beyond it, fading the ink there to `ResultFade.inkFloor`. It is drawn rather
/// than a layer mask so offscreen captures show it too; since it paints paper,
/// the pane behind it must stay solid `surface-paper`.
@MainActor
final class ResultEdgeFadeView: NSView {
  enum Edge {
    case top, bottom
  }

  let edge: Edge

  init(edge: Edge) {
    self.edge = edge
    super.init(frame: .zero)
    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isOpaque: Bool { false }

  /// Clicks and scrolls go to the text underneath.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let paper = CidaDesign.Palette.surfacePaper.appKit(dark: effectiveAppearance.isDark)
    let clear = paper.withAlphaComponent(0)
    let covering = paper.withAlphaComponent(1 - CidaDesign.ResultFade.inkFloor)
    // A gradient angle of 90° runs from the bottom of the rect to its top.
    let fromBottom = (edge == .bottom) != isFlipped
    NSGradient(starting: fromBottom ? covering : clear, ending: fromBottom ? clear : covering)?
      .draw(in: bounds, angle: 90)
  }
}

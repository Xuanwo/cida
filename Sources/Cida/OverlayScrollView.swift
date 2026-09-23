import AppKit

/// An `NSScrollView` whose scroll bar is always the system overlay bar.
///
/// AppKit switches every scroll view to the legacy bar (a permanent track
/// that narrows the content) when a mouse without a trackpad is attached or
/// the user picks "Always" for scroll bars in System Settings. The panel
/// floats over other apps like Spotlight and its text columns are sized by
/// the design, so it pins the overlay style: the bar appears while scrolling
/// or hovering and takes no width. AppKit re-applies the preferred style
/// through the setter, which is why the setter ignores its value.
@MainActor
class OverlayScrollView: NSScrollView {
  override var scrollerStyle: NSScroller.Style {
    get { .overlay }
    set { super.scrollerStyle = .overlay }
  }
}

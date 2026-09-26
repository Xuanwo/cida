import AppKit

@MainActor
enum CidaWindowFactory {
  static func makeWindow(
    size: CGSize,
    minimumSize: CGSize = CGSize(width: 480, height: 420),
    title: String
  ) -> CidaWindow {
    let window = CidaWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
        .fullSizeContentView,
      ],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unifiedCompact
    // The style only applies with a toolbar: an empty one gives the 40 pt compact title bar the
    // content's own title centres in, level with the traffic lights.
    window.toolbar = NSToolbar(identifier: "cida.window")
    window.isOpaque = true
    window.backgroundColor = CidaDesign.Palette.background.appKit
    window.hasShadow = true
    window.isMovableByWindowBackground = false
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    window.minSize = minimumSize
    window.contentMinSize = minimumSize
    window.tabbingMode = .disallowed
    return window
  }
}

final class CidaWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  /// Height changes AppKit makes for the content (a hosting controller's preferred content
  /// size) move over `motion-height-ms` with the top edge fixed instead of in one frame.
  var animatesHeightChanges = false
  /// The animation's own steps come back through `setFrame`; they pass straight through.
  private var isAnimatingHeight = false
  /// Counts moves, so a superseded move's fallback cannot pull the window back.
  private var heightMoveCount = 0

  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    let duration = CidaMotion.resolvedDuration(CidaMotion.heightSeconds, in: self)
    guard animatesHeightChanges, !isAnimatingHeight, isVisible, duration > 0,
      abs(frameRect.width - frame.width) < 0.5, abs(frameRect.height - frame.height) > 0.5
    else {
      super.setFrame(frameRect, display: flag)
      return
    }
    let target = NSRect(
      x: frame.minX, y: frame.maxY - frameRect.height, width: frame.width,
      height: frameRect.height)
    heightMoveCount += 1
    let move = heightMoveCount
    isAnimatingHeight = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CidaMotion.easeOut
      animator().setFrame(target, display: flag)
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.heightMoveCount == move else { return }
        self.isAnimatingHeight = false
      }
    }
    // A window the system does not draw (hidden, or on a locked screen) never steps the
    // animation or reports its end; a plain timer still lands it where its content asked.
    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.heightMoveCount == move else { return }
        self.isAnimatingHeight = false
        if self.frame != target { self.setFrameWithoutAnimation(target) }
      }
    }
  }

  private func setFrameWithoutAnimation(_ frameRect: NSRect) {
    super.setFrame(frameRect, display: true)
  }
}

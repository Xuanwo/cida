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
    window.isOpaque = true
    window.backgroundColor = NSColor(
      red: 250 / 255,
      green: 250 / 255,
      blue: 248 / 255,
      alpha: 1
    )
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

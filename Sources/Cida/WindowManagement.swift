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

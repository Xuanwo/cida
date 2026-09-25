import AppKit
import SwiftUI

/// The floating panel that is Cida's main interface (`Design/spec/panel.md`
/// §一). It never activates the app, so the application the user came from
/// keeps its focus and gets it back the moment the panel hides.
@MainActor
final class CidaPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init(width: CGFloat) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    hidesOnDeactivate = false
    isMovableByWindowBackground = false
    isReleasedWhenClosed = false
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    animationBehavior = .none
    title = "辞达"
    setAccessibilityIdentifier("cida-panel")
    setAccessibilityLabel("辞达")
  }
}

/// The height budget the panel offers its content on the screen it is shown
/// on. Both panes and the panel itself are capped relative to the visible
/// screen height (`panel-top-ratio`, `source-max-ratio`, `panel-max-ratio`).
struct PanelHeightBudget: Equatable, Sendable {
  let sourceEditorMaxHeight: CGFloat
  let panelMaxHeight: CGFloat

  init(visibleScreenHeight: CGFloat) {
    let paneInsets = CidaDesign.Spacing.paneVertical * 2
    sourceEditorMaxHeight = max(
      CidaDesign.Panel.compactEditorHeight,
      floor(visibleScreenHeight * CidaDesign.Panel.sourceMaxRatio) - paneInsets
    )
    panelMaxHeight = floor(visibleScreenHeight * CidaDesign.Panel.maxRatio)
  }

  static let automation = PanelHeightBudget(visibleScreenHeight: 1_000)
}

/// Owns the panel's lifecycle: where it appears, how tall it is, when it hides,
/// and what the panel-level keys do. The SwiftUI content reports the height it
/// wants; the controller resizes the panel from a fixed top edge.
@MainActor
final class PanelController {
  let panel: CidaPanel
  private let model: AppModel
  private let hostingView: NSHostingView<PanelView>
  private var keyMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var contentHeight: CGFloat = 120
  private(set) var heightBudget = PanelHeightBudget.automation
  private var topEdge: CGFloat?
  /// Production and E2E panels hide when they stop being key (the user left);
  /// probe and snapshot panels stay put so automation keeps a stable target.
  private let hidesOnResignKey: Bool
  private let openSettings: @MainActor () -> Void

  init(
    model: AppModel,
    hidesOnResignKey: Bool,
    openSettings: @escaping @MainActor () -> Void
  ) {
    self.model = model
    self.hidesOnResignKey = hidesOnResignKey
    self.openSettings = openSettings
    panel = CidaPanel(width: CidaDesign.Panel.width)

    // Sized before the hosting view joins it: the hosting view's flexible
    // width would otherwise absorb the container's first resize twice.
    let container = PanelContentView(frame: panel.contentRect(forFrameRect: panel.frame))
    let heightBudget = PanelHeightBudget.automation
    let rootView = PanelView(model: model, heightBudget: heightBudget)
    hostingView = NSHostingView(rootView: rootView)
    hostingView.setAccessibilityLabel("辞达面板内容")
    // The content keeps its own (final) height at the top of the flipped
    // container while the window animates its frame; the container clips the
    // part the window has not revealed yet. Filling the container would
    // re-centre the panes on every animation step, and Auto Layout
    // constraints would let AppKit resize the window to the hosting view's
    // intrinsic size, so the frame is managed by hand.
    hostingView.autoresizingMask = [.width]
    hostingView.frame = NSRect(x: 0, y: 0, width: CidaDesign.Panel.width, height: contentHeight)
    container.addSubview(hostingView)
    hostingView.needsLayout = true
    panel.contentView = container
    applyRootView()
    installKeyMonitor()
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: panel,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.hidesOnResignKey, self.panel.isVisible else { return }
        self.hide()
      }
    }
  }

  /// The controller lives as long as the app; tear the monitors down here if
  /// an owner ever lets it go.
  func invalidate() {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    if let resignObserver {
      NotificationCenter.default.removeObserver(resignObserver)
      self.resignObserver = nil
    }
  }

  var isVisible: Bool {
    panel.isVisible
  }

  var contentView: NSView? {
    panel.contentView
  }

  /// Shows the panel on the active screen. Every appearance resets the action
  /// to 翻译 and selects the whole source, so typing or ⌘V starts a new task.
  func show() {
    if let screen = Self.activeScreen() {
      heightBudget = PanelHeightBudget(visibleScreenHeight: screen.visibleFrame.height)
      applyRootView()
      let visible = screen.visibleFrame
      topEdge = visible.maxY - floor(visible.height * CidaDesign.Panel.topRatio)
      let origin = NSPoint(
        x: floor(visible.midX - panel.frame.width / 2),
        y: topEdge! - panel.frame.height
      )
      panel.setFrameOrigin(origin)
    }
    model.resetModeToDefault()
    // Appears at once, like Spotlight. A probe launch may have parked the
    // panel transparent (`prepareAutomationPanel`), so restore full opacity.
    panel.alphaValue = 1
    panel.makeKeyAndOrderFront(nil)
    model.requestInputFocus()
    model.requestInputSelectAll()
  }

  func hide() {
    guard panel.isVisible else { return }
    panel.orderOut(nil)
  }

  func toggle() {
    if panel.isVisible { hide() } else { show() }
  }

  /// Called by the content whenever the height it wants changes. The panel
  /// grows or shrinks from its top edge over `motion-height-ms`.
  func setContentHeight(_ height: CGFloat, animated: Bool) {
    let clamped = min(heightBudget.panelMaxHeight, max(1, ceil(height)))
    guard abs(clamped - contentHeight) > 0.5 else { return }
    contentHeight = clamped
    hostingView.setFrameSize(NSSize(width: hostingView.frame.width, height: clamped))
    hostingView.needsLayout = true
    let top = topEdge ?? panel.frame.maxY
    let frame = NSRect(
      x: panel.frame.minX,
      y: top - clamped,
      width: panel.frame.width,
      height: clamped
    )
    let duration = animated ? CidaMotion.resolvedDuration(CidaMotion.heightSeconds, in: panel) : 0
    if duration > 0 {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CidaMotion.easeOut
        panel.animator().setFrame(frame, display: true)
      }
    } else {
      panel.setFrame(frame, display: true)
    }
  }

  private func applyRootView() {
    hostingView.rootView = PanelView(
      model: model,
      heightBudget: heightBudget,
      onContentHeightChange: { [weak self] height, animated in
        self?.setContentHeight(height, animated: animated)
      }
    )
  }

  /// Panel-level keys (`Design/spec/panel.md` §五). Text editing keys stay
  /// with the editor; these only fire while the panel is key.
  private func installKeyMonitor() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, NSApp.keyWindow === self.panel else { return event }
      // Escape cancels a pinyin composition and Tab may pick a candidate; the
      // input method must see every key before the panel's shortcuts do.
      if InputMethodRouting.isComposing(in: self.panel) { return event }
      let modifiers = event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting(.capsLock)

      if CopyShortcutRouting.isResultShortcut(event) {
        if CopyShortcutRouting.nativeTextResponderOwnsCopy(window: self.panel) {
          return event
        }
        return self.model.copyResult() ? nil : event
      }

      if modifiers == .command, event.charactersIgnoringModifiers == "." {
        self.model.cancelProcessing()
        return nil
      }
      if modifiers == .command, event.charactersIgnoringModifiers == "," {
        self.openSettings()
        return nil
      }

      switch event.keyCode {
      case 48 where modifiers.isEmpty:
        self.model.toggleMode()
        return nil
      case 53 where modifiers.isEmpty:
        self.hide()
        return nil
      default:
        return event
      }
    }
  }

  /// The screen under the pointer, which is where the user is working; the
  /// main screen otherwise.
  static func activeScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    if let underPointer = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
      return underPointer
    }
    return NSScreen.main
  }
}

/// Whether the panel's first responder is a text view with marked text, in
/// which case the input method owns the keyboard.
enum InputMethodRouting {
  @MainActor
  static func isComposing(in window: NSWindow) -> Bool {
    guard let textView = window.firstResponder as? NSTextView else { return false }
    return textView.hasMarkedText()
  }
}

/// Rounded, clipped panel surface. The window itself is transparent so the
/// corner radius and the shadow come from this view.
@MainActor
final class PanelContentView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = CidaDesign.Radius.panel
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.backgroundColor = CidaDesign.Palette.surface.appKit.cgColor
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.black.withAlphaComponent(0.07).cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool { true }
}

@MainActor
enum CopyShortcutRouting {
  static func isResultShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)
    guard modifiers == .command else { return false }
    return event.keyCode == 8 || event.charactersIgnoringModifiers?.lowercased() == "c"
  }

  /// ⌘C keeps its native meaning while a text view has a selection or is the
  /// editable source; only then does it fall through to copying the result.
  static func nativeTextResponderOwnsCopy(window: NSWindow?) -> Bool {
    guard let textView = window?.firstResponder as? NSTextView else { return false }
    return textView.selectedRange().length > 0
  }
}

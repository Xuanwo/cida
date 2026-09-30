import AppKit
import Carbon.HIToolbox
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
  private let clipboardHandoff: ClipboardManagerPasteHandoff
  private var keyMonitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var contentHeight: CGFloat = 120
  /// Identifies the latest height change, so an interrupted animation's
  /// completion does not shrink the host under a newer one.
  private var heightChangeGeneration = 0
  private(set) var heightBudget = PanelHeightBudget.automation
  private var topEdge: CGFloat?
  /// Production and E2E panels hide when they stop being key (the user left);
  /// probe and snapshot panels stay put so automation keeps a stable target.
  private let hidesOnResignKey: Bool
  private let openSettings: @MainActor () -> Void
  /// Told after every show and hide, whichever path caused it.
  var onVisibilityChange: (@MainActor (_ isVisible: Bool) -> Void)?

  init(
    model: AppModel,
    hidesOnResignKey: Bool,
    openSettings: @escaping @MainActor () -> Void,
    clipboardHandoff: ClipboardManagerPasteHandoff = ClipboardManagerPasteHandoff()
  ) {
    self.model = model
    self.hidesOnResignKey = hidesOnResignKey
    self.openSettings = openSettings
    self.clipboardHandoff = clipboardHandoff
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
        guard let self else { return }
        self.model.isCopyMenuOpen = false
        guard self.hidesOnResignKey, self.panel.isVisible else { return }
        if self.clipboardHandoff.isWaiting { return }
        if !Self.currentEventIsMouseDismissal() {
          self.beginKeyboardClipboardManagerHandoff()
          return
        }
        if self.beginClipboardManagerHandoffIfNeeded() { return }
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
    if model.panelMessage == nil, model.needsModelConfiguration {
      // The welcome may have been answered with ⏎ in an earlier appearance.
      model.clearConfigurationReminder()
    }
    model.resetModeToDefault()
    if let screen = Self.activeScreen() {
      heightBudget = PanelHeightBudget(visibleScreenHeight: screen.visibleFrame.height)
      applyRootView()
      // The height the content reports now lands before the panel is drawn; see
      // `layOutHiddenContent()`.
      hostingView.layoutSubtreeIfNeeded()
      let visible = screen.visibleFrame
      topEdge = CidaDesign.Panel.topEdge(in: visible)
      let origin = NSPoint(
        x: floor(visible.midX - panel.frame.width / 2),
        y: topEdge! - panel.frame.height
      )
      panel.setFrameOrigin(origin)
    }
    // Appears at once, like Spotlight. A probe launch may have parked the
    // panel transparent (`prepareAutomationPanel`), so restore full opacity.
    panel.alphaValue = 1
    panel.makeKeyAndOrderFront(nil)
    model.requestInputFocus()
    model.requestInputSelectAll()
    onVisibilityChange?(true)
  }

  /// Lays out what the model changed while the panel was hidden, such as an
  /// imported selection or a capture's text, so the panel appears at that
  /// content's height instead of its last one and does not animate from one to
  /// the other as it appears. A hidden panel is never drawn, so its content
  /// reports a new height only when asked to lay out; the source editor then
  /// measures the new text and publishes its height one main-actor turn later,
  /// which takes a second pass.
  func layOutHiddenContent() async {
    guard !panel.isVisible else { return }
    hostingView.layoutSubtreeIfNeeded()
    await Task.yield()
    hostingView.layoutSubtreeIfNeeded()
  }

  /// Every way of hiding the panel answers a message on it with its last choice
  /// (`Design/spec/lifecycle.md` §一).
  func hide() {
    guard panel.isVisible else { return }
    clipboardHandoff.cancel()
    panel.orderOut(nil)
    model.isCopyMenuOpen = false
    model.dismissPanelMessage()
    model.cancelForeignLanguageEditing()
    onVisibilityChange?(false)
  }

  func toggle() {
    if panel.isVisible { hide() } else { show() }
  }

  /// Called by the content whenever the height it wants changes. The panel
  /// grows or shrinks from its top edge over `motion-height-ms`; a hidden panel
  /// has nothing to animate and takes the height at once.
  ///
  /// The content is already laid out at its final height at the top of the
  /// host, and the window's frame is the only thing that moves. The host is
  /// never shorter than the window: it grows at once, and while the window
  /// shrinks it keeps its height until the window has caught up, so what shows
  /// below the content is the surface `PanelView` paints there (its bottom
  /// pane's) instead of the empty container.
  func setContentHeight(_ height: CGFloat, animated: Bool) {
    let clamped = min(heightBudget.panelMaxHeight, max(1, ceil(height)))
    guard abs(clamped - contentHeight) > 0.5 else { return }
    contentHeight = clamped
    heightChangeGeneration &+= 1
    let top = topEdge ?? panel.frame.maxY
    let frame = NSRect(
      x: panel.frame.minX,
      y: top - clamped,
      width: panel.frame.width,
      height: clamped
    )
    let duration =
      animated && panel.isVisible
      ? CidaMotion.resolvedDuration(CidaMotion.heightSeconds, in: panel) : 0
    if duration == 0 || clamped > hostingView.frame.height {
      setHostHeight(clamped)
    }
    guard duration > 0 else {
      panel.setFrame(frame, display: true)
      return
    }
    let generation = heightChangeGeneration
    animateFrame(to: frame, duration: duration) { [weak self] in
      guard let self, self.heightChangeGeneration == generation else { return }
      self.setHostHeight(self.contentHeight)
    }
  }

  private func setHostHeight(_ height: CGFloat) {
    guard abs(hostingView.frame.height - height) > 0.5 else { return }
    hostingView.setFrameSize(NSSize(width: hostingView.frame.width, height: height))
    hostingView.needsLayout = true
  }

  private func animateFrame(
    to frame: NSRect,
    duration: TimeInterval,
    completion: @escaping @MainActor () -> Void
  ) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CidaMotion.heightCurve.timingFunction
      panel.animator().setFrame(frame, display: true)
    } completionHandler: {
      MainActor.assumeIsolated { completion() }
    }
  }

  private func applyRootView() {
    hostingView.rootView = PanelView(
      model: model,
      heightBudget: heightBudget,
      onContentHeightChange: { [weak self] height, animated in
        self?.setContentHeight(height, animated: animated)
      },
      openSettings: openSettings
    )
  }

  private func beginClipboardManagerHandoffIfNeeded() -> Bool {
    clipboardHandoff.begin(
      isClipboardManagerActive: Self.isSupportedClipboardManagerActive,
      paste: { [weak self] text in
        self?.pasteClipboardManagerSelection(text) ?? false
      },
      hide: { [weak self] in
        guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
        self.hide()
      }
    )
  }

  private func beginKeyboardClipboardManagerHandoff() {
    clipboardHandoff.beginKeyboardInvocation(
      paste: { [weak self] text in
        self?.pasteClipboardManagerSelection(text) ?? false
      },
      hide: { [weak self] in
        guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
        self.hide()
      }
    )
  }

  private static func isSupportedClipboardManagerActive() -> Bool {
    if ClipboardManagerPasteHandoff.isSupported(
      bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    {
      return true
    }
    return ClipboardManagerPasteHandoff.supportedBundleIdentifiers.contains { bundleIdentifier in
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .contains { $0.isActive }
    }
  }

  private static func currentEventIsMouseDismissal() -> Bool {
    guard let event = NSApp.currentEvent else { return false }
    switch event.type {
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
      return true
    default:
      return false
    }
  }

  private func pasteClipboardManagerSelection(_ text: String) -> Bool {
    guard
      panel.isVisible,
      let contentView = panel.contentView,
      let input = Self.firstComposerInput(in: contentView)
    else {
      return false
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(input)
    model.requestInputFocus()
    let prepared = ComposerPreparedPaste(text)
    if input.performPaste(prepared) { return true }
    input.insertText(text, replacementRange: input.selectedRange())
    return true
  }

  private static func firstComposerInput(in view: NSView) -> ComposerNativeTextView? {
    if let input = view as? ComposerNativeTextView,
      input.accessibilityIdentifier() == "composer-input"
    {
      return input
    }
    for child in view.subviews {
      if let found = firstComposerInput(in: child) { return found }
    }
    return nil
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

      if ClipboardManagerShortcutRouting.isInvocationShortcut(event, modifiers: modifiers) {
        self.beginKeyboardClipboardManagerHandoff()
        return event
      }

      if CopyShortcutRouting.isImageShortcut(event) {
        return self.model.copyResultImage() ? nil : event
      }
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

      if self.model.isCopyMenuOpen, event.keyCode == 53, modifiers.isEmpty {
        self.model.isCopyMenuOpen = false
        return nil
      }

      if self.model.panelMessage != nil {
        switch event.keyCode {
        case 48 where modifiers.isEmpty:
          self.model.selectNextPanelMessageChoice()
          return nil
        case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty:
          self.model.performPanelMessageChoice()
          return nil
        case 53 where modifiers.isEmpty:
          self.hide()
          return nil
        default:
          return nil
        }
      }

      // The foreign language's field keeps ⏎ and typing; Esc drops the edit instead of hiding
      // the panel, and Tab stays with the field (`Design/spec/panel.md` §三).
      if self.model.isEditingForeignLanguage {
        switch event.keyCode {
        case 48 where modifiers.isEmpty:
          return nil
        case 53 where modifiers.isEmpty:
          self.model.cancelForeignLanguageEditing()
          return nil
        default:
          return event
        }
      }

      if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "l" {
        return self.model.beginEditingForeignLanguage() ? nil : event
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

/// Keeps the panel alive while a clipboard manager writes the item the user picked,
/// then lets the source editor paste it as if the manager's simulated paste had
/// reached the non-activating panel.
@MainActor
final class ClipboardManagerPasteHandoff {
  static let supportedBundleIdentifiers: Set<String> = ["com.raycast.macos"]

  private let pasteboard: NSPasteboard
  private let pollInterval: Duration
  private let activationTimeout: Duration
  private let selectionTimeout: Duration
  private let inactiveGrace: Duration
  private let pasteSuppressionDuration: Duration
  private var task: Task<Void, Never>?

  var isWaiting: Bool {
    task != nil
  }

  init(
    pasteboard: NSPasteboard = .general,
    pollInterval: Duration = .milliseconds(20),
    activationTimeout: Duration = .milliseconds(300),
    selectionTimeout: Duration = .seconds(30),
    inactiveGrace: Duration = .milliseconds(250),
    pasteSuppressionDuration: Duration = .milliseconds(700)
  ) {
    self.pasteboard = pasteboard
    self.pollInterval = pollInterval
    self.activationTimeout = activationTimeout
    self.selectionTimeout = selectionTimeout
    self.inactiveGrace = inactiveGrace
    self.pasteSuppressionDuration = pasteSuppressionDuration
  }

  static func isSupported(bundleIdentifier: String?) -> Bool {
    supportedBundleIdentifiers.contains(bundleIdentifier ?? "")
  }

  func begin(
    isClipboardManagerActive: @escaping @MainActor () -> Bool,
    paste: @escaping @MainActor (String) -> Bool,
    hide: @escaping @MainActor () -> Void
  ) -> Bool {
    cancel()
    let startingChangeCount = pasteboard.changeCount
    let pasteboard = pasteboard
    let pollInterval = pollInterval
    let activationTimeout = activationTimeout
    let selectionTimeout = selectionTimeout
    let inactiveGrace = inactiveGrace
    let pasteSuppressionDuration = pasteSuppressionDuration
    task = Task { @MainActor [weak self] in
      defer { self?.task = nil }
      let clock = ContinuousClock()
      let activationDeadline = clock.now.advanced(by: activationTimeout)
      while !Task.isCancelled, clock.now < activationDeadline {
        if Self.consumeClipboardChange(
          since: startingChangeCount, from: pasteboard,
          suppressFor: pasteSuppressionDuration, paste: paste, hide: hide)
        {
          return
        }
        if isClipboardManagerActive() { break }
        try? await Task.sleep(for: pollInterval)
      }
      guard !Task.isCancelled, isClipboardManagerActive() else {
        hide()
        return
      }

      let selectionDeadline = clock.now.advanced(by: selectionTimeout)
      var inactiveSince: ContinuousClock.Instant?
      while !Task.isCancelled, clock.now < selectionDeadline {
        if Self.consumeClipboardChange(
          since: startingChangeCount, from: pasteboard,
          suppressFor: pasteSuppressionDuration, paste: paste, hide: hide)
        {
          return
        }
        if isClipboardManagerActive() {
          inactiveSince = nil
        } else if let inactiveSince {
          if inactiveSince.duration(to: clock.now) >= inactiveGrace {
            hide()
            return
          }
        } else {
          inactiveSince = clock.now
        }
        try? await Task.sleep(for: pollInterval)
      }
      if !Task.isCancelled { hide() }
    }
    return true
  }

  func beginKeyboardInvocation(
    paste: @escaping @MainActor (String) -> Bool,
    hide: @escaping @MainActor () -> Void
  ) {
    beginWaitingForClipboardChange(
      since: pasteboard.changeCount,
      timeout: selectionTimeout,
      paste: paste,
      hide: hide
    )
  }

  private func beginWaitingForClipboardChange(
    since startingChangeCount: Int,
    timeout: Duration,
    paste: @escaping @MainActor (String) -> Bool,
    hide: @escaping @MainActor () -> Void
  ) {
    cancel()
    let pasteboard = pasteboard
    let pollInterval = pollInterval
    let pasteSuppressionDuration = pasteSuppressionDuration
    let deadline = ContinuousClock().now.advanced(by: timeout)
    task = Task { @MainActor [weak self] in
      defer { self?.task = nil }
      let clock = ContinuousClock()
      while !Task.isCancelled, clock.now < deadline {
        if Self.consumeClipboardChange(
          since: startingChangeCount, from: pasteboard,
          suppressFor: pasteSuppressionDuration, paste: paste, hide: hide)
        {
          return
        }
        try? await Task.sleep(for: pollInterval)
      }
      if !Task.isCancelled { hide() }
    }
  }

  private static func consumeClipboardChange(
    since startingChangeCount: Int,
    from pasteboard: NSPasteboard,
    suppressFor suppressionDuration: Duration,
    paste: @escaping @MainActor (String) -> Bool,
    hide: @escaping @MainActor () -> Void
  ) -> Bool {
    guard pasteboard.changeCount != startingChangeCount else { return false }
    guard pasteboard.types?.isEmpty != true else { return false }
    guard let text = pasteboard.string(forType: .string) else {
      hide()
      return true
    }
    suppressExternalPaste(of: text, on: pasteboard, for: suppressionDuration)
    guard paste(text) else {
      hide()
      return true
    }
    return true
  }

  private static func suppressExternalPaste(
    of text: String,
    on pasteboard: NSPasteboard,
    for duration: Duration
  ) {
    let empty = NSPasteboardItem()
    empty.setData(Data(), forType: PasteboardSnapshot.transientType)
    pasteboard.clearContents()
    pasteboard.writeObjects([empty])
    let suppressionChangeCount = pasteboard.changeCount
    Task { @MainActor in
      try? await Task.sleep(for: duration)
      guard pasteboard.changeCount == suppressionChangeCount else { return }
      let restored = NSPasteboardItem()
      restored.setString(text, forType: .string)
      restored.setData(Data(), forType: PasteboardSnapshot.transientType)
      pasteboard.clearContents()
      pasteboard.writeObjects([restored])
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}

enum ClipboardManagerShortcutRouting {
  static func isInvocationShortcut(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
    modifiers == .option && event.keyCode == UInt16(kVK_Space)
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
    layer?.borderWidth = 1
    applyAppearance()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  private func applyAppearance() {
    layer?.backgroundColor = CidaDesign.Palette.surface.cgColor(in: effectiveAppearance)
    layer?.borderColor = CidaDesign.Palette.panelEdge.cgColor(in: effectiveAppearance)
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
    isCopyKey(event, modifiers: .command)
  }

  /// ⇧⌘C copies the share card whether or not a text view has a selection:
  /// the card is always the whole source and result (`Design/spec/panel.md` §八).
  static func isImageShortcut(_ event: NSEvent) -> Bool {
    isCopyKey(event, modifiers: [.command, .shift])
  }

  private static func isCopyKey(_ event: NSEvent, modifiers expected: NSEvent.ModifierFlags) -> Bool {
    let modifiers = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)
    guard modifiers == expected else { return false }
    return event.keyCode == 8 || event.charactersIgnoringModifiers?.lowercased() == "c"
  }

  /// ⌘C keeps its native meaning while a text view has a selection or is the
  /// editable source; only then does it fall through to copying the result.
  static func nativeTextResponderOwnsCopy(window: NSWindow?) -> Bool {
    guard let textView = window?.firstResponder as? NSTextView else { return false }
    return textView.selectedRange().length > 0
  }
}

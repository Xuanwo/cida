import AppKit
import ScreenCaptureKit
import os

/// Runs the translation layer (`Design/spec/translation-layer.md`): ⌥D turns the paragraph
/// under the pointer into its translation and back (§二), ⌥⇧D translates every window of an
/// app or site (§三). Each pane in use is a `LayerPaneSession` that reads its paragraphs,
/// translates what is not in the user's own language, and keeps the translations over the
/// originals while the pane scrolls, moves or gets covered.
@MainActor
final class TranslationLayerController {
  private let settings: () -> CidaSettings
  private let service: any TextProcessingService
  private let namespace: String
  private let persists: Bool
  private(set) var windowRules: [LayerWindowRule]
  private var sessions: [LayerPaneSession] = []
  private let cache = LayerTranslationCache()
  private var tick: Timer?
  private var tickCount = 0
  private var windows: [LayerWindowInfo] = []
  private var monitors: [Any] = []
  private var discovering = false
  private var enabledTrees: Set<pid_t> = []
  /// Everything the layer says (§五 提示胶囊).
  private lazy var hints = LayerHintPanel()
  /// The failure the hint pill shows, so it is said once and taken back when it clears.
  private var shownFailure: LayerTranslationError?
  private lazy var outline = LayerOutlinePanel()
  var lifecycleLog: ((String) -> Void)?

  init(
    settings: @escaping () -> CidaSettings, service: any TextProcessingService, namespace: String,
    persists: Bool
  ) {
    self.settings = settings
    self.service = service
    self.namespace = namespace
    self.persists = persists
    windowRules = persists ? SettingsStore.loadLayerWindowRules(namespace: namespace) : []
  }

  func start() {
    guard tick == nil else { return }
    // 20 Hz: often enough to notice motion within a frame or two of the tree changing.
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.step() }
    }
    RunLoop.main.add(timer, forMode: .common)
    tick = timer
    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
        MainActor.assumeIsolated { self?.noteScroll() }
      } as Any)
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated {
        self?.frontApplicationChanged(to: running?.processIdentifier)
        // Chromium and Electron build their tree about two seconds after being asked; asking
        // when they come to the front saves that wait on the first ⌥D (§二 提前读取).
        if let running, let application = LayerApplication(running) { self?.enableTree(of: application) }
        self?.discover()
      }
    }
  }

  // MARK: ⌥D: this paragraph

  /// Turns the paragraph under `point` (top-left screen coordinates) into its translation, or
  /// back into the original when it already shows one (§二).
  func toggleParagraph(at point: CGPoint) {
    let windows = LayerWindowInfo.onScreen()
    guard let info = LayerWindowInfo.applicationWindow(at: point, in: windows),
      let running = NSRunningApplication(processIdentifier: info.ownerPID),
      let application = LayerApplication(running)
    else {
      hint("这里没有可以翻译的文字")
      return
    }
    enableTree(of: application)
    // A pane already in use answers from its last read, so a repeated press is instant.
    for session in sessions where session.application.processIdentifier == application.processIdentifier
      && session.paneFrame.contains(point)
    {
      if let outcome = session.toggleParagraph(at: point) {
        log("layer-paragraph-\(outcome) app=\(application.bundleIdentifier)")
        return
      }
    }
    Task.detached(priority: .userInitiated) {
      let found = LayerParagraphFinder.find(at: point, in: application)
      await MainActor.run { [weak self] in self?.applyFoundParagraph(found, application: application, at: point) }
    }
  }

  private func applyFoundParagraph(_ found: LayerParagraphFinder.Result, application: LayerApplication, at point: CGPoint) {
    guard case .paragraph(let block, let node, let pane, let window, let site) = found else {
      let readsText = if case .nothing(let readsText) = found { readsText } else { true }
      hint(
        readsText
          ? "这里没有可以翻译的文字"
          : "\(application.name) 里读不到文字，可以用截图翻译 \(settings().captureShortcut.displayText)")
      log("layer-paragraph-none app=\(application.bundleIdentifier)")
      return
    }
    let session = sessions.first { !$0.isFinished && $0.pane.isSameElement(as: pane) } ?? {
      let session = LayerPaneSession(application: application, window: window, pane: pane, owner: self)
      session.site = site
      sessions.append(session)
      return session
    }()
    session.pick(block, element: node)
    log("layer-paragraph-translated app=\(application.bundleIdentifier)")
  }

  // MARK: ⌥⇧D: the whole window

  /// Starts translating every window of the app, or the site, under `point`; stops when it
  /// already does (§三).
  func toggleWindow(at point: CGPoint) {
    let windows = LayerWindowInfo.onScreen()
    guard let info = LayerWindowInfo.applicationWindow(at: point, in: windows),
      let running = NSRunningApplication(processIdentifier: info.ownerPID),
      let application = LayerApplication(running)
    else {
      hint("这里没有可以翻译的窗口")
      return
    }
    enableTree(of: application)
    let bounds = info.bounds
    Task.detached(priority: .userInitiated) {
      let window = application.windows.first { window in
        guard let frame = window.frame else { return false }
        return abs(frame.minX - bounds.minX) < 2 && abs(frame.minY - bounds.minY) < 2
      }
      let site = window.flatMap(LayerSiteReader.site(of:))
      await MainActor.run { [weak self] in self?.applyWindowToggle(application: application, site: site, bounds: bounds) }
    }
  }

  private func applyWindowToggle(application: LayerApplication, site: String?, bounds: CGRect) {
    let frame = LayerScreenGeometry.appKitRect(fromTopLeft: bounds)
    let matching = windowRules.filter { $0.applies(to: application.bundleIdentifier, site: site) }
    if !matching.isEmpty {
      windowRules.removeAll { matching.contains($0) }
      saveWindowRules()
      for session in sessions where session.application.bundleIdentifier == application.bundleIdentifier
        && matching.contains(where: { $0.applies(to: application.bundleIdentifier, site: session.site) })
      {
        session.close()
      }
      sessions.removeAll(where: \.isFinished)
      hints.show("已停止翻译这个窗口", for: LayerHintPanel.briefSeconds)
      log("layer-window-off app=\(application.bundleIdentifier)")
      return
    }
    let rule = LayerWindowRule(
      bundleIdentifier: application.bundleIdentifier, applicationName: application.name,
      scope: site.map { .site($0) } ?? .application)
    windowRules.append(rule)
    saveWindowRules()
    outline.flash(around: frame)
    let stop = settings().layerShortcut.addingShift.displayText
    hints.show("翻译整个窗口 · \(rule.scope.label(applicationName: application.name)) · 再按 \(stop) 停止", for: LayerHintPanel.instructiveSeconds)
    logHint()
    log("layer-window-on app=\(application.bundleIdentifier)")
    discover()
  }

  private func saveWindowRules() {
    if persists { SettingsStore.saveLayerWindowRules(windowRules, namespace: namespace) }
  }

  private func hint(_ text: String) {
    hints.show(text, for: LayerHintPanel.briefSeconds)
    logHint()
  }

  private func logHint() {
    log(
      "layer-hint visible=\(hints.isVisible) alpha=\(hints.alphaValue) frame=\(Int(hints.frame.minX)),\(Int(hints.frame.minY)),\(Int(hints.frame.width))x\(Int(hints.frame.height))"
        + " screens=\(NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" })")
  }

  /// A failed request is said once and stays until it is pressed, which retries every pane
  /// that failed, or until a translation succeeds. The shortcuts show the panel's welcome
  /// without a model service, so that is said here only when the service is removed while a
  /// window is translated whole (§二 失败).
  private func updateFailureHint() {
    let failure = sessions.lazy.compactMap(\.failure).first
    guard failure != shownFailure else { return }
    let previous = shownFailure
    shownFailure = failure
    switch failure {
    case .notConfigured:
      hints.show("还没有模型服务", for: LayerHintPanel.briefSeconds)
    case .some:
      hints.show("翻译失败 · 点按重试", for: nil) { [weak self] in
        guard let self else { return }
        for session in sessions where session.failure != nil { session.retry() }
      }
    case nil:
      if previous != nil, previous != .notConfigured, hints.text == "翻译失败 · 点按重试" { hints.hide() }
    }
  }

  private func enableTree(of application: LayerApplication) {
    guard !enabledTrees.contains(application.processIdentifier) else { return }
    enabledTrees.insert(application.processIdentifier)
    application.enableAccessibilityTree()
  }

  // MARK: Loop

  private func step() {
    tickCount += 1
    if tickCount % 30 == 1 { discover() }
    // Nothing to follow: no window list, no pointer.
    guard !sessions.isEmpty else { return }
    if let settle = windowsSettleAt, Date() >= settle {
      windowsSettleAt = nil
      windows = LayerWindowInfo.onScreen()
    } else if tickCount % 5 == 1 {
      windows = LayerWindowInfo.onScreen()
    }
    let mouse = LayerScreenGeometry.topLeftPoint(fromAppKit: NSEvent.mouseLocation)
    for session in sessions {
      session.step(windows: windows, mouse: mouse)
    }
    for session in sessions where session.isFinished || session.isEmpty {
      session.close()
    }
    sessions.removeAll(where: \.isFinished)
    updateFailureHint()
  }

  /// When the windows of a newly active app have finished animating into place.
  private var windowsSettleAt: Date?

  /// Another app came to the front: its windows grow over the panes while they animate in,
  /// faster than the window list can follow. The translations of every other app are hidden
  /// at once and come back where they are still visible once the windows settle.
  private func frontApplicationChanged(to pid: pid_t?) {
    let settle = Date().addingTimeInterval(0.3)
    windowsSettleAt = settle
    for session in sessions where session.application.processIdentifier != pid {
      session.hideUntilWindowsSettle(settle)
    }
  }

  private func noteScroll() {
    let mouse = LayerScreenGeometry.topLeftPoint(fromAppKit: NSEvent.mouseLocation)
    for session in sessions where session.paneFrame.contains(mouse) {
      session.noteScroll()
    }
  }

  /// Finds the panes of every window translated whole (§三). Panes ⌥D already uses come
  /// first; a pane no longer found stops translating whole.
  func discover() {
    guard !discovering else { return }
    guard !windowRules.isEmpty else {
      for session in sessions where session.translatesAll { session.translatesAll = false }
      return
    }
    discovering = true
    let rules = windowRules
    let bundles = Set(rules.map(\.bundleIdentifier))
    let applications = NSWorkspace.shared.runningApplications
      .filter { $0.bundleIdentifier.map(bundles.contains) ?? false && !$0.isHidden }
      .compactMap(LayerApplication.init)
    applications.forEach(enableTree(of:))
    let inUse = sessions.map { (pid: $0.application.processIdentifier, pane: $0.pane) }
    Task.detached(priority: .utility) {
      var found: [(application: LayerApplication, window: AccessibilityLayerNode, pane: AccessibilityLayerNode, site: String?)] = []
      for application in applications {
        for window in application.windows {
          let site = LayerSiteReader.site(of: window)
          guard rules.contains(where: { $0.applies(to: application.bundleIdentifier, site: site) }),
            let windowFrame = window.frame
          else {
            continue
          }
          let preferred = inUse.filter { $0.pid == application.processIdentifier && $0.pane.isAlive }
            .map(\.pane)
            .filter { pane in pane.frame.map(windowFrame.intersects) ?? false }
          for pane in LayerPaneRule.panes(in: window, preferred: preferred) {
            found.append((application, window, pane, site))
          }
        }
      }
      let result = found
      await MainActor.run { [weak self] in self?.applyDiscovery(result) }
    }
  }

  private func applyDiscovery(
    _ discovered: [(application: LayerApplication, window: AccessibilityLayerNode, pane: AccessibilityLayerNode, site: String?)]
  ) {
    discovering = false
    // ⌥⇧D may have stopped a window while this search ran; only what is still on counts.
    let found = discovered.filter { item in
      windowRules.contains { $0.applies(to: item.application.bundleIdentifier, site: item.site) }
    }
    for session in sessions where session.translatesAll
      && !found.contains(where: { $0.pane.isSameElement(as: session.pane) })
    {
      session.translatesAll = false
    }
    for (application, window, pane, site) in found {
      if let session = sessions.first(where: { !$0.isFinished && $0.pane.isSameElement(as: pane) }) {
        if !session.translatesAll {
          session.translatesAll = true
          session.read()
        }
        continue
      }
      let session = LayerPaneSession(application: application, window: window, pane: pane, owner: self)
      session.site = site
      session.translatesAll = true
      sessions.append(session)
      session.read()
      log("layer-pane-found app=\(application.bundleIdentifier)")
    }
  }

  // MARK: Shared by sessions

  fileprivate var currentSettings: CidaSettings { settings() }
  fileprivate var translationService: any TextProcessingService { service }
  fileprivate var translations: LayerTranslationCache { cache }
  private static let logger = Logger(subsystem: "com.xuanwo.Cida", category: "translation-layer")

  /// Records a lifecycle event in the unified log and, under automation, the lifecycle log.
  /// Events carry no text from any application.
  func log(_ event: String) {
    Self.logger.notice("\(event, privacy: .public)")
    lifecycleLog?(event)
  }

  /// A paragraph ⌥D asked for is already in the user's own language.
  fileprivate func noteAlreadyMine(at frame: CGRect) {
    let language = settings().requestLanguages.my
    hint("这一段已经是\(language)")
  }
}

/// What ⌥D points at, read in the background from the app's tree.
enum LayerParagraphFinder {
  enum Result: @unchecked Sendable {
    case paragraph(
      LayerBlock, node: AccessibilityLayerNode, pane: AccessibilityLayerNode, window: AccessibilityLayerNode,
      site: String?)
    /// No paragraph there; `readsText` is false when the app shows no text at all.
    case nothing(readsText: Bool)
  }

  static func find(at point: CGPoint, in application: LayerApplication) -> Result {
    guard let hit = application.element(at: point) else { return .nothing(readsText: false) }
    guard let pane = LayerPaneRule.pane(from: hit), let paneFrame = pane.frame,
      let window = hit.window ?? pane.window
    else {
      return .nothing(readsText: LayerPaneRule.holdsText(hit.window ?? hit))
    }
    let located = LayerBlockExtractor.located(in: pane, visible: paneFrame)
    guard let index = LayerBlockExtractor.paragraphIndex(at: point, in: located.map(\.block)) else {
      return .nothing(readsText: true)
    }
    return .paragraph(
      located[index].block, node: located[index].node, pane: pane, window: window,
      site: LayerSiteReader.site(of: window))
  }
}

/// The site a window shows: the host of its web area, if it has one.
enum LayerSiteReader {
  static func site(of window: AccessibilityLayerNode) -> String? {
    var stack = [window]
    var visited = 0
    while let node = stack.popLast(), visited < 400 {
      visited += 1
      if node.role == LayerRole.webArea {
        return node.url?.host(percentEncoded: false)?.lowercased()
      }
      stack.append(contentsOf: node.children)
    }
    return nil
  }
}

extension AccessibilityLayerNode {
  /// An element of a closed window or a removed row no longer answers.
  var isAlive: Bool {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
  }

  /// A fresh read of the position, bypassing the snapshot.
  var currentFrame: CGRect? {
    AccessibilityLayerNode(element).frame
  }
}

/// A paragraph by the element it was read from and its text: an element may hold several
/// hand-broken lines, and another paragraph with the same text (a repeated alert) is not it.
struct LayerParagraphMark {
  let element: AccessibilityLayerNode
  let text: String
  /// Reads in a row that did not find it; after two it is gone (§二 自然消失).
  var misses = 0

  func matches(_ block: LayerBlock, node: AccessibilityLayerNode) -> Bool {
    block.text == text && node.isSameElement(as: element)
  }
}

/// One pane in one window: every paragraph of it while its window is translated whole (§三),
/// plus the paragraphs ⌥D asked for, minus those ⌥D turned back (§二).
@MainActor
final class LayerPaneSession {
  let application: LayerApplication
  let window: AccessibilityLayerNode
  let pane: AccessibilityLayerNode
  var site: String?
  /// The window is translated whole.
  var translatesAll = false {
    didSet {
      guard translatesAll != oldValue else { return }
      if !translatesAll { restored = [] }
      needsRead = true
    }
  }
  /// Paragraphs ⌥D asked for; they are translated whatever the whole-window rules say.
  private var picked: [LayerParagraphMark] = []
  /// Paragraphs of a window translated whole that ⌥D turned back to their original.
  private var restored: [LayerParagraphMark] = []
  /// Every paragraph of the last read, to find the one under the pointer without reading again.
  private var readBlocks: [LayerBlock] = []
  private var readNodes: [AccessibilityLayerNode] = []
  private unowned let owner: TranslationLayerController

  private let overlay = LayerOverlayPanel()
  private(set) var paneFrame: CGRect = .zero
  /// The window's frame as its accessibility tree reports it, read with the pane's.
  private var windowFrame: CGRect?
  private var windowNumber: CGWindowID?
  private(set) var isOnScreen = false
  private var blocks: [LayerBlock] = []
  private var anchors: [AccessibilityLayerNode] = []
  private var anchorFrames: [CGRect?] = []
  private var lastMotion: Date?
  private var lastScroll: Date?
  private var windowsSettle: Date?
  private var isReading = false
  private var isProbing = false
  private var needsRead = true
  private var lastRead = Date.distantPast
  private var translating: Task<Void, Never>?
  private(set) var failure: LayerTranslationError?
  private var styles: [String: LayerTextStyle] = [:]
  private var peekCandidate: (index: Int, since: Date)?
  /// The paragraph under the pointer when translations first appeared: the pointer is there
  /// because the user just clicked it, so it waits until the pointer has left once.
  private var peekSuppressed: Int?
  private var hasShownTranslations = false
  private(set) var isFinished = false
  /// Follows the content frame by frame while the screen can be read (§五).
  private var motion: LayerMotionStream?
  private var lastCoveringCount = -1

  init(
    application: LayerApplication, window: AccessibilityLayerNode, pane: AccessibilityLayerNode,
    owner: TranslationLayerController
  ) {
    self.application = application
    self.window = window
    self.pane = pane
    self.owner = owner
  }

  /// Tries the paragraphs whose request failed again (§二 失败).
  func retry() {
    failure = nil
    translatePending()
  }

  /// Ends the session for good: reads and requests still on their way find it finished and
  /// never show the overlay again, or it would float over every app with no one to hide it.
  func close() {
    translating?.cancel()
    motion?.stop()
    motion = nil
    overlay.orderOut(nil)
    isFinished = true
  }

  /// Nothing left to translate: neither the whole window nor a paragraph ⌥D asked for.
  var isEmpty: Bool { !translatesAll && picked.isEmpty }

  // MARK: ⌥D

  /// Translates this paragraph from now on (§二).
  func pick(_ block: LayerBlock, element: AccessibilityLayerNode) {
    restored.removeAll { $0.matches(block, node: element) }
    if !picked.contains(where: { $0.matches(block, node: element) }) {
      picked.append(LayerParagraphMark(element: element, text: block.text))
    }
    needsRead = true
    read()
  }

  /// ⌥D on a paragraph of this pane from the last read: turns a translation back into its
  /// original, or an original into its translation. Nil when no paragraph is there.
  func toggleParagraph(at point: CGPoint) -> String? {
    guard let index = LayerBlockExtractor.paragraphIndex(at: point, in: readBlocks) else { return nil }
    let block = readBlocks[index]
    let node = readNodes[index]
    let isShown = blocks.contains { $0 == block }
    if isShown {
      picked.removeAll { $0.matches(block, node: node) }
      if translatesAll { restored.append(LayerParagraphMark(element: node, text: block.text)) }
      needsRead = true
      read()
      return "restored"
    }
    pick(block, element: node)
    return "translated"
  }

  /// The content moved. Followed frame by frame when the screen can be read; hidden until it
  /// settles otherwise (§五).
  /// Hidden while another app's windows move in front (see `frontApplicationChanged`).
  func hideUntilWindowsSettle(_ date: Date) {
    if windowsSettle == nil, overlay.alphaValue > 0 { owner.log("layer-hidden-for-app-switch") }
    windowsSettle = date
    overlay.alphaValue = 0
  }

  /// The user scrolled over the pane.
  func noteScroll() {
    lastScroll = Date()
    noteMotion()
  }

  func noteMotion() {
    lastMotion = Date()
    needsRead = true
    if motion == nil { overlay.alphaValue = 0 }
  }

  /// The screen can be read: colours come from it and motion is followed (§三, §五).
  static var readsScreen: Bool { CGPreflightScreenCaptureAccess() }

  private func followMotion() {
    guard motion == nil, Self.readsScreen, isOnScreen, let windowNumber,
      !overlay.overlayView.drawings.isEmpty, let windowFrame = window.frame
    else {
      return
    }
    let stream = LayerMotionStream()
    stream.onLost = { [weak self] reason in self?.owner.log("layer-motion-unexplained \(reason)") }
    stream.onMotion = { [weak self] offset in
      guard let self else { return }
      needsRead = true
      if let offset {
        lastMotion = Date()
        overlay.overlayView.setOffset(offset)
      } else if let lastScroll, Date().timeIntervalSince(lastScroll) < 0.5 {
        // Scrolled too fast to follow: hidden until it settles.
        owner.log("layer-motion-lost")
        lastMotion = Date()
        overlay.alphaValue = 0
      }
      // Otherwise pixels changed in place (a hover toolbar, an animation, a new message): the
      // translations stay and the next read of the tree puts them where the text is.
    }
    motion = stream
    owner.log("layer-motion-followed")
    let pane = paneFrame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
    Task { await stream.start(windowNumber: windowNumber, pane: pane) }
  }

  func step(windows: [LayerWindowInfo], mouse: CGPoint) {
    guard !isFinished else { return }
    if let settle = windowsSettle {
      guard Date() >= settle else { return }
      windowsSettle = nil
      placeOverWindow(windows)
      redraw()
      return
    }
    placeOverWindow(windows)
    probeMotion()
    let settled = lastMotion.map { Date().timeIntervalSince($0) > 0.15 } ?? true
    if settled, !isReading, needsRead || Date().timeIntervalSince(lastRead) > 1.0 {
      read()
    }
    updatePeek(mouse: mouse, settled: settled)
  }

  // MARK: Where the pane is

  private func placeOverWindow(_ windows: [LayerWindowInfo]) {
    let ownerPID = application.processIdentifier
    if windowNumber == nil || !windows.contains(where: { $0.number == windowNumber }) {
      let frame = window.frame ?? .zero
      windowFrame = frame
      windowNumber = windows.first {
        $0.ownerPID == ownerPID && LayerWindowInfo.isInPlace($0, windowFrame: frame)
      }?.number
    }
    // Stage Manager keeps a window in the list while it shows it as a thumbnail in the strip,
    // and a window is also elsewhere while it minimizes or Mission Control shows it: its
    // paragraphs are not where the tree says, so nothing is drawn.
    guard let windowNumber, let info = windows.first(where: { $0.number == windowNumber }),
      windowFrame.map({ LayerWindowInfo.isInPlace(info, windowFrame: $0) }) ?? true
    else {
      isOnScreen = false
      overlay.orderOut(nil)
      motion?.stop()
      motion = nil
      return
    }
    isOnScreen = true
    let occluders = LayerWindowInfo.occluders(of: windowNumber, in: windows)
    let covered = occluders.map { $0.bounds.offsetBy(dx: -paneFrame.minX, dy: -paneFrame.minY) }
    overlay.overlayView.setOcclusion(covered)
    let coveringPane = occluders.filter { $0.bounds.intersects(paneFrame) }
    if coveringPane.count != lastCoveringCount {
      lastCoveringCount = coveringPane.count
      owner.log(
        "layer-occluded count=\(coveringPane.count) by=\(coveringPane.map { "\($0.ownerName) \(Int($0.bounds.width))x\(Int($0.bounds.height))" })")
    }
    if !overlay.isVisible, !overlay.overlayView.drawings.isEmpty { overlay.orderFront(nil) }
    followMotion()
  }

  /// Reads a few paragraph positions and the pane's frame; any change means the content or
  /// the window moved (§五).
  private func probeMotion() {
    guard !isProbing, !anchors.isEmpty || paneFrame != .zero else { return }
    isProbing = true
    let anchors = anchors
    let pane = pane
    let window = window
    Task.detached(priority: .userInitiated) {
      let frames = anchors.map(\.currentFrame)
      let paneFrame = pane.currentFrame
      let windowFrame = window.currentFrame
      await MainActor.run { [weak self] in
        guard let self, !isFinished else { return }
        isProbing = false
        self.windowFrame = windowFrame
        guard let paneFrame else {
          close()
          return
        }
        if paneFrame != self.paneFrame {
          // The window moved or resized: the overlay goes with it.
          noteMotion()
          overlay.alphaValue = 0
          place(paneFrame)
        } else if frames.count == anchorFrames.count, frames != anchorFrames {
          noteMotion()
        }
        anchorFrames = frames
      }
    }
  }

  private func place(_ frame: CGRect) {
    paneFrame = frame
    overlay.setFrame(LayerScreenGeometry.appKitRect(fromTopLeft: frame), display: false)
  }

  // MARK: Paragraphs

  func read() {
    guard !isReading else { return }
    isReading = true
    needsRead = false
    let pane = pane
    let window = window
    let wantsColors = Self.readsScreen
    let translatesAll = translatesAll
    Task.detached(priority: .userInitiated) {
      guard let frame = pane.currentFrame else {
        await MainActor.run { [weak self] in self?.close() }
        return
      }
      let located = LayerBlockExtractor.located(in: pane, visible: frame)
      // Whole-window translation leaves navigation and one-word labels alone (§四).
      let automatic = translatesAll ? LayerBlockExtractor.located(in: pane, visible: frame, automatic: true) : []
      var image: CGImage?
      var windowFrame: CGRect?
      if wantsColors, let current = window.currentFrame {
        windowFrame = current
        image = await LayerWindowCapture.image(ofWindowAt: current, pid: pane.processIdentifier)
      }
      let blocks = located.map(\.block)
      let nodes = located.map(\.node)
      let automaticIndices = Set(located.indices.filter { index in
        automatic.contains { $0.block == located[index].block && $0.node.isSameElement(as: located[index].node) }
      })
      let capturedImage = image
      let capturedWindowFrame = windowFrame
      await MainActor.run { [weak self] in
        self?.applyRead(
          frame: frame, blocks: blocks, nodes: nodes, automatic: automaticIndices, image: capturedImage,
          windowFrame: capturedWindowFrame)
      }
    }
  }

  private func applyRead(
    frame: CGRect, blocks newBlocks: [LayerBlock], nodes: [AccessibilityLayerNode], automatic: Set<Int>,
    image: CGImage?, windowFrame: CGRect?
  ) {
    isReading = false
    guard !isFinished else { return }
    lastRead = Date()
    place(frame)
    readBlocks = newBlocks
    readNodes = nodes
    // What shows: the whole window's paragraphs but those turned back, and those ⌥D asked for.
    for index in picked.indices {
      let found = newBlocks.indices.contains { picked[index].matches(newBlocks[$0], node: nodes[$0]) }
      picked[index].misses = found ? 0 : picked[index].misses + 1
    }
    picked.removeAll { $0.misses >= 2 }
    let shown = newBlocks.indices.filter { index in
      let block = newBlocks[index], node = nodes[index]
      if picked.contains(where: { $0.matches(block, node: node) }) { return true }
      return automatic.contains(index) && !restored.contains(where: { $0.matches(block, node: node) })
    }
    // ⌥D on a paragraph already in the user's own language has nothing to show.
    let filter = LayerLanguageFilter(myLanguage: owner.currentSettings.requestLanguages.my)
    for index in shown where !filter.needsTranslation(newBlocks[index].text) {
      let block = newBlocks[index], node = nodes[index]
      guard picked.contains(where: { $0.matches(block, node: node) }) else { continue }
      picked.removeAll { $0.matches(block, node: node) }
      owner.noteAlreadyMine(at: block.frame)
    }
    blocks = shown.map { newBlocks[$0] }
    if let windowFrame = window.frame {
      motion?.resetBaseline(pane: frame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY))
    }
    // Motion is noticed from any paragraph of the pane, shown or not.
    let picks = [0, nodes.count / 2, nodes.count - 1].filter { $0 >= 0 && $0 < nodes.count }
    anchors = Array(Set(picks)).sorted().map { nodes[$0] }
    anchorFrames = anchors.map(\.frame)
    if let image, let windowFrame {
      let scale = CGFloat(image.width) / max(windowFrame.width, 1)
      for block in blocks where styles[block.maskedText] == nil {
        let pixels = CGRect(
          x: (block.frame.minX - windowFrame.minX) * scale, y: (block.frame.minY - windowFrame.minY) * scale,
          width: block.frame.width * scale, height: block.frame.height * scale)
        if let style = LayerColorSampler.style(in: image, pixelRect: pixels) { styles[block.maskedText] = style }
      }
    }
    redraw()
    translatePending()
  }

  private var pendingBlocks: [LayerBlock] {
    let filter = LayerLanguageFilter(myLanguage: owner.currentSettings.requestLanguages.my)
    return blocks.filter {
      owner.translations[$0.maskedText] == nil && filter.needsTranslation($0.text)
    }
  }

  private func translatePending() {
    guard translating == nil, failure == nil else { return }
    let texts = Array(Set(pendingBlocks.map(\.maskedText)))
    guard !texts.isEmpty else { return }
    let settings = owner.currentSettings
    let service = owner.translationService
    translating = Task { [weak self] in
      for batch in LayerTranslationRequest.batches(of: texts) {
        do {
          let translated = try await LayerTranslationRequest.translate(batch, settings: settings, service: service)
          guard let self, !Task.isCancelled else { return }
          for (source, translation) in zip(batch, translated) {
            owner.translations.store(translation, for: source)
          }
          redraw()
          owner.log("layer-translated count=\(batch.count)")
        } catch is CancellationError {
          return
        } catch {
          // A cancelled request may fail with its transport's own error.
          guard let self, !Task.isCancelled else { return }
          failure = error as? LayerTranslationError ?? .mismatchedReply
          owner.log("layer-translation-failed")
          break
        }
      }
      guard let self, !Task.isCancelled else { return }
      translating = nil
      redraw()
      // Paragraphs that appeared while this batch was out.
      if failure == nil, !pendingBlocks.isEmpty { translatePending() }
    }
  }

  private func redraw() {
    guard !isFinished else { return }
    let scale = overlay.backingScaleFactor
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let paper = LayerTextStyle.paper(darkAppearance: dark)
    let drawings: [LayerDrawing] = blocks.compactMap { block in
      guard let translation = owner.translations[block.maskedText] else { return nil }
      let text = block.restoringVerbatim(in: translation)
      guard text != block.text else { return nil }
      return LayerDrawing(
        frame: block.frame.offsetBy(dx: -paneFrame.minX, dy: -paneFrame.minY),
        text: text, lineHeight: block.lineHeight, style: styles[block.maskedText] ?? paper)
    }
    overlay.overlayView.show(drawings, scale: scale)
    // Every paragraph waiting for its translation breathes (§二 等待, §五 等待).
    let waiting = failure == nil ? pendingBlocks : []
    overlay.overlayView.setPending(waiting.map { $0.frame.offsetBy(dx: -paneFrame.minX, dy: -paneFrame.minY) })
    if isOnScreen, !waiting.isEmpty { overlay.orderFront(nil) }
    let settled = lastMotion.map { Date().timeIntervalSince($0) > 0.15 } ?? true
    if settled {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = CidaMotion.resolvedDuration(CidaMotion.heightSeconds, in: overlay)
        overlay.animator().alphaValue = 1
      }
    }
    if isOnScreen, !drawings.isEmpty { overlay.orderFront(nil) }
    owner.log(
      "layer-drawn drawings=\(drawings.count) painted=\(overlay.overlayView.paintedCount) blocks=\(blocks.count) onScreen=\(isOnScreen)"
        + " visible=\(overlay.isVisible) alpha=\(overlay.alphaValue) settled=\(settled)"
        + " frame=\(Int(overlay.frame.minX)),\(Int(overlay.frame.minY)),\(Int(overlay.frame.width))x\(Int(overlay.frame.height))"
        + " paper=\(drawings.first?.style.isPaper ?? true)")
  }

  // MARK: Showing the original

  /// The pointer rests 300 ms on a paragraph: it shows the original until the pointer leaves
  /// (§四).
  private func updatePeek(mouse: CGPoint, settled: Bool) {
    let local = CGPoint(x: mouse.x - paneFrame.minX, y: mouse.y - paneFrame.minY)
    let hovered = paneFrame.contains(mouse) ? overlay.overlayView.index(at: local) : nil
    if !hasShownTranslations, !overlay.overlayView.drawings.isEmpty {
      hasShownTranslations = true
      peekSuppressed = hovered
    }
    if hovered != peekSuppressed { peekSuppressed = nil }
    guard settled, let index = hovered, index != peekSuppressed else {
      peekCandidate = nil
      overlay.overlayView.setPeek(nil, animated: true)
      return
    }
    if peekCandidate?.index != index {
      peekCandidate = (index, Date())
      overlay.overlayView.setPeek(nil, animated: true)
    } else if let candidate = peekCandidate, Date().timeIntervalSince(candidate.since) >= 0.3 {
      overlay.overlayView.setPeek(index, animated: true)
    }
  }
}

extension AccessibilityLayerNode {
  var processIdentifier: pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
  }
}

/// One capture of a window for sampling colours; only with Screen Recording granted.
enum LayerWindowCapture {
  static func image(ofWindowAt frame: CGRect, pid: pid_t) async -> CGImage? {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
      let window = content.windows.first(where: {
        $0.owningApplication?.processID == pid && abs($0.frame.minX - frame.minX) < 2
          && abs($0.frame.minY - frame.minY) < 2 && abs($0.frame.width - frame.width) < 2
      })
    else {
      return nil
    }
    let configuration = SCStreamConfiguration()
    let scale = NSScreen.screens.first { $0.frame.intersects(LayerScreenGeometry.appKitRect(fromTopLeft: frame)) }?
      .backingScaleFactor ?? 2
    configuration.width = Int(frame.width * scale)
    configuration.height = Int(frame.height * scale)
    configuration.showsCursor = false
    return try? await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
  }
}

import AppKit
import ScreenCaptureKit

/// Runs the translation layer (`Design/spec/translation-layer.md`): finds the chosen panes in
/// running applications, reads their paragraphs, translates what is not in the user's own
/// language, and keeps the translations over the originals while the pane scrolls, moves or
/// gets covered. It also shows single paragraphs translated once from the configuration.
@MainActor
final class TranslationLayerController {
  private let settings: () -> CidaSettings
  private let service: any TextProcessingService
  private let namespace: String
  private let persists: Bool
  private(set) var selections: [LayerSelection]
  private var sessions: [String: LayerPaneSession] = [:]
  private var oneOff: LayerPaneSession?
  private let cache = LayerTranslationCache()
  private var tick: Timer?
  private var tickCount = 0
  private var windows: [LayerWindowInfo] = []
  private var monitors: [Any] = []
  private var discovering = false
  private var enabledTrees: Set<pid_t> = []
  var lifecycleLog: ((String) -> Void)?

  init(
    settings: @escaping () -> CidaSettings, service: any TextProcessingService, namespace: String,
    persists: Bool
  ) {
    self.settings = settings
    self.service = service
    self.namespace = namespace
    self.persists = persists
    selections = persists ? SettingsStore.loadLayerSelections(namespace: namespace) : []
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
    monitors.append(
      NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
        // Escape dismisses a paragraph translated once; the key still reaches the app.
        guard event.keyCode == 53 else { return }
        MainActor.assumeIsolated { self?.dismissOneOff() }
      } as Any)
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.discover() }
    }
  }

  // MARK: Selections

  func setSelections(_ newSelections: [LayerSelection]) {
    selections = newSelections
    if persists { SettingsStore.saveLayerSelections(newSelections, namespace: namespace) }
    for (key, session) in sessions where !newSelections.contains(where: { $0.id == session.selectionID }) {
      session.close()
      sessions[key] = nil
    }
    discover()
  }

  /// The chosen panes on screen now, for the configuration to lift (top-left coordinates).
  var visibleSelectedPanes: [(selectionID: UUID, frame: CGRect)] {
    sessions.values.compactMap { session in
      guard let id = session.selectionID, session.isOnScreen else { return nil }
      return (id, session.paneFrame)
    }
  }

  // MARK: One paragraph, once

  /// Translates one paragraph in place until it leaves the screen, its text changes or the
  /// user presses Escape (the configuration's plain click).
  func translateOnce(
    paragraph: LayerBlock, pane: AccessibilityLayerNode, window: AccessibilityLayerNode,
    application: LayerApplication
  ) {
    dismissOneOff()
    let session = LayerPaneSession(
      application: application, window: window, pane: pane, selectionID: nil,
      paragraph: paragraph.text, owner: self)
    oneOff = session
    session.read()
  }

  func dismissOneOff() {
    oneOff?.close()
    oneOff = nil
  }

  // MARK: Loop

  private func step() {
    tickCount += 1
    if tickCount % 5 == 1 { windows = LayerWindowInfo.onScreen() }
    if tickCount % 30 == 1 { discover() }
    let mouse = LayerScreenGeometry.topLeftPoint(fromAppKit: NSEvent.mouseLocation)
    for session in allSessions {
      session.step(windows: windows, mouse: mouse)
    }
    if let oneOff, oneOff.isFinished {
      oneOff.close()
      self.oneOff = nil
    }
  }

  private var allSessions: [LayerPaneSession] {
    Array(sessions.values) + (oneOff.map { [$0] } ?? [])
  }

  private func noteScroll() {
    let mouse = LayerScreenGeometry.topLeftPoint(fromAppKit: NSEvent.mouseLocation)
    for session in allSessions where session.paneFrame.contains(mouse) {
      session.noteMotion()
    }
  }

  /// Finds the chosen panes in the windows of running applications. Panes already found are
  /// kept while their element is alive and their window shows the same site.
  func discover() {
    guard !discovering, !selections.isEmpty else { return }
    discovering = true
    let selections = selections
    let bundles = Set(selections.map(\.bundleIdentifier))
    let applications = NSWorkspace.shared.runningApplications
      .filter { $0.bundleIdentifier.map(bundles.contains) ?? false && !$0.isHidden }
      .compactMap(LayerApplication.init)
    for application in applications where !enabledTrees.contains(application.processIdentifier) {
      enabledTrees.insert(application.processIdentifier)
      application.enableAccessibilityTree()
    }
    let existing = sessions.mapValues { ($0.pane, $0.site) }
    Task.detached(priority: .userInitiated) {
      var found: [(key: String, selection: LayerSelection, application: LayerApplication,
        window: AccessibilityLayerNode, pane: AccessibilityLayerNode, site: String?)] = []
      for application in applications {
        for window in application.windows {
          let site = LayerSiteReader.site(of: window)
          for selection in selections where selection.applies(to: application.bundleIdentifier, site: site) {
            let key = "\(selection.id)-\(CFHash(window.element))"
            if let (pane, knownSite) = existing[key], knownSite == site, pane.isAlive {
              found.append((key, selection, application, window, pane, site))
            } else if let pane = selection.locator.resolve(in: window) {
              found.append((key, selection, application, window, pane, site))
            }
          }
        }
      }
      let result = found
      await MainActor.run { [weak self] in
        self?.applyDiscovery(result.map { ($0.key, $0.selection, $0.application, $0.window, $0.pane, $0.site) })
      }
    }
  }

  private func applyDiscovery(
    _ found: [(String, LayerSelection, LayerApplication, AccessibilityLayerNode, AccessibilityLayerNode, String?)]
  ) {
    discovering = false
    let keys = Set(found.map(\.0))
    for (key, session) in sessions where !keys.contains(key) {
      session.close()
      sessions[key] = nil
    }
    for (key, selection, application, window, pane, site) in found {
      if let session = sessions[key], session.pane.isSameElement(as: pane) { continue }
      sessions[key]?.close()
      let session = LayerPaneSession(
        application: application, window: window, pane: pane, selectionID: selection.id,
        paragraph: nil, owner: self)
      session.site = site
      sessions[key] = session
      session.read()
      lifecycleLog?("layer-pane-found app=\(application.bundleIdentifier)")
    }
  }

  // MARK: Shared by sessions

  fileprivate var currentSettings: CidaSettings { settings() }
  fileprivate var translationService: any TextProcessingService { service }
  fileprivate var translations: LayerTranslationCache { cache }
  fileprivate func log(_ event: String) { lifecycleLog?(event) }
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

/// One pane in one window, or one paragraph translated once.
@MainActor
final class LayerPaneSession {
  let application: LayerApplication
  let window: AccessibilityLayerNode
  let pane: AccessibilityLayerNode
  let selectionID: UUID?
  /// Set for a paragraph translated once: only this text is drawn.
  let paragraph: String?
  var site: String?
  private unowned let owner: TranslationLayerController

  private let overlay = LayerOverlayPanel()
  private let status = LayerStatusPanel()
  private(set) var paneFrame: CGRect = .zero
  private var windowNumber: CGWindowID?
  private(set) var isOnScreen = false
  private var blocks: [LayerBlock] = []
  private var anchors: [AccessibilityLayerNode] = []
  private var anchorFrames: [CGRect?] = []
  private var lastMotion: Date?
  private var isReading = false
  private var isProbing = false
  private var needsRead = true
  private var lastRead = Date.distantPast
  private var translating: Task<Void, Never>?
  private var failure: LayerTranslationError?
  private var styles: [String: LayerTextStyle] = [:]
  private var peekCandidate: (index: Int, since: Date)?
  /// The paragraph under the pointer when translations first appeared: the pointer is there
  /// because the user just clicked it, so it waits until the pointer has left once.
  private var peekSuppressed: Int?
  private var hasShownTranslations = false
  private(set) var isFinished = false
  private var readsWithoutParagraph = 0
  /// Follows the content frame by frame while the screen can be read (§五).
  private var motion: LayerMotionStream?
  private var lastCoveringCount = -1

  init(
    application: LayerApplication, window: AccessibilityLayerNode, pane: AccessibilityLayerNode,
    selectionID: UUID?, paragraph: String?, owner: TranslationLayerController
  ) {
    self.application = application
    self.window = window
    self.pane = pane
    self.selectionID = selectionID
    self.paragraph = paragraph
    self.owner = owner
    status.onRetry = { [weak self] in
      self?.failure = nil
      self?.translatePending()
    }
  }

  func close() {
    translating?.cancel()
    motion?.stop()
    motion = nil
    overlay.orderOut(nil)
    status.orderOut(nil)
    isFinished = true
  }

  /// The content moved. Followed frame by frame when the screen can be read; hidden until it
  /// settles otherwise (§五).
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
    stream.onMotion = { [weak self] offset in
      guard let self else { return }
      if offset == nil { owner.log("layer-motion-lost") }
      lastMotion = Date()
      needsRead = true
      if let offset {
        overlay.overlayView.setOffset(offset)
      } else {
        // Replaced or too fast to follow: hide until it settles.
        overlay.alphaValue = 0
      }
    }
    motion = stream
    owner.log("layer-motion-followed")
    let pane = paneFrame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
    Task { await stream.start(windowNumber: windowNumber, pane: pane) }
  }

  func step(windows: [LayerWindowInfo], mouse: CGPoint) {
    guard !isFinished else { return }
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
      let windowFrame = window.frame ?? .zero
      windowNumber = windows.first {
        $0.ownerPID == ownerPID && abs($0.bounds.minX - windowFrame.minX) < 2
          && abs($0.bounds.minY - windowFrame.minY) < 2
          && abs($0.bounds.width - windowFrame.width) < 2
      }?.number
    }
    guard let windowNumber, windows.contains(where: { $0.number == windowNumber }) else {
      isOnScreen = false
      overlay.orderOut(nil)
      status.orderOut(nil)
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
    Task.detached(priority: .userInitiated) {
      let frames = anchors.map(\.currentFrame)
      let paneFrame = pane.currentFrame
      await MainActor.run { [weak self] in
        guard let self else { return }
        isProbing = false
        guard let paneFrame else {
          isFinished = true
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
    Task.detached(priority: .userInitiated) {
      guard let frame = pane.currentFrame else {
        await MainActor.run { [weak self] in self?.isFinished = true }
        return
      }
      let located = LayerBlockExtractor.located(in: pane, visible: frame)
      var image: CGImage?
      var windowFrame: CGRect?
      if wantsColors, let current = window.currentFrame {
        windowFrame = current
        image = await LayerWindowCapture.image(ofWindowAt: current, pid: pane.processIdentifier)
      }
      let blocks = located.map(\.block)
      let nodes = located.map(\.node)
      let capturedImage = image
      let capturedWindowFrame = windowFrame
      await MainActor.run { [weak self] in
        self?.applyRead(
          frame: frame, blocks: blocks, nodes: nodes, image: capturedImage,
          windowFrame: capturedWindowFrame)
      }
    }
  }

  private func applyRead(
    frame: CGRect, blocks newBlocks: [LayerBlock], nodes: [AccessibilityLayerNode], image: CGImage?,
    windowFrame: CGRect?
  ) {
    isReading = false
    lastRead = Date()
    place(frame)
    var blocks = newBlocks
    var nodes = nodes
    if let paragraph {
      let keep = blocks.indices.filter { blocks[$0].text == paragraph }
      blocks = keep.map { blocks[$0] }
      nodes = keep.map { nodes[$0] }
      readsWithoutParagraph = blocks.isEmpty ? readsWithoutParagraph + 1 : 0
      // Gone from the screen, or its text changed: the one-off translation ends.
      if readsWithoutParagraph >= 2 { isFinished = true }
    }
    self.blocks = blocks
    if let windowFrame = window.frame {
      motion?.resetBaseline(pane: frame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY))
    }
    let picks = [0, blocks.count / 2, blocks.count - 1].filter { $0 >= 0 && $0 < nodes.count }
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
    guard translating == nil, failure == nil else {
      updateStatus()
      return
    }
    let texts = Array(Set(pendingBlocks.map(\.maskedText)))
    guard !texts.isEmpty else {
      updateStatus()
      return
    }
    let settings = owner.currentSettings
    let service = owner.translationService
    updateStatus()
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
          guard let self else { return }
          failure = error as? LayerTranslationError ?? .mismatchedReply
          owner.log("layer-translation-failed")
          break
        }
      }
      guard let self else { return }
      translating = nil
      updateStatus()
      // Paragraphs that appeared while this batch was out.
      if failure == nil, !pendingBlocks.isEmpty { translatePending() }
    }
  }

  private func redraw() {
    let scale = overlay.backingScaleFactor
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let paper = LayerTextStyle.paper(darkAppearance: dark)
    let drawings: [LayerDrawing] = blocks.compactMap { block in
      guard let translation = owner.translations[block.maskedText] else { return nil }
      let text = block.restoringLinks(in: translation)
      guard text != block.text else { return nil }
      return LayerDrawing(
        frame: block.frame.offsetBy(dx: -paneFrame.minX, dy: -paneFrame.minY),
        text: text, lineHeight: block.lineHeight, style: styles[block.maskedText] ?? paper)
    }
    overlay.overlayView.show(drawings, scale: scale)
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
    updateStatus()
  }

  private func updateStatus() {
    guard isOnScreen else {
      status.orderOut(nil)
      return
    }
    let pane = LayerScreenGeometry.appKitRect(fromTopLeft: paneFrame)
    if let failure {
      status.show(
        text: failure == .notConfigured ? "还没有模型服务" : "翻译失败 · 点按重试",
        retryable: failure != .notConfigured, in: pane)
    } else if translating != nil {
      let count = Set(pendingBlocks.map(\.maskedText)).count
      if count > 0 { status.show(text: "翻译中 · \(count) 条", retryable: false, in: pane) }
    } else {
      status.orderOut(nil)
    }
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

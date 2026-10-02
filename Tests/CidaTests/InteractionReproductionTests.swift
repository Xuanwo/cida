import AppKit
import Carbon.HIToolbox
import QuartzCore
import SwiftUI
import XCTest

@testable import Cida

@MainActor
final class InteractionReproductionTests: XCTestCase {
  static var clickEventNumber = 0
  var retainedTestWindows: [NSWindow] = []
  var retainedPanelControllers: [PanelController] = []

  /// These tests assert on the motion a user sees, so they run with Reduce Motion off whatever
  /// the host's setting is.
  override func setUp() async throws {
    try await super.setUp()
    CidaMotion.reducesMotionOverride = false
  }

  override func tearDown() async throws {
    CidaMotion.reducesMotionOverride = nil
    CATransaction.flush()
    let retainedContentViews = retainedTestWindows.compactMap(\.contentView)
    for controller in retainedPanelControllers {
      controller.invalidate()
    }
    for window in retainedTestWindows {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    CATransaction.flush()
    retainedTestWindows.removeAll(keepingCapacity: false)
    retainedPanelControllers.removeAll(keepingCapacity: false)
    withExtendedLifetime(retainedContentViews) {}
    try await Task.sleep(for: .milliseconds(10))
    try await super.tearDown()
  }

  // MARK: - Panel

  /// `Design/spec/panel.md` §一: a borderless floating panel that takes the
  /// keyboard without activating the app.
  func testPanelIsANonActivatingBorderlessFloatingKeyPanel() {
    let panel = CidaPanel(width: CidaDesign.Panel.width)
    retainedTestWindows.append(panel)

    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(panel.styleMask.contains(.borderless))
    XCTAssertFalse(panel.styleMask.contains(.titled))
    XCTAssertFalse(panel.styleMask.contains(.resizable))
    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertEqual(panel.level, .floating)
    XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
    XCTAssertFalse(panel.hidesOnDeactivate)
    XCTAssertFalse(panel.isMovableByWindowBackground)
    XCTAssertEqual(panel.frame.width, 800)
    XCTAssertFalse(NSApp.isActive)
  }

  func testPanelHeightFollowsItsContentFromAFixedTopEdge() async throws {
    let model = AppModel(inputText: "", service: ImmediateStreamingService())
    let controller = makeHiddenPanel(model: model)
    let panel = controller.panel

    try await waitUntil(timeout: .seconds(1)) {
      controller.contentView?.layoutSubtreeIfNeeded()
      return abs(panel.frame.height - (27 + 36 + 50)) <= 1
    }
    let emptyHeight = panel.frame.height
    let topEdge = panel.frame.maxY
    XCTAssertEqual(emptyHeight, 113, accuracy: 1, "input line + pane insets + control bar")

    model.inputText = "Grow the panel with a result"
    XCTAssertTrue(model.submit())
    try await waitUntil(timeout: .seconds(2)) {
      controller.contentView?.layoutSubtreeIfNeeded()
      return model.result?.phase == .completed && panel.frame.height > emptyHeight + 40
    }

    XCTAssertEqual(panel.frame.maxY, topEdge, accuracy: 0.5, "the panel grows downward only")
    XCTAssertEqual(panel.frame.width, 800)
    XCTAssertLessThanOrEqual(panel.frame.height, controller.heightBudget.panelMaxHeight)
    assertTestProcessIsNotFrontmost()
  }

  /// A selection or capture imported while the panel is hidden must not make the
  /// panel appear at its previous, taller height and shrink from there.
  func testPanelAppearsAtTheHeightOfContentImportedWhileHidden() async throws {
    let model = AppModel(
      inputText: ResultRecord.designLongInput,
      service: DelayedStreamingService(chunks: ["译文"], delay: .seconds(2))
    )
    model.setResultForTesting(ResultRecord.designLong())
    let controller = makeHiddenPanel(model: model)
    let panel = controller.panel
    panel.orderBack(nil)
    let budget = controller.heightBudget.panelMaxHeight
    try await waitUntil(timeout: .seconds(2)) {
      panel.frame.height > budget - CidaDesign.Typography.resultLineHeight
    }
    let previousHeight = panel.frame.height

    panel.orderOut(nil)
    model.importCapturedText("Hello world")
    await controller.layOutHiddenContent()
    let importedHeight = panel.frame.height
    XCTAssertLessThan(importedHeight, previousHeight - 200, "The short import fits a short panel")

    panel.orderBack(nil)
    var heights: [CGFloat] = []
    let appeared = Date()
    while Date().timeIntervalSince(appeared) < 0.4 {
      try await Task.sleep(for: .milliseconds(8))
      heights.append(panel.frame.height)
    }
    XCTAssertEqual(
      heights.filter { abs($0 - importedHeight) > 0.5 }, [],
      "The panel appears at the imported content's height and stays there")
    assertTestProcessIsNotFrontmost()
  }

  func testPanelNeverExceedsItsHeightBudgetAndScrollsTheResultInstead() async throws {
    let model = AppModel(inputText: ResultRecord.designLongInput)
    model.setResultForTesting(ResultRecord.designLong())
    let controller = makeHiddenPanel(model: model)
    let panel = controller.panel

    // At its cap the result pane shows whole lines, so the panel stops within one line of
    // its budget.
    let lineHeight = CidaDesign.Typography.resultLineHeight
    let budget = controller.heightBudget.panelMaxHeight
    try await waitUntil(timeout: .seconds(2)) {
      controller.contentView?.layoutSubtreeIfNeeded()
      return panel.frame.height > budget - lineHeight
    }
    let contentView = try XCTUnwrap(controller.contentView)
    let resultScrollView = try XCTUnwrap(firstResultScrollView(in: contentView))
    let container = resultScrollView.container
    try await waitUntil(timeout: .seconds(2)) {
      container.naturalTextHeight > resultScrollView.contentView.bounds.height
    }

    XCTAssertLessThanOrEqual(panel.frame.height, budget)
    XCTAssertGreaterThan(panel.frame.height, budget - lineHeight)
    let visibleLines = resultScrollView.contentView.bounds.height / lineHeight
    XCTAssertEqual(visibleLines, visibleLines.rounded(), accuracy: 0.001, "No line is cut")
    XCTAssertGreaterThan(container.frame.height, resultScrollView.contentView.bounds.height)
    XCTAssertEqual(
      resultScrollView.contentView.bounds.minY, 0, accuracy: 0.5,
      "A completed result is read from the top")
    let sourceEditor = try XCTUnwrap(firstTextView(in: contentView, identifier: "composer-input"))
    XCTAssertLessThanOrEqual(
      sourceEditor.enclosingScrollView?.frame.height ?? .infinity,
      controller.heightBudget.sourceEditorMaxHeight + 0.5
    )
  }

  func testSubmitKeepsTheSourceAndReplacesTheResult() async throws {
    let model = AppModel(
      inputText: "First source",
      service: DelayedStreamingService(chunks: ["First result"], delay: .milliseconds(10))
    )
    let controller = makeHiddenPanel(model: model)
    let contentView = try XCTUnwrap(controller.contentView)
    let input = try XCTUnwrap(firstTextView(in: contentView, identifier: "composer-input"))

    XCTAssertTrue(model.submit())
    try await waitUntil(timeout: .seconds(2)) { model.result?.phase == .completed }
    let firstResult = try XCTUnwrap(model.result)

    XCTAssertEqual(input.string, "First source")
    XCTAssertEqual(model.inputText, "First source")
    XCTAssertEqual(firstResult.result, "First result")
    XCTAssertFalse(model.isResultStale)

    input.string = "Edited source"
    input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
    XCTAssertTrue(model.isResultStale)
    XCTAssertEqual(model.resultNote, .stale)

    XCTAssertTrue(model.submit())
    XCTAssertFalse(model.result === firstResult, "A new submission replaces the record")
    XCTAssertEqual(model.result?.source, "Edited source")
    try await waitUntil(timeout: .seconds(2)) { model.result?.phase == .completed }
    XCTAssertFalse(model.isResultStale)
    assertTestProcessIsNotFrontmost()
  }

  /// One slot, three phases: nothing while typing, 停止 while a request runs,
  /// 复制结果 once a result exists, ✓ 已复制 right after copying.
  func testControlBarSlotShowsStopWhileStreamingAndCopyAfterwards() async throws {
    let model = AppModel(
      inputText: "Slot source",
      service: DelayedStreamingService(chunks: ["Slot", " result"], delay: .milliseconds(120))
    )
    func slot(copied: Bool = false) -> BarActionPresentation {
      .resolve(
        isProcessing: model.isProcessing,
        canCopyResult: model.canCopyResult,
        copyFeedback: copied ? .text : nil
      )
    }
    XCTAssertEqual(slot(), .none)

    XCTAssertTrue(model.submit())
    XCTAssertEqual(slot(), .stop)
    XCTAssertEqual(slot(copied: true), .stop, "Stop wins while the request runs")

    try await waitUntil(timeout: .seconds(3)) { model.result?.phase == .completed }
    XCTAssertEqual(slot(), .copy)
    XCTAssertTrue(model.copyResult())
    XCTAssertEqual(slot(copied: true), .copied(.text))

    model.cancelProcessing()
    XCTAssertEqual(slot(), .copy, "Cancelling an idle model changes nothing")
  }

  // MARK: - Settings window

  func testSettingsWindowIsAFixedWidthTitledWindowSizedByItsContent() throws {
    let controller = SettingsWindowFactory.makeWindowController(
      model: AppModel(settings: .designPreview), updates: UpdateState())
    let window = try XCTUnwrap(controller.window)
    retainedTestWindows.append(window)

    XCTAssertTrue(window.styleMask.contains(.titled))
    XCTAssertTrue(window.styleMask.contains(.closable))
    XCTAssertTrue(window.styleMask.contains(.miniaturizable))
    XCTAssertFalse(window.styleMask.contains(.resizable), "Width is fixed; height follows content")
    XCTAssertNotNil(window.standardWindowButton(.closeButton))
    XCTAssertEqual(window.frame.width, SettingsWindowFactory.width, accuracy: 0.5)
  }

  func testSettingsShortcutRecorderTakesTheNextCombinationAndEscapeCancels() async throws {
    let applied = AppliedShortcuts()
    let model = AppModel(
      settings: .designPreview,
      saveSettings: { _ in },
      applyGlobalShortcut: { shortcut, _ in
        applied.values.append(shortcut)
        return shortcut?.keyCode != UInt16(kVK_ANSI_Q)
      })
    model.settingsTab = .shortcuts
    let controller = SettingsWindowFactory.makeWindowController(model: model, updates: UpdateState())
    let window = try XCTUnwrap(controller.window)
    retainedTestWindows.append(window)
    window.alphaValue = 0
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    window.contentView?.layoutSubtreeIfNeeded()

    /// Finish the previous focus transition before starting another recording. A fixed delay
    /// can expire before SwiftUI updates the recorder on a busy runner.
    func startRecording() async throws {
      try await waitUntil(timeout: .seconds(5)) { !(window.firstResponder is ShortcutCaptureNSView) }
      model.recordingShortcut = .showPanel
      try await waitUntil(timeout: .seconds(5)) { window.firstResponder is ShortcutCaptureNSView }
    }

    model.recordingShortcut = .showPanel
    try await waitUntil(timeout: .seconds(5)) { window.firstResponder is ShortcutCaptureNSView }
    let recorder = try XCTUnwrap(window.firstResponder as? ShortcutCaptureNSView)

    // Shift alone is not a shortcut: the recorder keeps waiting.
    recorder.record(keyEvent(kVK_ANSI_T, "t", [.shift]))
    XCTAssertEqual(model.recordingShortcut, .showPanel)
    XCTAssertEqual(model.settings.shortcut, GlobalShortcut.optionA)

    recorder.record(keyEvent(kVK_ANSI_T, "t", [.control, .option]))
    let recorded = GlobalShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: [.control, .option])
    XCTAssertEqual(model.settings.shortcut, recorded)
    XCTAssertEqual(applied.values, [recorded], "The combination is registered before it is kept")
    try await waitUntil(timeout: .seconds(5)) { model.recordingShortcut == nil }
    try await waitUntil(timeout: .seconds(5)) { !(window.firstResponder is ShortcutCaptureNSView) }

    try await startRecording()
    recorder.record(keyEvent(kVK_Escape, "\u{1B}", []))
    try await waitUntil(timeout: .seconds(5)) { model.recordingShortcut == nil }
    XCTAssertEqual(model.settings.shortcut, recorded, "Escape keeps the combination")

    // A combination the system refuses leaves the current one in place.
    try await startRecording()
    recorder.record(keyEvent(kVK_ANSI_Q, "q", [.command]))
    try await waitUntil(timeout: .seconds(5)) { model.recordingShortcut == nil }
    XCTAssertEqual(model.settings.shortcut, recorded)
    XCTAssertEqual(applied.values.count, 2)

    // ⌫ alone leaves the action without a shortcut; the system only releases it.
    try await startRecording()
    recorder.record(keyEvent(kVK_Delete, "\u{7F}", []))
    try await waitUntil(timeout: .seconds(5)) { model.recordingShortcut == nil }
    XCTAssertNil(model.settings.shortcut)
    XCTAssertEqual(applied.values.last, .some(nil))
    // ⌥⌫ is a combination like any other.
    try await startRecording()
    recorder.record(keyEvent(kVK_Delete, "\u{7F}", [.option]))
    try await waitUntil(timeout: .seconds(5)) { model.recordingShortcut == nil }
    XCTAssertEqual(
      model.settings.shortcut, GlobalShortcut(keyCode: UInt16(kVK_Delete), modifiers: .option))
    assertTestProcessIsNotFrontmost()
  }

  /// Recording can start before the recorder is in a window (Settings attaches its scroll
  /// view's content later); it must still hold the keyboard once it arrives.
  func testSettingsShortcutRecorderTakesTheKeyboardWhenItReachesAWindow() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    retainedTestWindows.append(window)
    let recorder = ShortcutCaptureNSView()

    recorder.wantsKeyFocus = true
    XCTAssertNil(recorder.window)
    window.contentView?.addSubview(recorder)
    XCTAssertTrue(window.firstResponder === recorder)

    recorder.wantsKeyFocus = false
    XCTAssertFalse(window.firstResponder === recorder)
    assertTestProcessIsNotFrontmost()
  }

  private final class AppliedShortcuts {
    var values: [GlobalShortcut?] = []
  }

  private func keyEvent(_ keyCode: Int, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: UInt16(keyCode))!
  }

  func testNativeCloseButtonClosesARealBackgroundSettingsWindow() throws {
    let (window, _) = makeNativeWindow(
      rootView: SettingsWindowView(model: AppModel(), updates: UpdateState()),
      size: CGSize(width: 560, height: 660)
    )
    window.alphaValue = 0
    window.orderBack(nil)
    XCTAssertTrue(window.isVisible)

    let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
    closeButton.performClick(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    XCTAssertFalse(window.isVisible)
    assertTestProcessIsNotFrontmost()
  }

  /// A screen whose visible height is below the tab's natural height scrolls the tab under the
  /// tab bar instead of running behind the Dock.
  func testSettingsScrollsInsteadOfOutgrowingASmallScreen() throws {
    // Heights are measured in the bundled faces, whichever test ran first.
    FontRegistrar.registerBundledFonts()
    let model = AppModel(settings: .designPreview)
    model.settingsTab = .shortcuts
    let controller = SettingsWindowFactory.makeWindowController(
      model: model, updates: UpdateState(), maxContentHeight: 400)
    let window = try XCTUnwrap(controller.window)
    retainedTestWindows.append(window)
    window.alphaValue = 0
    window.orderBack(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))

    XCTAssertEqual(window.frame.height, 400, accuracy: 1)

    model.settingsTab = .translation
    model.editingPrompt = .improve
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    XCTAssertEqual(window.frame.height, 400, accuracy: 1, "An open prompt sheet scrolls too")
    assertTestProcessIsNotFrontmost()
  }

  func testSettingsWindowHeightFollowsItsTabFromAFixedTopEdge() throws {
    // Heights are measured in the bundled faces, whichever test ran first.
    FontRegistrar.registerBundledFonts()
    let model = AppModel(settings: .designPreview)
    let controller = SettingsWindowFactory.makeWindowController(
      model: model, updates: UpdateState(), maxContentHeight: 2_000)
    let window = try XCTUnwrap(controller.window)
    retainedTestWindows.append(window)
    window.alphaValue = 0
    window.orderBack(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))

    let modelFrame = window.frame
    XCTAssertEqual(modelFrame.height, 250, accuracy: 4, "The board's 模型 is 252 pt tall")
    XCTAssertEqual(window.title, "模型")
    let contentView = try XCTUnwrap(window.contentView)
    let content = try XCTUnwrap(
      ([contentView] + contentView.subviews).first { $0.accessibilityLabel() == "设置窗口内容" })
    /// Waits for a move to end, checking on every turn of the run loop that the content's top
    /// stays on the window's top edge while the frame moves. Every move changes the height, so
    /// the move has ended once the height has left where it started and held for 0.2 s; a
    /// loaded machine may start it late, so there is no fixed window.
    func settle(_ move: String) {
      let startHeight = window.frame.height
      let deadline = Date().addingTimeInterval(2)
      var lastHeight = startHeight
      var heldSince = Date()
      var drift: [String] = []
      while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        let height = window.frame.height
        let top = content.convert(content.bounds, to: nil).maxY
        if abs(top - height) > 0.5 {
          drift.append(String(format: "%.0f in %.0f", top, height))
        }
        if abs(height - lastHeight) > 0.1 {
          lastHeight = height
          heldSince = Date()
        } else if abs(height - startHeight) > 0.5, Date().timeIntervalSince(heldSince) >= 0.2 {
          break
        }
      }
      XCTAssertEqual(drift, [], "\(move): the tabs stay under the title while the window moves")
    }

    // The window follows over motion-height-ms; wait for each move to end.
    model.settingsTab = .shortcuts
    settle("模型 → 快捷键")
    XCTAssertEqual(window.frame.height, 470, accuracy: 4, "The board's 快捷键 is 471 pt tall")
    XCTAssertEqual(window.frame.maxY, modelFrame.maxY, accuracy: 0.5, "The top edge stays put")
    XCTAssertEqual(window.title, "快捷键", "The title names the tab")

    model.settingsTab = .translation
    settle("快捷键 → 翻译")
    let collapsedFrame = window.frame
    XCTAssertEqual(collapsedFrame.height, 364, accuracy: 4, "The board's 翻译 is 365 pt tall")

    model.editingPrompt = .improve
    settle("展开提示词")
    let expandedFrame = window.frame
    XCTAssertGreaterThan(expandedFrame.height, collapsedFrame.height + 80, "The prompt sheet grows the window")
    XCTAssertEqual(expandedFrame.maxY, modelFrame.maxY, accuracy: 0.5, "The top edge stays put")

    model.editingPrompt = nil
    settle("收起提示词")
    XCTAssertEqual(window.frame.height, collapsedFrame.height, accuracy: 0.5)
    assertTestProcessIsNotFrontmost()
  }

  /// A growing pane must not scroll its text up and snap it back on every new
  /// line, and a result that outgrows the pane stays at its start.
  func testStreamingResultDoesNotBounceWhileThePaneGrows() async throws {
    let source = String(repeating: ">> [ ] Download links are valid and checksums match.\n", count: 80)
    let piece = "这是一段较长的中文译文，用来观察流式输出时结果栏的高度与滚动位置是否会来回跳动。"
    let chunks = (0..<100).map { index in
      (index % 9 == 8 ? "\n" : "") + String(piece.prefix(12 + index % 20))
    }
    let model = AppModel(
      inputText: source,
      service: DelayedStreamingService(chunks: chunks, delay: .milliseconds(6))
    )
    let controller = makeHiddenPanel(model: model)
    controller.panel.orderBack(nil)
    let hostingView = try XCTUnwrap(controller.contentView)
    try await Task.sleep(for: .milliseconds(150))

    let streaming = Task { await model.process(text: source) }
    var lastScrollY: CGFloat = 0
    var lastPanelHeight = controller.panel.frame.height
    var scrollReversals: [String] = []
    var panelShrinks: [String] = []
    var sourceTopDrift: [String] = []
    var scrolledAwayFromTheStart: [String] = []
    var outgrewThePane = false
    let composer = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))
    let composerScrollView = try XCTUnwrap(composer.enclosingScrollView)
    func sourceTopInset() -> CGFloat {
      let inWindow = composerScrollView.convert(composerScrollView.bounds, to: nil)
      return controller.panel.frame.height - inWindow.maxY
    }
    let initialSourceTop = sourceTopInset()
    let started = Date()
    while Date().timeIntervalSince(started) < 4, model.result?.phase != .completed {
      try await Task.sleep(for: .milliseconds(8))
      guard let scrollView = firstResultScrollView(in: hostingView) else { continue }
      let scrollY = scrollView.contentView.bounds.origin.y
      let panelHeight = controller.panel.frame.height
      if scrollY < lastScrollY - 0.5 {
        scrollReversals.append("\(lastScrollY) -> \(scrollY)")
      }
      if panelHeight < lastPanelHeight - 0.5 {
        panelShrinks.append("\(lastPanelHeight) -> \(panelHeight)")
      }
      if scrollY > 0.5 { scrolledAwayFromTheStart.append(String(format: "%.1f", scrollY)) }
      if scrollView.container.frame.height > scrollView.contentView.bounds.height + 1 {
        outgrewThePane = true
      }
      let sourceTop = sourceTopInset()
      if abs(sourceTop - initialSourceTop) > 0.5 {
        sourceTopDrift.append(String(format: "%.1f", sourceTop))
      }
      lastScrollY = scrollY
      lastPanelHeight = panelHeight
    }
    streaming.cancel()

    XCTAssertTrue(outgrewThePane, "The result outgrew the pane")
    XCTAssertEqual(
      scrolledAwayFromTheStart, [], "The result stays at its start while it streams below the fold")
    XCTAssertEqual(scrollReversals, [], "The text never jumped back down")
    XCTAssertEqual(panelShrinks, [], "The panel only grew")
    XCTAssertEqual(
      sourceTopDrift, [],
      "The source pane stays pinned to the panel's top edge while the height animates (initial \(initialSourceTop))")
    XCTAssertLessThanOrEqual(
      controller.panel.frame.height, PanelHeightBudget.automation.panelMaxHeight)
    XCTAssertGreaterThan(
      controller.panel.frame.height,
      PanelHeightBudget.automation.panelMaxHeight - CidaDesign.Typography.resultLineHeightCJK,
      "At its cap the result pane shows whole lines")
    assertTestProcessIsNotFrontmost()
  }

  /// Scrolling to the end of a streaming result is asking to watch it: the
  /// pane follows the tail from then on.
  func testStreamingResultFollowsItsTailOnceTheUserScrollsThere() async throws {
    let chunks = (0..<100).map { index in
      (index % 9 == 8 ? "\n" : "") + "用户滚到底部之后，结果栏跟着新写出的文字往下走。"
    }
    let model = AppModel(
      inputText: "Source",
      service: DelayedStreamingService(chunks: chunks, delay: .milliseconds(6))
    )
    let controller = makeHiddenPanel(model: model)
    controller.panel.orderBack(nil)
    let hostingView = try XCTUnwrap(controller.contentView)
    try await Task.sleep(for: .milliseconds(150))

    let streaming = Task { await model.process(text: "Source") }
    defer { streaming.cancel() }
    var scrollView: ResultScrollView?
    try await waitUntil(timeout: .seconds(4)) {
      guard let found = self.firstResultScrollView(in: hostingView) else { return false }
      scrollView = found
      return found.container.frame.height
        > found.contentView.bounds.height + 2 * CidaDesign.Typography.resultLineHeightCJK
    }
    let pane = try XCTUnwrap(scrollView)
    XCTAssertEqual(pane.contentView.bounds.minY, 0, accuracy: 0.5, "Nothing scrolled before the user")

    pane.contentView.scroll(
      to: NSPoint(x: 0, y: pane.container.frame.height - pane.contentView.bounds.height))
    pane.reflectScrolledClipView(pane.contentView)
    let wheel = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
    pane.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
    let reachedTheTailAt = pane.contentView.bounds.minY

    try await waitUntil(timeout: .seconds(2)) {
      pane.contentView.bounds.minY > reachedTheTailAt + CidaDesign.Typography.resultLineHeightCJK
    }
    XCTAssertLessThanOrEqual(
      pane.container.frame.height - pane.contentView.bounds.maxY,
      CidaDesign.Typography.resultLineHeightCJK,
      "The tail stays in view")
    XCTAssertEqual(model.result?.phase, .streaming)
    assertTestProcessIsNotFrontmost()
  }

  // MARK: - Responder chain

  func testClickingComposerThenTypingUsesTheRealResponderChain() async throws {
    let model = AppModel()
    let controller = makeHiddenPanel(model: model)
    let window = controller.panel
    let hostingView = try XCTUnwrap(controller.contentView)
    window.orderBack(nil)
    hostingView.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    hostingView.layoutSubtreeIfNeeded()
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))
    let scrollView = try XCTUnwrap(input.enclosingScrollView)
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      scrollView.layoutSubtreeIfNeeded()
      return scrollView.frame.height > 0
    }
    let clickPoint = input.convert(NSPoint(x: 12, y: 12), to: nil)
    let hitView = window.contentView?.hitTest(clickPoint)
    XCTAssertTrue(
      hitView === input,
      "hit=\(String(describing: hitView)) input=\(input.frame) point=\(clickPoint)"
    )
    guard hitView === input else { return }

    clickTextInput(window: window, at: clickPoint)
    XCTAssertTrue(window.firstResponder === input || window.makeFirstResponder(input))

    type("Real keyboard input", in: window)
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertEqual(input.string, "Real keyboard input")
    XCTAssertEqual(model.inputText, "Real keyboard input")
    assertTestProcessIsNotFrontmost()
  }

}

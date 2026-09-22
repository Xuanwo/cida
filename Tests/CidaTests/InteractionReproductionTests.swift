import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import Cida

@MainActor
final class InteractionReproductionTests: XCTestCase {
  static var clickEventNumber = 0
  var retainedTestWindows: [NSWindow] = []
  var retainedPanelControllers: [PanelController] = []

  override func tearDown() async throws {
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

  /// Pencil `Spec — 面板模型` §一: a borderless floating panel that takes the
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

  func testPanelNeverExceedsItsHeightBudgetAndScrollsTheResultInstead() async throws {
    let model = AppModel(inputText: ResultRecord.designLongInput)
    model.setResultForTesting(ResultRecord.designLong())
    let controller = makeHiddenPanel(model: model)
    let panel = controller.panel

    try await waitUntil(timeout: .seconds(2)) {
      controller.contentView?.layoutSubtreeIfNeeded()
      return abs(panel.frame.height - controller.heightBudget.panelMaxHeight) <= 1
    }
    let contentView = try XCTUnwrap(controller.contentView)
    let resultScrollView = try XCTUnwrap(firstResultScrollView(in: contentView))
    let container = resultScrollView.container
    try await waitUntil(timeout: .seconds(2)) {
      container.naturalTextHeight > resultScrollView.contentView.bounds.height
    }

    XCTAssertEqual(panel.frame.height, controller.heightBudget.panelMaxHeight, accuracy: 1)
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
        showsCopiedFeedback: copied
      )
    }
    XCTAssertEqual(slot(), .none)

    XCTAssertTrue(model.submit())
    XCTAssertEqual(slot(), .stop)
    XCTAssertEqual(slot(copied: true), .stop, "Stop wins while the request runs")

    try await waitUntil(timeout: .seconds(3)) { model.result?.phase == .completed }
    XCTAssertEqual(slot(), .copy)
    XCTAssertTrue(model.copyResult())
    XCTAssertEqual(slot(copied: true), .copied)

    model.cancelProcessing()
    XCTAssertEqual(slot(), .copy, "Cancelling an idle model changes nothing")
  }

  // MARK: - Settings window

  func testSettingsWindowRemainsAStandardTitledWindow() {
    let window = CidaWindowFactory.makeWindow(
      size: CGSize(width: 560, height: 660),
      title: "设置"
    )
    retainedTestWindows.append(window)

    XCTAssertTrue(window.styleMask.contains(.titled))
    XCTAssertTrue(window.styleMask.contains(.closable))
    XCTAssertTrue(window.styleMask.contains(.miniaturizable))
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertNotNil(window.standardWindowButton(.closeButton))
  }

  func testNativeCloseButtonClosesARealBackgroundSettingsWindow() throws {
    let (window, _) = makeNativeWindow(
      rootView: SettingsWindowView(model: AppModel()),
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

  func testSettingsContentRemainsScrollableAtItsMinimumWindowSize() throws {
    var settings = CidaSettings.designPreview
    settings.provider = .openAI
    settings.model = "local-model"
    let (_, hostingView) = makeNativeWindow(
      rootView: SettingsWindowView(model: AppModel(settings: settings)),
      size: CGSize(width: 500, height: 500)
    )
    let scrollView = try XCTUnwrap(
      allScrollViews(in: hostingView).max { lhs, rhs in
        (lhs.documentView?.bounds.height ?? 0) < (rhs.documentView?.bounds.height ?? 0)
      }
    )
    let documentView = try XCTUnwrap(scrollView.documentView)

    XCTAssertGreaterThan(documentView.bounds.height, scrollView.contentView.bounds.height)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let settingsIndicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "settings-scroll-indicator")
    )
    XCTAssertFalse(settingsIndicator.isHidden)
    XCTAssertEqual(settingsIndicator.knobDrawingRect.width, 4, accuracy: 0.1)
    XCTAssertEqual(settingsIndicator.knobDrawingRect.height, 64, accuracy: 0.1)
    let bottomOrigin = NSPoint(
      x: 0,
      y: max(0, documentView.bounds.maxY - scrollView.contentView.bounds.height)
    )
    scrollView.contentView.scroll(to: bottomOrigin)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    XCTAssertTrue(isScrolledToBottom(scrollView))
  }

  func testSettingsHidesItsScrollIndicatorAtThePencilWindowSize() throws {
    let (window, hostingView) = makeHiddenWindow(
      rootView: SettingsWindowView(
        model: AppModel(settings: .designPreview)
      ),
      size: CGSize(width: 560, height: 660)
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    hostingView.layoutSubtreeIfNeeded()

    let indicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "settings-scroll-indicator")
    )
    let scrollView = try XCTUnwrap(indicator.observedScrollView)
    let documentView = try XCTUnwrap(scrollView.documentView)
    XCTAssertTrue(
      indicator.isHidden,
      "document=\(documentView.bounds) visible=\(scrollView.contentView.documentVisibleRect)"
    )
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
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
    let indicator = try XCTUnwrap(CidaScrollIndicator.installed(in: scrollView))
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      scrollView.layoutSubtreeIfNeeded()
      indicator.refresh()
      return (indicator.superview?.frame.height ?? 0) > 0 && indicator.isHidden
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

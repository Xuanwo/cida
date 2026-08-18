import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import Cida

@MainActor
final class InteractionReproductionTests: XCTestCase {
  private static var clickEventNumber = 0
  private var retainedTestWindows: [NSWindow] = []

  override func tearDown() async throws {
    CATransaction.flush()
    let retainedContentViews = retainedTestWindows.compactMap(\.contentView)
    for window in retainedTestWindows {
      window.orderOut(nil)
      window.contentView = nil
      window.close()
    }
    CATransaction.flush()
    retainedTestWindows.removeAll(keepingCapacity: false)
    withExtendedLifetime(retainedContentViews) {}
    try await Task.sleep(for: .milliseconds(10))
    try await super.tearDown()
  }

  func testWindowSupportsCloseMinimizeZoomAndControlInteraction() {
    let window = CidaWindowFactory.makeWindow(
      size: CGSize(width: 860, height: 640),
      title: "Test"
    )

    XCTAssertTrue(window.styleMask.contains(.titled))
    XCTAssertTrue(window.styleMask.contains(.closable))
    XCTAssertTrue(window.styleMask.contains(.miniaturizable))
    XCTAssertTrue(window.styleMask.contains(.resizable))
    XCTAssertTrue(window.titlebarAppearsTransparent)
    XCTAssertFalse(window.isMovableByWindowBackground)
    XCTAssertNotNil(window.standardWindowButton(.closeButton))
    XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
    XCTAssertNotNil(window.standardWindowButton(.zoomButton))
    XCTAssertGreaterThan(window.maxSize.width, window.minSize.width)
    XCTAssertGreaterThan(window.maxSize.height, window.minSize.height)

    let originalLayoutSize = window.contentLayoutRect.size
    window.setContentSize(CGSize(width: 960, height: 740))
    XCTAssertGreaterThan(window.contentLayoutRect.size.width, originalLayoutSize.width)
    XCTAssertGreaterThan(window.contentLayoutRect.size.height, originalLayoutSize.height)
  }

  func testMainAndSettingsContentFillResizedNativeWindows() {
    let model = AppModel(entries: [], settings: .designPreview)
    let (mainWindow, mainHostingView) = makeNativeWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let (settingsWindow, settingsHostingView) = makeNativeWindow(
      rootView: SettingsWindowView(model: model),
      size: CGSize(width: 560, height: 660)
    )

    mainWindow.setContentSize(CGSize(width: 960, height: 740))
    settingsWindow.setContentSize(CGSize(width: 720, height: 820))
    mainHostingView.layoutSubtreeIfNeeded()
    settingsHostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(mainHostingView.frame.size.width, 960, accuracy: 0.5)
    XCTAssertEqual(mainHostingView.frame.size.height, 740, accuracy: 0.5)
    XCTAssertEqual(settingsHostingView.frame.size.width, 720, accuracy: 0.5)
    XCTAssertEqual(settingsHostingView.frame.size.height, 820, accuracy: 0.5)
  }

  func testMainAndSettingsWindowsBothZoomAndRestoreInTheBackground() {
    let configurations: [(title: String, size: CGSize, minimumSize: CGSize)] = [
      ("Main", CGSize(width: 860, height: 640), CGSize(width: 640, height: 480)),
      ("Settings", CGSize(width: 560, height: 660), CGSize(width: 500, height: 500)),
    ]

    for configuration in configurations {
      let window = CidaWindowFactory.makeWindow(
        size: configuration.size,
        minimumSize: configuration.minimumSize,
        title: configuration.title
      )
      window.animationBehavior = .none
      window.alphaValue = 0
      window.center()
      window.orderBack(nil)
      let originalFrame = window.frame
      window.zoom(nil)
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let zoomedFrame = window.frame
      window.zoom(nil)
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let restoredFrame = window.frame
      window.orderOut(nil)

      XCTAssertNotEqual(zoomedFrame, originalFrame, configuration.title)
      XCTAssertEqual(restoredFrame.origin.x, originalFrame.origin.x, accuracy: 0.5)
      XCTAssertEqual(restoredFrame.origin.y, originalFrame.origin.y, accuracy: 0.5)
      XCTAssertEqual(restoredFrame.width, originalFrame.width, accuracy: 0.5)
      XCTAssertEqual(restoredFrame.height, originalFrame.height, accuracy: 0.5)
    }
    assertTestProcessIsNotFrontmost()
  }

  func testNativeCloseButtonClosesARealBackgroundSettingsWindow() throws {
    let (window, _) = makeNativeWindow(
      rootView: SettingsWindowView(model: AppModel(entries: [])),
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
      rootView: SettingsWindowView(model: AppModel(entries: [], settings: settings)),
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
        model: AppModel(entries: [], settings: .designPreview)
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

  func testModelStatusButtonOpensSettings() {
    var settingsRequestCount = 0
    let model = AppModel(entries: [], settings: .designPreview)
    let (window, _) = makeHiddenWindow(
      rootView: MainWindowView(model: model) {
        settingsRequestCount += 1
      },
      size: CGSize(width: 860, height: 640)
    )
    window.alphaValue = 0
    window.orderBack(nil)

    click(window: window, at: NSPoint(x: 786, y: 617))
    window.orderOut(nil)

    XCTAssertEqual(settingsRequestCount, 1)
    assertTestProcessIsNotFrontmost()
  }

  func testClickingComposerThenTypingUsesTheRealResponderChain() async throws {
    let model = AppModel(entries: [])
    let (window, hostingView) = makeNativeWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    window.alphaValue = 0
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
    XCTAssertTrue(
      indicator.isHidden,
      "document=\(String(describing: scrollView.documentView?.bounds)) visible=\(scrollView.contentView.documentVisibleRect) indicator=\(indicator.frame) host=\(String(describing: indicator.superview?.frame))"
    )
    let clickPoint = input.convert(NSPoint(x: 12, y: 12), to: nil)
    let hitView = window.contentView?.hitTest(clickPoint)
    XCTAssertTrue(
      hitView === input,
      "hit=\(String(describing: hitView)) input=\(input.frame) scroll=\(String(describing: input.enclosingScrollView?.frame)) point=\(clickPoint)"
    )
    guard hitView === input else { return }
    let trailingClickPoint = input.convert(
      NSPoint(x: input.bounds.maxX - 4, y: 12),
      to: nil
    )
    XCTAssertTrue(window.contentView?.hitTest(trailingClickPoint) === input)

    clickTextInput(window: window, at: clickPoint)
    XCTAssertTrue(window.firstResponder === input || window.makeFirstResponder(input))

    type("Real keyboard input", in: window)
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertEqual(input.string, "Real keyboard input")
    XCTAssertEqual(model.inputText, "Real keyboard input")
    assertTestProcessIsNotFrontmost()
  }

  func testHistoryAutomaticallyFollowsStreamingUpdatesToTheBottom() throws {
    let entries = (0..<24).map { index in
      HistoryEntry(
        mode: .translate,
        source: "Source \(index)",
        result: "Result \(index)\nwith another line",
        detail: "中文 → English",
        timestamp: "18:00"
      )
    }
    let model = AppModel(entries: entries)
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let scrollView = try XCTUnwrap(
      allScrollViews(in: hostingView).max { lhs, rhs in
        lhs.frame.height < rhs.frame.height
      }
    )
    let documentView = try XCTUnwrap(scrollView.documentView)
    XCTAssertGreaterThan(documentView.bounds.height, scrollView.contentView.bounds.height)

    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)

    let entryID = UUID()
    model.setGenerationStateForTesting(.revealing(entryID: entryID))
    model.entries.append(
      HistoryEntry(
        id: entryID,
        mode: .translate,
        source: "Latest source",
        result: "First streamed chunk",
        detail: "中文 → English",
        timestamp: "18:01",
        state: .streaming
      )
    )
    model.requestHistoryFollow()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    XCTAssertTrue(isScrolledToBottom(scrollView), scrollDescription(scrollView))

    let delta = String(repeating: "\nNext chunk", count: 12)
    model.entries[model.entries.count - 1].appendPresentationDelta(delta)
    model.entries[model.entries.count - 1].state = .completed
    model.setGenerationStateForTesting(.idle)
    model.requestHistoryFollow()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    XCTAssertTrue(isScrolledToBottom(scrollView), scrollDescription(scrollView))
  }

  func testHistoryHostingCapacityDoesNotLeakIntoScrollableGeometry() throws {
    let model = AppModel()
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let indicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "history-scroll-indicator")
    )
    let scrollView = try XCTUnwrap(indicator.observedScrollView)
    let documentView = try XCTUnwrap(scrollView.documentView)
    let historyHost = try XCTUnwrap(
      documentView.subviews.compactMap { $0 as? ResizingHistoryHostingView }.first
    )

    XCTAssertEqual(documentView.frame.width, scrollView.contentSize.width, accuracy: 0.5)
    XCTAssertEqual(
      documentView.frame.height,
      scrollView.contentSize.height + HistoryNativeScrollView.scrollGeometryRunway,
      accuracy: 0.5,
      "Reserved hosting capacity must not become blank scrollable history."
    )
    XCTAssertGreaterThan(
      historyHost.frame.height,
      documentView.frame.height + 512,
      "The hosting surface must reserve stable height before streaming begins."
    )
    indicator.refresh()
    XCTAssertTrue(indicator.isHidden)
    XCTAssertFalse(scrollView.hasVerticalScroller)
    XCTAssertNil(scrollView.verticalScroller)
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testCoalescedResultHeightPublicationPreservesEveryDelta() {
    let host = HistoryResultHeightProbeView()
    let container = HistoryResultTextContainer()
    host.addSubview(container)

    container.scheduleNaturalHeightPublication(heightDelta: 26)
    container.scheduleNaturalHeightPublication(heightDelta: 52)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    XCTAssertEqual(host.publishedHeightDeltas, [78])
  }

  func testSubmitFollowIsNotOverwrittenByACoalescedStreamingFollow() throws {
    let entries = (0..<24).map { index in
      HistoryEntry(
        mode: .translate,
        source: "Source \(index)",
        result: "Result \(index)\nwith another line",
        detail: "中文 → English",
        timestamp: "18:00"
      )
    }
    let model = AppModel(entries: entries)
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let scrollView = try XCTUnwrap(
      allScrollViews(in: hostingView).max { lhs, rhs in
        lhs.frame.height < rhs.frame.height
      }
    )

    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    NotificationCenter.default.post(
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    XCTAssertFalse(isScrolledToBottom(scrollView), scrollDescription(scrollView))

    model.entries.append(
      HistoryEntry(
        mode: .translate,
        source: "Newly submitted source",
        result: "First streamed chunk",
        detail: "中文 → English",
        timestamp: "18:01",
        state: .streaming
      )
    )
    model.setGenerationStateForTesting(.revealing(entryID: model.entries.last!.id))
    model.requestHistoryFollow(force: true)
    Thread.sleep(forTimeInterval: 0.06)
    model.requestHistoryFollow(force: false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))

    XCTAssertTrue(isScrolledToBottom(scrollView), scrollDescription(scrollView))
  }

  func testProductionShapedHistoryMaterializesNewestEntriesAcrossConsecutiveSubmissions() throws {
    let model = AppModel(entries: HistoryEntry.interactionTestHistoryContinuitySamples)
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let historyScrollView = try XCTUnwrap(
      allScrollViews(in: hostingView).max { lhs, rhs in
        lhs.frame.height < rhs.frame.height
      }
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    hostingView.layoutSubtreeIfNeeded()

    let firstEntryID = UUID()
    model.entries.append(
      HistoryEntry(
        id: firstEntryID,
        mode: .translate,
        source: "Newest submitted source",
        result: "",
        detail: "中文 → English",
        timestamp: "16:20",
        state: .streaming
      )
    )
    model.setGenerationStateForTesting(.revealing(entryID: firstEntryID))
    model.requestHistoryFollow(force: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    hostingView.layoutSubtreeIfNeeded()

    model.entries[model.entries.count - 1].appendPresentationDelta(
      (0..<30).map { "Streamed line \($0) remains visible." }.joined(separator: "\n")
    )
    model.entries[model.entries.count - 1].state = .completed
    model.requestHistoryFollow(force: false, allowsThrottling: false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    hostingView.layoutSubtreeIfNeeded()

    let secondEntryID = UUID()
    model.entries.append(
      HistoryEntry(
        id: secondEntryID,
        mode: .translate,
        source: "Second submitted source",
        result: "",
        detail: "中文 → English",
        timestamp: "16:21",
        state: .streaming
      )
    )
    model.requestHistoryFollow(force: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    hostingView.layoutSubtreeIfNeeded()

    let secondResultTextView = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "history-result-\(secondEntryID.uuidString)")
    )
    let resultFrameInHost = secondResultTextView.convert(
      secondResultTextView.bounds, to: hostingView)
    let historyViewportInHost = historyScrollView.contentView.convert(
      historyScrollView.contentView.bounds,
      to: hostingView
    )
    XCTAssertGreaterThan(resultFrameInHost.intersection(historyViewportInHost).height, 8)
    XCTAssertTrue(isScrolledToBottom(historyScrollView), scrollDescription(historyScrollView))
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testHistoryOnlyLaysOutAnOlderResultAfterTheUserExpandsIt() throws {
    let olderID = UUID()
    let middleID = UUID()
    let latestID = UUID()
    let model = AppModel(
      entries: [
        HistoryEntry(
          id: olderID,
          mode: .translate,
          source: "Older source",
          result: String(repeating: "Older result stays cheap while folded. ", count: 2_000),
          detail: "中文 → English",
          timestamp: "17:58"
        ),
        HistoryEntry(
          id: middleID,
          mode: .translate,
          source: "Middle source",
          result: "Middle result",
          detail: "中文 → English",
          timestamp: "17:59"
        ),
        HistoryEntry(
          id: latestID,
          mode: .translate,
          source: "Latest source",
          result: "Latest result",
          detail: "中文 → English",
          timestamp: "18:00"
        ),
      ]
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertNil(firstTextView(in: hostingView, identifier: "history-result-\(olderID.uuidString)"))
    XCTAssertNil(
      firstTextView(in: hostingView, identifier: "history-result-\(middleID.uuidString)"))
    XCTAssertNotNil(
      firstTextView(in: hostingView, identifier: "history-result-\(latestID.uuidString)"))

    model.expandHistoryEntry(olderID)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    hostingView.layoutSubtreeIfNeeded()
    XCTAssertNotNil(
      firstTextView(in: hostingView, identifier: "history-result-\(olderID.uuidString)"))
    XCTAssertNotNil(
      firstTextView(in: hostingView, identifier: "history-result-\(latestID.uuidString)"))

    model.collapseHistoryEntry(olderID)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    hostingView.layoutSubtreeIfNeeded()
    XCTAssertNil(firstTextView(in: hostingView, identifier: "history-result-\(olderID.uuidString)"))
    assertTestProcessIsNotFrontmost()
  }

  func testEveryHistoryPresentationUsesOneNativeEntryRenderer() async throws {
    let foldedID = UUID()
    let expandedID = UUID()
    let latestID = UUID()
    let model = AppModel(
      entries: [
        HistoryEntry(
          id: foldedID,
          mode: .translate,
          source: "Folded source",
          result: "Folded result",
          detail: "中文 → English",
          timestamp: "17:58"
        ),
        HistoryEntry(
          id: expandedID,
          mode: .improve,
          source: "Expanded source",
          result: "Expanded result",
          detail: "English · 语气与语法",
          timestamp: "17:59"
        ),
        HistoryEntry(
          id: latestID,
          mode: .translate,
          source: "Latest source",
          result: "Latest result",
          detail: "中文 → English",
          timestamp: "18:00"
        ),
      ]
    )
    model.expandHistoryEntry(expandedID)
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )

    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return self.firstHistoryResultContainer(
        in: hostingView,
        identifier: "history-result-\(expandedID.uuidString)"
      ) != nil
        && self.firstHistoryResultContainer(
          in: hostingView,
          identifier: "history-result-\(latestID.uuidString)"
        ) != nil
        && (self.firstVirtualizedHistoryList(in: hostingView)?.materializedRowCount ?? 0) > 0
    }

    let expandedResult = try XCTUnwrap(
      firstHistoryResultContainer(
        in: hostingView,
        identifier: "history-result-\(expandedID.uuidString)"
      )
    )
    let latestResult = try XCTUnwrap(
      firstHistoryResultContainer(
        in: hostingView,
        identifier: "history-result-\(latestID.uuidString)"
      )
    )
    let foldedRow = try XCTUnwrap(
      firstVirtualizedHistoryList(in: hostingView)?.materializedRowsForTesting.first
    )

    let expandedRenderer = try XCTUnwrap(nativeHistoryEntryAncestor(of: expandedResult))
    let latestRenderer = try XCTUnwrap(nativeHistoryEntryAncestor(of: latestResult))
    XCTAssertEqual(foldedRow.presentation, .folded)
    XCTAssertEqual(expandedRenderer.presentation, .expanded(isLatest: false))
    XCTAssertEqual(latestRenderer.presentation, .expanded(isLatest: true))
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testRealClickOnVirtualizedFoldedRowMountsTheExpandedNativeResult() async throws {
    let foldedID = UUID()
    let latestID = UUID()
    let model = AppModel(
      entries: [
        HistoryEntry(
          id: foldedID,
          mode: .translate,
          source: "Folded source",
          result: "Folded result",
          detail: "中文 → English",
          timestamp: "17:59"
        ),
        HistoryEntry(
          id: latestID,
          mode: .translate,
          source: "Latest source",
          result: "Latest result",
          detail: "中文 → English",
          timestamp: "18:00"
        ),
      ]
    )
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    window.alphaValue = 0
    window.orderBack(nil)

    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return self.firstVirtualizedHistoryList(in: hostingView)?.materializedRowsForTesting
        .contains(where: {
          $0.accessibilityIdentifier() == "history-entry-\(foldedID.uuidString.lowercased())"
        }) == true
    }
    let row = try XCTUnwrap(
      firstVirtualizedHistoryList(in: hostingView)?.materializedRowsForTesting.first(where: {
        $0.accessibilityIdentifier() == "history-entry-\(foldedID.uuidString.lowercased())"
      })
    )
    let clickPoint = row.convert(
      NSPoint(x: row.bounds.midX, y: row.bounds.midY),
      to: nil
    )
    let hitView = window.contentView?.hitTest(clickPoint)
    XCTAssertTrue(
      hitView === row,
      "Expected the unified row to own the click, got \(String(describing: hitView))"
    )
    XCTAssertTrue(row.hasExpandHandlerForTesting)
    click(window: window, at: clickPoint)
    XCTAssertEqual(row.mouseDownCountForTesting, 1)

    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.isHistoryEntryManuallyExpanded(foldedID)
        && self.firstHistoryResultContainer(
          in: hostingView,
          identifier: "history-result-\(foldedID.uuidString)"
        ) != nil
    }
    XCTAssertTrue(model.isHistoryEntryManuallyExpanded(foldedID))
    XCTAssertNotNil(
      firstHistoryResultContainer(
        in: hostingView,
        identifier: "history-result-\(foldedID.uuidString)"
      )
    )
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testScrollingUpThroughLargeFoldedHistoryDoesNotReadCompleteResults() async throws {
    let largeResult = String(
      repeating: "A persisted result should stay out of the scrolling hot path. ",
      count: 2_000
    )
    let entries = (0..<240).map { index in
      HistoryEntry(
        mode: .translate,
        source: "Persisted source \(index)",
        result: largeResult,
        detail: "中文 → English",
        timestamp: "17:58"
      )
    }
    let model = AppModel(entries: entries)
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )

    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return self.firstScroller(
        in: hostingView,
        identifier: "history-scroll-indicator"
      )?.observedScrollView?.documentView?.bounds.height ?? 0 > 10_000
    }
    XCTAssertEqual(
      entries.dropLast().reduce(0) { $0 + $1.resultStorage.fullStringReadCount },
      0,
      "Folded history rows must never bridge complete results during initial layout."
    )
    for entry in entries {
      entry.resultStorage.resetRenderingReadCounts()
    }

    let historyIndicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "history-scroll-indicator")
    )
    let historyScrollView = try XCTUnwrap(historyIndicator.observedScrollView)
    historyIndicator.scroll(toNormalizedValue: 0)
    try await Task.sleep(for: .milliseconds(200))
    hostingView.layoutSubtreeIfNeeded()

    let completeResultReads = entries.reduce(0) {
      $0 + $1.resultStorage.fullStringReadCount
    }
    XCTAssertEqual(
      completeResultReads,
      0,
      "Folded history rows must render from bounded previews, not bridge complete results while scrolling."
    )
    let newestID = UUID()
    model.entries.append(
      HistoryEntry(
        id: newestID,
        mode: .translate,
        source: "Newest source",
        result: "Newest streamed result",
        detail: "中文 → English",
        timestamp: "18:01",
        state: .streaming
      )
    )
    model.requestHistoryFollow(force: true)
    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return self.isScrolledToBottom(historyScrollView)
        && self.firstTextView(
          in: hostingView,
          identifier: "history-result-\(newestID.uuidString)"
        ) != nil
    }
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testFoldedHistoryMaterializesOnlyTheViewportPoolDuringHyperScroll() throws {
    let entries = (0..<1_000).map { index in
      HistoryEntry(
        mode: .translate,
        source: "Persisted source \(index)",
        result: String(
          repeating: "A bounded folded preview remains independent of the complete result. ",
          count: 64
        ),
        detail: "中文 → English",
        timestamp: "18:00",
        reportedSourceCharacterCount: 32,
        reportedResultCharacterCount: 4_096
      )
    }
    let list = VirtualizedFoldedHistoryListNSView()
    list.configure(
      entries: entries,
      onExpand: { _ in },
      onRedo: { _ in },
      onCopyResult: { _ in }
    )

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
    let documentHeight = list.preferredHeight(for: 720)
    list.frame = NSRect(x: 0, y: 0, width: 720, height: documentHeight)
    scrollView.documentView = list
    scrollView.layoutSubtreeIfNeeded()
    list.layoutSubtreeIfNeeded()

    let firstMaterializedRow = try XCTUnwrap(
      list.materializedRowsForTesting.first
    )
    XCTAssertTrue(firstMaterializedRow.isAccessibilityElement())
    XCTAssertTrue(
      firstMaterializedRow.accessibilityIdentifier().hasPrefix("history-entry-")
    )
    let childIdentifiers = (firstMaterializedRow.accessibilityChildren() ?? []).compactMap {
      ($0 as? NSAccessibilityElement)?.accessibilityIdentifier()
        ?? ($0 as? NSView)?.accessibilityIdentifier()
    }
    XCTAssertTrue(childIdentifiers.contains { $0.hasPrefix("history-expand-") })
    XCTAssertTrue(childIdentifiers.contains { $0.hasPrefix("history-collapsed-result-") })
    XCTAssertLessThan(
      list.materializedRowsForTesting.map(\.frame.maxY).max() ?? .greatestFiniteMagnitude,
      5_000,
      "Materialized rows must use viewport-local coordinates instead of the full history offset."
    )

    var maximumMaterializedRows = list.materializedRowCount
    var maximumPooledRows = list.pooledRowCountForTesting
    let maximumOriginY = max(0, documentHeight - scrollView.contentView.bounds.height)
    for originY in stride(from: maximumOriginY, through: 0, by: -480) {
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: originY))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      list.layoutSubtreeIfNeeded()
      maximumMaterializedRows = max(maximumMaterializedRows, list.materializedRowCount)
      maximumPooledRows = max(maximumPooledRows, list.pooledRowCountForTesting)
    }

    XCTAssertGreaterThan(maximumMaterializedRows, 0)
    XCTAssertLessThan(
      maximumMaterializedRows,
      40,
      "A thousand folded records must retain only the three-viewport recycling pool."
    )
    XCTAssertLessThan(
      maximumPooledRows,
      40,
      "Hyper-scroll must reuse the attached row pool instead of rebuilding the AppKit layer tree."
    )
    XCTAssertEqual(
      entries.reduce(0) { $0 + $1.resultStorage.fullStringReadCount },
      0,
      "Viewport recycling must never bridge complete persisted results."
    )
  }

  func testRecycledFoldedHistoryRowDoesNotLeakHoverActions() throws {
    var redoCount = 0
    var copyCount = 0
    let row = HistoryEntryNSView()
    row.frame = NSRect(x: 0, y: 0, width: 720, height: 100)
    row.configure(
      entryID: UUID(),
      mode: .translate,
      metadata: "中文 → English · 18:00",
      preview: "A completed result exposes actions only while its row is hovered.",
      state: .completed,
      onExpand: {},
      onRedo: { redoCount += 1 },
      onCopyResult: { copyCount += 1 }
    )
    let entered = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      )
    )
    row.mouseEntered(with: entered)

    XCTAssertEqual(
      row.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.count,
      2
    )
    XCTAssertEqual(
      (row.accessibilityChildren() ?? []).compactMap { $0 as? NSButton }.count,
      2
    )
    let accessibilityButtons = (row.accessibilityChildren() ?? [])
      .compactMap { $0 as? NSButton }
    XCTAssertTrue(accessibilityButtons.allSatisfy { $0.accessibilityRole() == .button })
    XCTAssertTrue(accessibilityButtons.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty })
    XCTAssertTrue(accessibilityButtons.allSatisfy { !($0.accessibilityHelp() ?? "").isEmpty })
    XCTAssertTrue(
      accessibilityButtons.allSatisfy {
        $0.image?.accessibilityDescription == $0.accessibilityLabel()
      }
    )
    for button in accessibilityButtons {
      XCTAssertTrue(button.accessibilityPerformPress())
    }
    XCTAssertEqual(redoCount, 1)
    XCTAssertEqual(copyCount, 1)

    row.prepareForReuse()

    XCTAssertTrue(row.subviews.compactMap { $0 as? NSButton }.allSatisfy(\.isHidden))
    XCTAssertTrue((row.accessibilityChildren() ?? []).allSatisfy { !($0 is NSButton) })
  }

  func testFoldedHistoryRowMatchesThePencilCardAndActionGeometry() throws {
    let row = HistoryEntryNSView()
    row.configure(
      entryID: UUID(),
      mode: .translate,
      metadata: "中文 → English · 09:14 · 1,846 → 3,214 字",
      preview:
        "Designing distributed systems has never been a matter of simply picking technologies. When we discuss consistency, availability, and partition tolerance, the second line must remain visible.",
      state: .completed,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )

    XCTAssertEqual(row.preferredHeight(for: 804), 96, accuracy: 0.001)
    row.frame = NSRect(x: 0, y: 0, width: 804, height: 96)
    let restingBackground = try XCTUnwrap(row.layer?.backgroundColor)
    XCTAssertTrue(
      try XCTUnwrap(NSColor(cgColor: restingBackground)).isEqual(
        NSColor(
          srgbRed: 250 / 255,
          green: 250 / 255,
          blue: 248 / 255,
          alpha: 1
        )
      )
    )
    let entered = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      )
    )
    row.mouseEntered(with: entered)
    row.layoutSubtreeIfNeeded()

    let hoverBackground = try XCTUnwrap(row.layer?.backgroundColor)
    XCTAssertTrue(
      try XCTUnwrap(NSColor(cgColor: hoverBackground)).isEqual(
        NSColor(
          srgbRed: 241 / 255,
          green: 241 / 255,
          blue: 236 / 255,
          alpha: 1
        )
      )
    )

    let actions = row.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
      .sorted { $0.frame.minY < $1.frame.minY }
    XCTAssertEqual(actions.count, 2)
    XCTAssertEqual(actions[0].frame, NSRect(x: 782, y: 12, width: 12, height: 12))
    XCTAssertEqual(actions[1].frame, NSRect(x: 782, y: 38, width: 12, height: 12))
  }

  func testFoldedHistoryRowAlwaysFadesItsSecondLineAndClipsToTheCard() throws {
    let line = String(repeating: "M", count: 32)
    let row = HistoryEntryNSView()
    row.configure(
      entryID: UUID(),
      mode: .translate,
      metadata: "中文 → English · 09:14",
      preview: "\(line)\n\(line)",
      state: .completed,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )
    row.frame = NSRect(x: 0, y: 0, width: 804, height: 96)
    row.layoutSubtreeIfNeeded()

    let textLayers = try XCTUnwrap(row.layer?.sublayers?.compactMap { $0 as? CATextLayer })
    let previewLayer = try XCTUnwrap(textLayers.first(where: \.isWrapped))
    let fadeLayer = try XCTUnwrap(
      row.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first
    )

    XCTAssertTrue(row.layer?.masksToBounds == true)
    XCTAssertEqual(previewLayer.truncationMode, .none)
    XCTAssertEqual(previewLayer.frame.height, 52, accuracy: 0.001)
    XCTAssertLessThanOrEqual(previewLayer.frame.maxY, row.bounds.maxY)
    XCTAssertFalse(fadeLayer.isHidden)
    XCTAssertEqual(fadeLayer.frame.height, 25, accuracy: 0.001)
    XCTAssertEqual(fadeLayer.frame.maxY, previewLayer.frame.maxY, accuracy: 0.001)
  }

  func testLatestSourcePreviewUsesThePencilClipAndFadeGeometry() {
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourcePreviewHeight, 41)
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourceFadeHeight, 20)
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourceLineLimit, 2)
  }

  func testNativeHistoryEntryKeepsOneRendererAndExactGeometryAcrossEveryState() throws {
    let pool = HistoryResultTextContainerPool.shared
    let initialLeaseCount = pool.leasedContainerCountForTesting
    let entryID = UUID()
    let resultStorage = HistoryResultStorage("A complete result")
    let row = HistoryEntryNSView()
    row.frame = NSRect(x: 0, y: 0, width: 804, height: 96)
    row.configure(
      entryID: entryID,
      mode: .improve,
      metadata: "English · 语气与语法 · 09:14",
      preview: "A complete result",
      state: .completed,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )
    row.layoutSubtreeIfNeeded()
    let sharedHeaderRenderer = row.headerRendererIdentityForTesting

    XCTAssertEqual(row.presentation, .folded)
    XCTAssertEqual(row.preferredHeight(for: 804), 96, accuracy: 0.001)
    XCTAssertEqual(row.headerModeFrameForTesting.minX, 28, accuracy: 0.001)
    XCTAssertEqual(row.headerModeFrameForTesting.minY, 10, accuracy: 0.001)
    XCTAssertEqual(
      row.foldedPreviewFrameForTesting,
      NSRect(x: 10, y: 34, width: 784, height: 52)
    )
    XCTAssertNil(row.resultContainerForTesting)
    XCTAssertEqual(pool.leasedContainerCountForTesting, initialLeaseCount)

    row.configureExpanded(
      entryID: entryID,
      mode: .improve,
      metadata: "English · 语气与语法 · 09:14",
      source: "Original source",
      preview: "A complete result",
      resultStorage: resultStorage,
      presentationRevision: 0,
      latestPresentationDelta: nil,
      state: .completed,
      isLatest: false,
      isLongEntry: false,
      showsSeparator: false,
      onCollapse: {},
      onRedo: {},
      onCopySource: {},
      onCopyResult: {}
    )
    row.frame.size.height = row.preferredHeight(for: 804)
    row.layoutSubtreeIfNeeded()
    let expandedResultContainer = try XCTUnwrap(row.resultContainerForTesting)

    XCTAssertEqual(row.presentation, .expanded(isLatest: false))
    XCTAssertEqual(row.headerRendererIdentityForTesting, sharedHeaderRenderer)
    XCTAssertEqual(
      expandedResultContainer.subviews.first {
        $0.accessibilityIdentifier() == "history-result-\(entryID.uuidString)"
      }?.accessibilityRole(),
      .staticText
    )
    XCTAssertEqual(row.headerModeFrameForTesting.minX, 18, accuracy: 0.001)
    XCTAssertEqual(row.headerModeFrameForTesting.minY, 16, accuracy: 0.001)
    XCTAssertEqual(row.resultFrameForTesting.minY, 40, accuracy: 0.001)
    XCTAssertEqual(
      row.resultFrameForTesting.maxY + 16,
      row.preferredHeight(for: 804),
      accuracy: 0.001
    )
    XCTAssertEqual(pool.leasedContainerCountForTesting, initialLeaseCount + 1)

    row.configureExpanded(
      entryID: entryID,
      mode: .improve,
      metadata: "English · 语气与语法 · 09:14",
      source: "First source line\nSecond source line\nHidden source line",
      preview: "A complete result",
      resultStorage: resultStorage,
      presentationRevision: 0,
      latestPresentationDelta: nil,
      state: .completed,
      isLatest: true,
      isLongEntry: false,
      showsSeparator: false,
      onCollapse: {},
      onRedo: {},
      onCopySource: {},
      onCopyResult: {}
    )
    row.frame.size.height = row.preferredHeight(for: 804)
    row.layoutSubtreeIfNeeded()

    XCTAssertEqual(row.presentation, .expanded(isLatest: true))
    XCTAssertEqual(row.headerRendererIdentityForTesting, sharedHeaderRenderer)
    XCTAssertTrue(row.resultContainerForTesting === expandedResultContainer)
    XCTAssertEqual(row.sourceFrameForTesting, NSRect(x: 0, y: 40, width: 780, height: 41))
    XCTAssertEqual(
      row.subviews.first {
        $0.accessibilityIdentifier() == "history-source-\(entryID.uuidString.lowercased())"
      }?
      .accessibilityRole(),
      .staticText
    )
    XCTAssertEqual(
      row.sourceFadeFrameForTesting, row.sourceFrameForTesting.offsetBy(dx: 0, dy: -40))
    XCTAssertEqual(row.resultFrameForTesting.minY, 89, accuracy: 0.001)
    XCTAssertEqual(
      row.resultFrameForTesting.maxY + 16,
      row.preferredHeight(for: 804),
      accuracy: 0.001
    )

    row.configure(
      entryID: entryID,
      mode: .improve,
      metadata: "English · 语气与语法 · 09:14",
      preview: "A complete result",
      state: .completed,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )
    XCTAssertEqual(row.presentation, .folded)
    XCTAssertNil(row.resultContainerForTesting)
    XCTAssertFalse(row.subviews.contains { $0 is StickyHistoryResultActionNSView })
    XCTAssertFalse(row.subviews.contains { $0 is HistoryEntryHoverTrackingNSView })
    XCTAssertEqual(pool.leasedContainerCountForTesting, initialLeaseCount)
  }

  func testFoldedHistoryAccessibilityFramesFollowAncestorMovement() throws {
    let row = HistoryEntryNSView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 96)
    )
    row.configure(
      entryID: UUID(),
      mode: .translate,
      metadata: "中文 → English · 09:14",
      preview: "Accessibility hit targets must follow the real folded card.",
      state: .completed,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )
    let movingAncestor = NSView(
      frame: NSRect(x: 20, y: 20, width: 320, height: 96)
    )
    movingAncestor.addSubview(row)
    let window = CidaWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(movingAncestor)
    retainedTestWindows.append(window)
    window.orderBack(nil)
    row.layoutSubtreeIfNeeded()

    let expandElement = try XCTUnwrap(
      (row.accessibilityChildren() ?? [])
        .compactMap { $0 as? NSAccessibilityElement }
        .first { $0.accessibilityLabel() == "展开历史记录" }
    )
    let originalFrame = expandElement.accessibilityFrame()
    movingAncestor.setFrameOrigin(NSPoint(x: 20, y: 77))
    let movedFrame = expandElement.accessibilityFrame()

    XCTAssertEqual(abs(movedFrame.minY - originalFrame.minY), 57, accuracy: 0.001)
    XCTAssertEqual(movedFrame.size, originalFrame.size)
    assertTestProcessIsNotFrontmost()
  }

  func testFoldedHistoryAccessibilityExpandElementPerformsItsPressAction() throws {
    var expansionCount = 0
    let row = HistoryEntryNSView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 96)
    )
    row.configure(
      entryID: UUID(),
      mode: .translate,
      metadata: "中文 → English · 09:14",
      preview: "The accessible expand button must invoke the same action as a pointer click.",
      state: .completed,
      onExpand: { expansionCount += 1 },
      onRedo: {},
      onCopyResult: {}
    )

    let expandElement = try XCTUnwrap(
      (row.accessibilityChildren() ?? [])
        .compactMap { $0 as? NSAccessibilityElement }
        .first { $0.accessibilityLabel() == "展开历史记录" }
    )

    XCTAssertTrue(expandElement.accessibilityPerformPress())
    XCTAssertEqual(expansionCount, 1)
  }

  func testFoldedHistoryActionInkStaysInsideThePencilIconBounds() throws {
    let row = HistoryEntryNSView()
    row.configure(
      entryID: UUID(),
      mode: .translate,
      metadata: "中文 → English · 09:14 · 1,846 → 3,214 字",
      preview: "A folded result keeps two preview lines visible.",
      state: .completed,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )
    row.frame = NSRect(x: 0, y: 0, width: 804, height: 96)
    let entered = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      )
    )
    row.mouseEntered(with: entered)
    row.layoutSubtreeIfNeeded()

    let redo = try XCTUnwrap(
      row.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        .min { $0.frame.minY < $1.frame.minY }
    )
    let scale: CGFloat = 2
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(row.bounds.width * scale),
        pixelsHigh: Int(row.bounds.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    bitmap.size = row.bounds.size
    let graphicsContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    row.displayIgnoringOpacity(row.bounds, in: graphicsContext)
    NSGraphicsContext.restoreGraphicsState()

    let searchRect = redo.frame.insetBy(dx: -6, dy: -6).intersection(row.bounds)
    var matchingPixelsOutsideButton = 0
    for pixelY in 0..<bitmap.pixelsHigh {
      for pixelX in 0..<bitmap.pixelsWide {
        let viewPoint = NSPoint(
          x: (CGFloat(pixelX) + 0.5) / scale,
          y: row.bounds.height - (CGFloat(pixelY) + 0.5) / scale
        )
        guard searchRect.contains(viewPoint), !redo.frame.contains(viewPoint) else { continue }
        guard
          let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB)
        else {
          continue
        }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let maximum = channels.max() ?? 1
        let minimum = channels.min() ?? 0
        if maximum > 0.55, maximum < 0.82, maximum - minimum < 0.12 {
          matchingPixelsOutsideButton += 1
        }
      }
    }

    XCTAssertEqual(
      matchingPixelsOutsideButton,
      0,
      "The native action image must be clipped to the same 12 × 12 pt Pencil bounds as the expanded SwiftUI action"
    )
  }

  func testInactiveFoldedHistoryPresentationCannotLeakHoverActions() throws {
    let row = HistoryEntryNSView()
    row.configure(
      entryID: UUID(),
      mode: .translate,
      metadata: "中文 → English · 18:00",
      preview: "Completed result",
      state: .completed,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )
    row.setPresentationActive(false)
    let entered = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      )
    )

    row.mouseEntered(with: entered)

    XCTAssertTrue(row.isHidden)
    XCTAssertTrue(row.subviews.compactMap { $0 as? NSButton }.allSatisfy(\.isHidden))
    XCTAssertEqual((row.accessibilityChildren() ?? []).count, 0)
  }

  func testFoldedHistoryTrackingFollowsExplicitRowBounds() throws {
    let row = HistoryEntryNSView()
    row.frame = NSRect(x: 0, y: 0, width: 720, height: 96)
    row.updateTrackingAreas()

    let trackingArea = try XCTUnwrap(
      row.trackingAreas.first { ($0.owner as AnyObject?) === row }
    )
    XCTAssertEqual(trackingArea.rect, row.bounds)
    XCTAssertTrue(trackingArea.options.contains(.mouseEnteredAndExited))
    XCTAssertTrue(trackingArea.options.contains(.mouseMoved))
    XCTAssertFalse(
      trackingArea.options.contains(.inVisibleRect),
      "Recycled rows need an explicit tracking rect so AppKit cannot retain stale visible regions"
    )
  }

  func testVirtualHistoryResolvesHoverToOnlyOneRecycledRow() {
    let rows = (0..<2).map { index in
      let row = HistoryEntryNSView()
      row.configure(
        entryID: UUID(),
        mode: .translate,
        metadata: "中文 → English · 18:0\(index)",
        preview: "Completed result \(index)",
        state: .completed,
        onExpand: {},
        onRedo: {},
        onCopyResult: {}
      )
      row.setHoverManagedExternally(true)
      return row
    }

    rows[0].setResolvedHoverState(true)
    rows[1].setResolvedHoverState(false)
    XCTAssertEqual(
      rows.flatMap(\.subviews).compactMap { $0 as? NSButton }.filter { !$0.isHidden }.count,
      2
    )

    rows[0].setResolvedHoverState(false)
    rows[1].setResolvedHoverState(true)
    XCTAssertEqual(
      rows.flatMap(\.subviews).compactMap { $0 as? NSButton }.filter { !$0.isHidden }.count,
      2
    )
  }

  func testFoldedHistoryActionMatchesThePencilHoverAndFeedbackTints() throws {
    let normal = NSColor(
      srgbRed: 181 / 255,
      green: 181 / 255,
      blue: 174 / 255,
      alpha: 1
    )
    let hover = NSColor(
      srgbRed: 138 / 255,
      green: 138 / 255,
      blue: 131 / 255,
      alpha: 1
    )
    let accent = NSColor(
      srgbRed: 46 / 255,
      green: 107 / 255,
      blue: 79 / 255,
      alpha: 1
    )
    let button = HistoryEntryActionButton()
    button.normalTintColor = normal
    button.hoverTintColor = hover
    XCTAssertTrue(try XCTUnwrap(button.contentTintColor).isEqual(normal))

    let event = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .mouseMoved,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      )
    )
    button.mouseEntered(with: event)
    XCTAssertTrue(try XCTUnwrap(button.contentTintColor).isEqual(hover))

    button.setFeedbackTint(accent)
    button.mouseExited(with: event)
    XCTAssertTrue(try XCTUnwrap(button.contentTintColor).isEqual(accent))
    button.setFeedbackTint(nil)
    XCTAssertTrue(try XCTUnwrap(button.contentTintColor).isEqual(normal))
  }

  func testExpandedHistoryTrackingUsesTheStableVisibleRegion() throws {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 360))
    let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 1_200))
    let tracker = HistoryEntryHoverTrackingNSView()
    tracker.frame = documentView.bounds
    documentView.addSubview(tracker)
    scrollView.documentView = documentView
    tracker.updateTrackingAreas()

    let trackingArea = try XCTUnwrap(
      scrollView.contentView.trackingAreas.first { ($0.owner as AnyObject?) === tracker }
    )
    XCTAssertTrue(trackingArea.options.contains(.mouseMoved))
    XCTAssertTrue(
      trackingArea.options.contains(.inVisibleRect),
      "A stable expanded row must track every currently visible slice of a long result"
    )

    let longEntryBounds = NSRect(x: 0, y: 0, width: 720, height: 1_200)
    let visibleSlice = NSRect(x: 0, y: 480, width: 720, height: 360)
    XCTAssertTrue(
      HistoryEntryHoverTrackingNSView.containsHoverPoint(
        NSPoint(x: 600, y: 500),
        entryRectInWindow: longEntryBounds,
        viewportRectInWindow: visibleSlice
      ),
      "The current event location must activate a long result through any visible slice"
    )
    XCTAssertTrue(
      HistoryEntryHoverTrackingNSView.containsHoverPoint(
        NSPoint(x: longEntryBounds.maxX + 6, y: 500),
        entryRectInWindow: longEntryBounds,
        viewportRectInWindow: NSRect(x: 0, y: 480, width: 760, height: 360)
      ),
      "Moving onto a trailing 12 pt action must not dismiss the record's hover state."
    )
    XCTAssertFalse(
      HistoryEntryHoverTrackingNSView.containsHoverPoint(
        NSPoint(x: longEntryBounds.maxX + 13, y: 500),
        entryRectInWindow: longEntryBounds,
        viewportRectInWindow: NSRect(x: 0, y: 480, width: 760, height: 360)
      )
    )
    XCTAssertFalse(
      HistoryEntryHoverTrackingNSView.containsHoverPoint(
        NSPoint(x: 600, y: 420),
        entryRectInWindow: longEntryBounds,
        viewportRectInWindow: visibleSlice
      )
    )
  }

  func testExpandedHistoryTrackerRepublishesAfterSwiftUIResetsItsState() async throws {
    let tracker = HistoryEntryHoverTrackingNSView()
    var publishedStates: [Bool] = []
    tracker.onHoverChange = { publishedStates.append($0) }

    tracker.synchronizePublishedHoverState(false)
    tracker.publishHoverStateForTesting(true)
    try await waitUntil(timeout: .seconds(1)) {
      publishedStates == [true]
    }

    tracker.synchronizePublishedHoverState(false)
    tracker.publishHoverStateForTesting(true)
    try await waitUntil(timeout: .seconds(1)) {
      publishedStates == [true, true]
    }

    XCTAssertEqual(
      publishedStates,
      [true, true],
      "The AppKit tracker must republish hover after SwiftUI recreates its state"
    )
  }

  func testExpandedHistoryTrackerAttachesToTheRealHistoryViewport() async throws {
    let model = AppModel(entries: [.interactionTestStickyLongResult])
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )

    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return self.firstHistoryEntryHoverTracker(in: hostingView) != nil
        && self.firstScroller(
          in: hostingView,
          identifier: "history-scroll-indicator"
        )?.observedScrollView != nil
    }
    let tracker = try XCTUnwrap(firstHistoryEntryHoverTracker(in: hostingView))
    let scrollView = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "history-scroll-indicator")?.observedScrollView
    )
    let resultView = try XCTUnwrap(
      firstTextView(
        in: hostingView,
        identifier: "history-result-\(HistoryEntry.interactionTestStickyLongResult.id.uuidString)"
      )
    )
    tracker.updateTrackingAreas()

    XCTAssertTrue(
      tracker.enclosingScrollView === scrollView,
      "The expanded-row tracker must resolve the same outer history scroll view as the Pencil indicator"
    )
    XCTAssertEqual(
      scrollView.contentView.trackingAreas.filter { ($0.owner as AnyObject?) === tracker }.count,
      1,
      "The real SwiftUI hierarchy must install exactly one viewport-owned tracking area"
    )
    XCTAssertTrue(
      window.acceptsMouseMovedEvents,
      "Moving inside an already-entered history viewport must still refresh expanded-row hover"
    )
    XCTAssertTrue(
      tracker.hasLocalMouseMonitorForTesting,
      "A new app instance must observe movement even when the pointer starts inside the viewport"
    )
    XCTAssertFalse(
      tracker.convert(tracker.bounds, to: nil)
        .intersection(scrollView.contentView.convert(scrollView.contentView.bounds, to: nil))
        .isNull
    )
    let resultRectInWindow = resultView.convert(resultView.bounds, to: nil)
    let viewportRectInWindow = scrollView.contentView.convert(
      scrollView.contentView.bounds,
      to: nil
    )
    let visibleResultRect = resultRectInWindow.intersection(viewportRectInWindow)
    let hoverPoint = NSPoint(
      x: viewportRectInWindow.minX + viewportRectInWindow.width * 0.72,
      y: visibleResultRect.minY + 16
    )
    XCTAssertFalse(visibleResultRect.isNull)
    XCTAssertTrue(
      HistoryEntryHoverTrackingNSView.containsHoverPoint(
        hoverPoint,
        entryRectInWindow: tracker.convert(tracker.bounds, to: nil),
        viewportRectInWindow: viewportRectInWindow
      ),
      "The real long-result hover point must be inside the expanded entry's visible slice"
    )
    withExtendedLifetime(window) {}
  }

  func testDetachingFromHistoryDoesNotReconfigureTheSwiftUIDocument() async throws {
    let entries = (0..<1_000).map { index in
      HistoryEntry(
        mode: .translate,
        source: "Persisted source \(index)",
        result: "Persisted result \(index)",
        detail: "中文 → English",
        timestamp: "18:00"
      )
    }
    let model = AppModel(entries: entries)
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )

    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return self.firstVirtualizedHistoryList(in: hostingView) != nil
        && self.firstScroller(
          in: hostingView,
          identifier: "history-scroll-indicator"
        )?.observedScrollView != nil
    }
    let list = try XCTUnwrap(firstVirtualizedHistoryList(in: hostingView))
    let indicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "history-scroll-indicator")
    )
    let scrollView = try XCTUnwrap(indicator.observedScrollView)
    let documentView = try XCTUnwrap(scrollView.documentView)
    let clipView = scrollView.contentView
    let visibleRect = clipView.documentVisibleRect
    let bottomOriginY =
      documentView.isFlipped
      ? max(documentView.bounds.minY, documentView.bounds.maxY - visibleRect.height)
      : documentView.bounds.minY
    clipView.scroll(to: NSPoint(x: visibleRect.minX, y: bottomOriginY))
    scrollView.reflectScrolledClipView(clipView)
    try await Task.sleep(for: .milliseconds(100))
    hostingView.layoutSubtreeIfNeeded()

    let settledConfigurationCount = list.configurationCount
    let upwardOriginY = bottomOriginY + (documentView.isFlipped ? -32 : 32)
    clipView.scroll(to: NSPoint(x: visibleRect.minX, y: upwardOriginY))
    scrollView.reflectScrolledClipView(clipView)
    NotificationCenter.default.post(
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )
    try await Task.sleep(for: .milliseconds(100))
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(scrollView.accessibilityValue() as? String, "detached")
    XCTAssertEqual(
      list.configurationCount,
      settledConfigurationCount,
      "Scroll pin state must remain native instead of invalidating the SwiftUI history tree."
    )
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testSubmittingNewSessionEntryPreservesTheStableHistoryTail() async throws {
    let entries = (0..<1_000).map { index in
      HistoryEntry(
        mode: .translate,
        source: "Persisted source \(index)",
        result: "Persisted result \(index)",
        detail: "中文 → English",
        timestamp: "18:00"
      )
    }
    let model = AppModel(entries: entries, service: BackendPauseStreamingService())
    let previousLatestID = try XCTUnwrap(entries.last?.id)
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )

    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return self.firstVirtualizedHistoryList(in: hostingView) != nil
    }
    let persistedList = try XCTUnwrap(firstVirtualizedHistoryList(in: hostingView))
    let settledMeasurementCount = persistedList.rowMeasurementCount
    let materializedRows = Set(
      persistedList.materializedRowsForTesting.map(ObjectIdentifier.init)
    )
    let document = String(repeating: "A", count: 1_000_000)
    model.stageInputDocument(
      document,
      utf16Count: document.utf16.count,
      hasNonWhitespace: true
    )
    XCTAssertTrue(model.submit())

    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.entries.count == entries.count + 1
    }

    XCTAssertEqual(
      persistedList.rowMeasurementCount - settledMeasurementCount,
      0,
      "The stable two-entry tail must fold in place without rebuilding the virtual page."
    )
    let survivingRows = persistedList.materializedRowsForTesting.map(ObjectIdentifier.init)
    XCTAssertTrue(
      survivingRows.contains(where: materializedRows.contains),
      "Append-only history updates must preserve the existing viewport row pool."
    )
    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return self.firstTextView(
        in: hostingView,
        identifier: "history-result-\(previousLatestID.uuidString)"
      ) == nil
    }
    model.cancelProcessing()
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testFirstTwoSubmissionsUsePrewarmedResultContainersWithoutHiddenLayoutSlots()
    async throws
  {
    let containerPool = HistoryResultTextContainerPool.shared
    containerPool.prewarm()
    let prewarmedContainers = containerPool.availableContainerIdentifiersForTesting
    XCTAssertGreaterThanOrEqual(
      prewarmedContainers.count,
      HistoryResultTextContainerPool.defaultReserveCount
    )

    let model = AppModel(entries: [])
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )

    hostingView.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      allHistoryResultContainers(in: hostingView).count,
      0,
      "Prewarming must not install transparent result views in the history layout."
    )

    let historyScrollView = try XCTUnwrap(
      allScrollViews(in: hostingView).first {
        $0.accessibilityIdentifier() == "history-scroll-view"
      }
    )

    for index in 0..<2 {
      let entry = HistoryEntry(
        mode: .translate,
        source: String(repeating: "S", count: 1_000_000),
        result: "",
        detail: "中文 → English",
        timestamp: "18:00",
        reportedSourceCharacterCount: 1_000_000,
        state: .streaming
      )
      if let previousEntry = model.entries.last {
        previousEntry.state = .completed
      }
      model.entries.append(entry)

      let identifier = "history-result-\(entry.id.uuidString)"
      try await waitUntil(timeout: .seconds(2)) {
        hostingView.layoutSubtreeIfNeeded()
        return self.firstHistoryResultContainer(
          in: hostingView,
          identifier: identifier
        ) != nil
      }
      let container = try XCTUnwrap(
        firstHistoryResultContainer(in: hostingView, identifier: identifier)
      )
      XCTAssertTrue(
        prewarmedContainers.contains(ObjectIdentifier(container)),
        "Submission \(index) must lease a native result container initialized before submit."
      )
      let containerFrame = container.convert(container.bounds, to: nil)
      let viewportFrame = historyScrollView.contentView.convert(
        historyScrollView.contentView.bounds,
        to: nil
      )
      XCTAssertGreaterThan(
        containerFrame.intersection(viewportFrame).height,
        20,
        "The submitted result must remain inside the visible history viewport."
      )
      XCTAssertGreaterThanOrEqual(
        minimumAncestorAlpha(from: container),
        0.99,
        "Pooled result views must never depend on transparent layout placeholders."
      )
    }

    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return self.allHistoryResultContainers(in: hostingView).count == 1
    }
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testLongResultUsesIncrementalNaturalTextLayoutWithoutNestedScrolling() {
    let resultView = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: HistoryResultTextContainer.minimumHeight)
    )
    let initialResult = String(repeating: "A long streamed result keeps growing. ", count: 500)
    resultView.replaceText(initialResult)
    let textStorage = resultView.textView.textStorage

    let height = resultView.updateDocumentLayout()
    resultView.append("Exact suffix")
    let updatedHeight = resultView.updateDocumentLayout()

    XCTAssertNotNil(resultView.textView.layoutManager)
    XCTAssertTrue(textStorage === resultView.textView.textStorage)
    XCTAssertEqual(resultView.renderedString, initialResult + "Exact suffix")
    XCTAssertFalse(resultView.selectionTextIsMaterializedForTesting)
    resultView.activateSelectionForTesting()
    XCTAssertEqual(resultView.textView.string, initialResult + "Exact suffix")
    XCTAssertGreaterThan(height, 280)
    XCTAssertGreaterThanOrEqual(updatedHeight, height)
    XCTAssertEqual(updatedHeight, resultView.naturalTextHeight)
    XCTAssertEqual(resultView.textView.frame.height, resultView.naturalTextHeight)
    XCTAssertNil(resultView.textView.enclosingScrollView)
    XCTAssertFalse(resultView.subviews.contains { $0 is NSScrollView })
    XCTAssertFalse(resultView.textView.isContinuousSpellCheckingEnabled)
    XCTAssertFalse(resultView.textView.isGrammarCheckingEnabled)
    XCTAssertFalse(resultView.textView.isAutomaticSpellingCorrectionEnabled)
    XCTAssertFalse(resultView.textView.isAutomaticTextReplacementEnabled)
    XCTAssertFalse(resultView.textView.isAutomaticQuoteSubstitutionEnabled)
    XCTAssertFalse(resultView.textView.isAutomaticDashSubstitutionEnabled)
    XCTAssertFalse(resultView.textView.isAutomaticLinkDetectionEnabled)
    XCTAssertFalse(resultView.textView.isAutomaticDataDetectionEnabled)
    XCTAssertFalse(resultView.textView.isAutomaticTextCompletionEnabled)
    XCTAssertEqual(resultView.textView.enabledTextCheckingTypes, 0)
  }

  func testLongResultSharesTheOuterHistoryScrollRegion() {
    let historyScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
    let historyDocument = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 5_000))
    historyScrollView.documentView = historyDocument
    let resultView = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: HistoryResultTextContainer.minimumHeight)
    )
    historyDocument.addSubview(resultView)
    resultView.replaceText(String(repeating: "Long streamed result. ", count: 500))

    XCTAssertGreaterThan(resultView.updateDocumentLayout(), 280)
    XCTAssertTrue(resultView.textView.enclosingScrollView === historyScrollView)
    XCTAssertFalse(resultView.subviews.contains { $0 is NSScrollView })
  }

  func testHighFrequencyResultUpdatesCoalesceNaturalHeightLayout() {
    let entryID = UUID()
    let storage = HistoryResultStorage("")
    let resultView = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: HistoryResultTextContainer.minimumHeight)
    )
    let coordinator = HistoryResultTextCoordinator()

    coordinator.replaceText(
      storage.string,
      entryID: entryID,
      presentationRevision: 0,
      isStreaming: true,
      in: resultView
    )
    for revision in 1...200 {
      storage.append("smooth")
      coordinator.updateText(
        storage,
        entryID: entryID,
        presentationRevision: revision,
        latestPresentationDelta: "smooth",
        isStreaming: true,
        in: resultView
      )
      coordinator.scheduleLayout(of: resultView)
    }
    let layoutDeadline = Date().addingTimeInterval(5)
    while resultView.documentLayoutCount == 0, Date() < layoutDeadline {
      RunLoop.current.run(until: min(layoutDeadline, Date().addingTimeInterval(0.02)))
    }

    XCTAssertEqual(resultView.renderedString, String(repeating: "smooth", count: 200))
    XCTAssertFalse(resultView.selectionTextIsMaterializedForTesting)
    XCTAssertEqual(resultView.documentLayoutCount, 1)
    XCTAssertGreaterThan(resultView.naturalTextHeight, HistoryResultTextContainer.minimumHeight)
    XCTAssertEqual(resultView.intrinsicContentSize.height, resultView.naturalTextHeight)
  }

  func testStreamingDeltaUpdatesNativeResultWithoutReconfiguringFoldedHistory() async throws {
    let persistedEntries = (0..<1_000).map { index in
      HistoryEntry(
        mode: .translate,
        source: "Persisted source \(index)",
        result: "Persisted result \(index)",
        detail: "中文 → English",
        timestamp: "18:00"
      )
    }
    let streamingEntry = HistoryEntry(
      mode: .translate,
      source: "Submitted source",
      result: "",
      detail: "中文 → English",
      timestamp: "18:01",
      state: .streaming
    )
    let model = AppModel(entries: persistedEntries + [streamingEntry])
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )

    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return self.firstVirtualizedHistoryList(in: hostingView) != nil
        && self.firstTextView(
          in: hostingView,
          identifier: "history-result-\(streamingEntry.id.uuidString)"
        ) != nil
    }
    let persistedList = try XCTUnwrap(firstVirtualizedHistoryList(in: hostingView))
    let resultTextView = try XCTUnwrap(
      firstTextView(
        in: hostingView,
        identifier: "history-result-\(streamingEntry.id.uuidString)"
      )
    )
    let resultContainer = try XCTUnwrap(
      resultTextView.superview as? HistoryResultTextContainer
    )
    let settledConfigurationCount = persistedList.configurationCount

    streamingEntry.appendPresentationDelta("Native streaming delta")
    try await waitUntil(timeout: .seconds(1)) {
      resultContainer.renderedString == "Native streaming delta"
    }

    XCTAssertEqual(persistedList.configurationCount, settledConfigurationCount)
    XCTAssertEqual(resultContainer.renderedString, streamingEntry.result)
    XCTAssertFalse(resultContainer.selectionTextIsMaterializedForTesting)
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testLongStreamingEntryMountsWaitingResultImmediatelyAndPreservesEarlyDeltas() async throws {
    let entry = HistoryEntry(
      mode: .translate,
      source: "Virtual million-character source",
      result: "",
      detail: "中文 → English",
      timestamp: "18:01",
      reportedSourceCharacterCount: 1_000_000,
      state: .streaming
    )
    let model = AppModel(entries: [entry])
    let hostingView = NSHostingView(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false)
    )
    hostingView.frame = NSRect(x: 0, y: 0, width: 860, height: 640)
    let window = CidaWindow(
      contentRect: hostingView.frame,
      styleMask: [.borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    retainedTestWindows.append(window)
    hostingView.layoutSubtreeIfNeeded()

    let identifier = "history-result-\(entry.id.uuidString)"
    let initialResultTextView = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: identifier),
      "An accepted long-document submission must expose its empty waiting result immediately."
    )
    let initialResultContainer = try XCTUnwrap(
      initialResultTextView.superview as? HistoryResultTextContainer
    )
    XCTAssertEqual(initialResultContainer.renderedString, "")
    XCTAssertTrue(initialResultContainer.streamingCaretIsVisible)

    let earlyDelta = "A stream delta received immediately after the result renderer is mounted."
    entry.appendPresentationDelta(earlyDelta)
    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      guard
        let textView = self.firstTextView(in: hostingView, identifier: identifier),
        let container = textView.superview as? HistoryResultTextContainer
      else {
        return false
      }
      return container.renderedString == earlyDelta
    }

    let resultTextView = try XCTUnwrap(firstTextView(in: hostingView, identifier: identifier))
    let resultContainer = try XCTUnwrap(resultTextView.superview as? HistoryResultTextContainer)
    XCTAssertEqual(resultContainer.renderedString, earlyDelta)
    XCTAssertFalse(resultContainer.selectionTextIsMaterializedForTesting)
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testStreamingResultPublishesItsNativeHeightWithoutSwiftUIStateFeedback() async throws {
    let entry = HistoryEntry(
      mode: .translate,
      source: "Submitted source",
      result: "",
      detail: "中文 → English",
      timestamp: "18:01",
      state: .streaming
    )
    let model = AppModel(entries: [entry])
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let resultTextView = try XCTUnwrap(
      firstTextView(
        in: hostingView,
        identifier: "history-result-\(entry.id.uuidString)"
      )
    )
    let resultContainer = try XCTUnwrap(
      resultTextView.superview as? HistoryResultTextContainer
    )
    let initialHeight = resultContainer.frame.height

    entry.appendPresentationDelta(
      (1...24).map { "Streamed result line \($0)" }.joined(separator: "\n")
    )
    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return resultContainer.naturalTextHeight > 300
        && abs(resultContainer.frame.height - resultContainer.naturalTextHeight) <= 0.5
    }

    XCTAssertGreaterThan(resultContainer.frame.height, initialHeight)
    XCTAssertEqual(
      resultContainer.frame.height,
      resultContainer.naturalTextHeight,
      accuracy: 0.5
    )
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testNaturalResultRelayoutsWhenTheHistoryWidthChanges() async throws {
    let entryID = UUID()
    let storage = HistoryResultStorage(
      String(repeating: "A translated paragraph must reflow with its history surface. ", count: 80)
    )
    let resultView = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: HistoryResultTextContainer.minimumHeight)
    )
    let coordinator = HistoryResultTextCoordinator()
    resultView.onWidthChange = { [weak resultView, weak coordinator] in
      guard let resultView, let coordinator else { return }
      coordinator.scheduleLayout(of: resultView)
    }
    coordinator.replaceText(
      storage.string,
      entryID: entryID,
      presentationRevision: 0,
      isStreaming: false,
      in: resultView
    )
    coordinator.scheduleLayout(of: resultView)
    try await waitUntil(timeout: .seconds(1)) {
      resultView.naturalTextHeight > HistoryResultTextContainer.minimumHeight
        && abs(resultView.textView.frame.height - resultView.naturalTextHeight) <= 0.5
    }
    let wideHeight = resultView.naturalTextHeight

    resultView.setFrameSize(
      NSSize(width: 320, height: HistoryResultTextContainer.minimumHeight)
    )
    try await waitUntil(timeout: .seconds(1)) {
      resultView.naturalTextHeight > wideHeight
        && abs(resultView.textView.frame.height - resultView.naturalTextHeight) <= 0.5
    }

    XCTAssertGreaterThan(resultView.naturalTextHeight, wideHeight)
    XCTAssertEqual(resultView.textView.frame.height, resultView.naturalTextHeight)
    XCTAssertNil(resultView.textView.enclosingScrollView)
  }

  func testStreamingResultDefersSelectionUntilCompletion() {
    let resultView = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: HistoryResultTextContainer.minimumHeight)
    )
    resultView.replaceText("Selectable completed result")

    XCTAssertFalse(resultView.selectionTextViewIsMaterializedForTesting)
    XCTAssertFalse(resultView.textView.isSelectable)
    XCTAssertTrue(resultView.selectionTextViewIsMaterializedForTesting)
    resultView.setStreaming(true)
    XCTAssertFalse(resultView.textView.isSelectable)
    resultView.setStreaming(false)
    XCTAssertFalse(resultView.textView.isSelectable)
    XCTAssertFalse(resultView.selectionTextIsMaterializedForTesting)
    XCTAssertEqual(resultView.renderedString, "Selectable completed result")

    resultView.activateSelectionForTesting()
    XCTAssertTrue(resultView.selectionTextIsMaterializedForTesting)
    XCTAssertTrue(resultView.textView.isSelectable)
    XCTAssertEqual(resultView.textView.string, "Selectable completed result")
  }

  func testStreamingCompletionKeepsTheResultHeightStructurallyStable() {
    let resultView = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 320, height: HistoryResultTextContainer.minimumHeight)
    )
    resultView.replaceText(String(repeating: "Stable streamed line. ", count: 60))
    resultView.setStreaming(true)
    let streamingHeight = resultView.updateDocumentLayout()

    resultView.setStreaming(false)
    let completedHeight = resultView.updateDocumentLayout()

    XCTAssertEqual(completedHeight, streamingHeight, accuracy: 0.5)
    XCTAssertFalse(resultView.selectionTextIsMaterializedForTesting)
  }

  func testStreamingResultActuallyPaintsItsVisibleGlyphs() throws {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    let resultView = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 320, height: HistoryResultTextContainer.minimumHeight)
    )
    documentView.addSubview(resultView)
    scrollView.documentView = documentView
    let window = CidaWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    retainedTestWindows.append(window)
    window.orderBack(nil)

    resultView.replaceText("STREAMING_VISIBLE_GLYPHS")
    resultView.setStreaming(true)
    let height = resultView.updateDocumentLayout()
    resultView.setFrameSize(NSSize(width: 320, height: height))
    window.contentView?.layoutSubtreeIfNeeded()
    window.contentView?.displayIfNeeded()

    let scale: CGFloat = 2
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(resultView.bounds.width * scale),
        pixelsHigh: Int(resultView.bounds.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    bitmap.size = resultView.bounds.size
    let graphicsContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    resultView.displayIgnoringOpacity(resultView.bounds, in: graphicsContext)
    NSGraphicsContext.restoreGraphicsState()

    var neutralDarkPixels = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let maximum = channels.max() ?? 1
        let minimum = channels.min() ?? 0
        if maximum < 0.42, maximum - minimum < 0.08, color.alphaComponent > 0.5 {
          neutralDarkPixels += 1
        }
      }
    }

    XCTAssertGreaterThan(
      neutralDarkPixels,
      100,
      "A streaming result must paint text, not expose only its accessibility value and caret; visible fragments: \(resultView.streamingVisibleFragmentFramesForTesting)"
    )
  }

  func testStreamingResultPaintsNewlyVisibleGlyphsAfterScrolling() throws {
    let viewportSize = NSSize(width: 320, height: 120)
    let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: viewportSize))
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    let documentView = NSView(frame: NSRect(origin: .zero, size: viewportSize))
    let resultView = HistoryResultTextContainer(
      frame: NSRect(origin: .zero, size: viewportSize)
    )
    documentView.addSubview(resultView)
    scrollView.documentView = documentView
    let window = CidaWindow(
      contentRect: scrollView.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    retainedTestWindows.append(window)
    window.orderBack(nil)

    resultView.replaceText(
      (0..<200).map { "SCROLLED_GLYPH_LINE_\($0)" }.joined(separator: "\n")
    )
    resultView.setStreaming(true)
    let height = resultView.updateDocumentLayout()
    resultView.setFrameSize(NSSize(width: viewportSize.width, height: height))
    documentView.setFrameSize(NSSize(width: viewportSize.width, height: height))
    window.contentView?.layoutSubtreeIfNeeded()

    let scrollY = floor(max(0, (height - viewportSize.height) / 2))
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    for subview in resultView.subviews where !subview.isHidden {
      subview.needsDisplay = true
    }
    window.contentView?.displayIfNeeded()

    let visibleResultRect = resultView.visibleRect
    let bitmap = try XCTUnwrap(
      scrollView.contentView.bitmapImageRepForCachingDisplay(
        in: scrollView.contentView.bounds
      )
    )
    scrollView.contentView.cacheDisplay(
      in: scrollView.contentView.bounds,
      to: bitmap
    )

    var neutralDarkPixels = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let maximum = channels.max() ?? 1
        let minimum = channels.min() ?? 0
        if maximum < 0.42, maximum - minimum < 0.08, color.alphaComponent > 0.5 {
          neutralDarkPixels += 1
        }
      }
    }

    XCTAssertGreaterThan(visibleResultRect.minY, 100)
    XCTAssertGreaterThan(
      neutralDarkPixels,
      100,
      "Scrolling must paint the newly visible TextKit fragments, not a blank viewport"
    )
    XCTAssertTrue(
      resultView.streamingVisibleFragmentFramesForTesting.contains {
        $0.intersects(visibleResultRect)
      },
      "The renderer must enumerate fragments inside the scrolled viewport"
    )
  }

  func testStreamingResultGrowsInsideReservedTextViewCapacity() {
    let resultView = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: HistoryResultTextContainer.minimumHeight)
    )
    resultView.setStreaming(true)
    resultView.replaceText(String(repeating: "Streaming line. ", count: 40))
    let initialNaturalHeight = resultView.updateDocumentLayout()
    let initialAllocatedHeight = resultView.textView.frame.height

    resultView.append(String(repeating: "More streamed text. ", count: 40), isStreaming: true)
    let updatedNaturalHeight = resultView.updateDocumentLayout()

    XCTAssertGreaterThan(updatedNaturalHeight, initialNaturalHeight)
    XCTAssertEqual(resultView.textView.frame.height, initialAllocatedHeight)
    XCTAssertGreaterThan(resultView.textView.frame.height, updatedNaturalHeight)

    resultView.setStreaming(false)
    let completedHeight = resultView.updateDocumentLayout()
    XCTAssertEqual(completedHeight, updatedNaturalHeight)
    XCTAssertEqual(resultView.textView.frame.height, initialAllocatedHeight)
    XCTAssertGreaterThan(resultView.textView.frame.height, completedHeight)
  }

  func testCoalescedStreamingRevisionsAppendOnlyTheMissingSuffix() {
    let entryID = UUID()
    let storage = HistoryResultStorage("Initial")
    let resultView = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: HistoryResultTextContainer.minimumHeight)
    )
    let coordinator = HistoryResultTextCoordinator()

    coordinator.replaceText(
      storage.string,
      entryID: entryID,
      presentationRevision: 0,
      isStreaming: true,
      in: resultView
    )
    storage.append(" first")
    storage.append(" second")
    coordinator.updateText(
      storage,
      entryID: entryID,
      presentationRevision: 2,
      latestPresentationDelta: " second",
      isStreaming: true,
      in: resultView
    )

    XCTAssertEqual(resultView.renderedString, "Initial first second")
    XCTAssertEqual(resultView.fullReplacementCount, 1)
    XCTAssertEqual(resultView.incrementalAppendCount, 1)
  }

  func testStreamingResultUsesAnInlineCaretAndRemovesItOnCompletion() throws {
    let resultView = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: HistoryResultTextContainer.minimumHeight)
    )
    let window = CidaWindow(
      contentRect: resultView.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = resultView
    retainedTestWindows.append(window)
    resultView.replaceText("")
    resultView.setStreaming(true)
    _ = resultView.updateDocumentLayout()
    resultView.updateStreamingCaretFrame()

    XCTAssertTrue(resultView.streamingCaretIsVisible)
    XCTAssertEqual(resultView.streamingCaretFrame.width, 2)
    XCTAssertEqual(resultView.streamingCaretFrame.height, 20)

    resultView.append("平滑输出", isStreaming: true)
    XCTAssertEqual(resultView.glyphRevealLayerCountForTesting, 1)
    let revealAnimation = try XCTUnwrap(resultView.glyphRevealAnimationForTesting)
    XCTAssertEqual(revealAnimation.duration, 0.12, accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(revealAnimation.fromValue as? NSNumber).doubleValue,
      0.18,
      accuracy: 0.001
    )
    _ = resultView.updateDocumentLayout()
    resultView.updateStreamingCaretFrame()
    XCTAssertGreaterThan(resultView.streamingCaretFrame.minX, 0)

    resultView.setStreaming(false)
    XCTAssertFalse(resultView.streamingCaretIsVisible)
    XCTAssertEqual(resultView.glyphRevealLayerCountForTesting, 0)
  }

  func testGlyphFadeMatchesThePencilOneHundredTwentyMillisecondEaseOut() {
    let initial = StreamGlyphFadeAnimation.style(elapsed: 0)
    let midpoint = StreamGlyphFadeAnimation.style(elapsed: 0.06)
    let complete = StreamGlyphFadeAnimation.style(elapsed: 0.12)

    XCTAssertEqual(initial.opacity, 0.82, accuracy: 0.001)
    XCTAssertEqual(initial.blurRadius, 2, accuracy: 0.001)
    XCTAssertGreaterThan(midpoint.opacity, initial.opacity)
    XCTAssertEqual(midpoint.opacity, 0.9775, accuracy: 0.001)
    XCTAssertEqual(midpoint.blurRadius, 0.25, accuracy: 0.001)
    XCTAssertEqual(complete.opacity, 1, accuracy: 0.001)
    XCTAssertEqual(complete.blurRadius, 0, accuracy: 0.001)
  }

  func testStreamingLineGrowthReusesTheSingleCompositorTailReveal() throws {
    let resultView = HistoryResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 320, height: HistoryResultTextContainer.minimumHeight)
    )
    let window = CidaWindow(
      contentRect: resultView.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = resultView
    retainedTestWindows.append(window)
    resultView.replaceText("")
    resultView.setStreaming(true)
    _ = resultView.updateDocumentLayout()

    resultView.append("First line grows.\nSecond line grows.", isStreaming: true)
    let expandedHeight = resultView.updateDocumentLayout()

    XCTAssertGreaterThan(expandedHeight, HistoryResultTextContainer.minimumHeight)
    XCTAssertEqual(resultView.glyphRevealLayerCountForTesting, 1)
    XCTAssertEqual(resultView.glyphRevealAnimationForTesting?.duration, 0.12)
    let blurAnimation = try XCTUnwrap(resultView.glyphRevealBlurAnimationForTesting)
    XCTAssertEqual(blurAnimation.duration, 0.12)
    XCTAssertEqual(
      try XCTUnwrap(blurAnimation.fromValue as? NSNumber).doubleValue,
      2,
      accuracy: 0.001
    )
    XCTAssertEqual(
      try XCTUnwrap(blurAnimation.toValue as? NSNumber).doubleValue,
      0,
      accuracy: 0.001
    )
    XCTAssertEqual(resultView.glyphRevealBlurRadiusForTesting, 0, accuracy: 0.001)
  }

  func testRecordActionsRequireHoverAndACompletedOrTerminalEntry() {
    XCTAssertFalse(
      HistoryEntryActionPolicy.showsActions(isHovering: false, state: .completed)
    )
    XCTAssertFalse(
      HistoryEntryActionPolicy.showsActions(isHovering: true, state: .streaming)
    )
    XCTAssertTrue(
      HistoryEntryActionPolicy.showsActions(isHovering: true, state: .completed)
    )
    XCTAssertTrue(
      HistoryEntryActionPolicy.showsActions(isHovering: true, state: .cancelled)
    )
    XCTAssertTrue(
      HistoryEntryActionPolicy.showsActions(isHovering: true, state: .failed)
    )
    XCTAssertEqual(
      HistoryEntryActionPolicy.presentationState(
        isHovering: false,
        state: .completed,
        copiedAction: .copyResult
      ),
      .copied(.copyResult)
    )
  }

  func testLongResultActionSticksToTheVisibleIntersectionAndStaysInsideItsBlock() {
    XCTAssertEqual(
      StickyHistoryResultActionNSView.actionOriginY(
        bounds: NSRect(x: 0, y: 0, width: 320, height: 208),
        visibleRect: NSRect(x: 0, y: 80, width: 320, height: 120),
        isLongEntry: false,
      ),
      4,
      accuracy: 0.001
    )
    XCTAssertEqual(
      StickyHistoryResultActionNSView.actionOriginY(
        bounds: NSRect(x: 0, y: 0, width: 320, height: 208),
        visibleRect: NSRect(x: 0, y: 80, width: 320, height: 120),
        isLongEntry: true,
      ),
      84,
      accuracy: 0.001
    )
    XCTAssertEqual(
      StickyHistoryResultActionNSView.actionOriginY(
        bounds: NSRect(x: 0, y: 0, width: 320, height: 208),
        visibleRect: NSRect(x: 0, y: 500, width: 320, height: 120),
        isLongEntry: true,
      ),
      192,
      accuracy: 0.001
    )

    let viewportSize = NSSize(width: 320, height: 120)
    let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: viewportSize))
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    let documentView = FlippedTestDocumentView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 600)
    )
    let actionView = StickyHistoryResultActionNSView(
      frame: NSRect(x: 0, y: 100, width: 320, height: 400)
    )
    var actionInvocationCount = 0
    actionView.configure(
      identifier: "sticky-action-test",
      isLongEntry: true,
      isVisible: true,
      isCopied: false,
      action: { actionInvocationCount += 1 }
    )
    documentView.addSubview(actionView)
    scrollView.documentView = documentView
    let window = CidaWindow(
      contentRect: scrollView.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    retainedTestWindows.append(window)
    window.orderBack(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    actionView.layoutSubtreeIfNeeded()

    guard
      let actionButton = actionView.subviews.compactMap({
        $0 as? HistoryEntryActionButton
      }).first
    else {
      XCTFail("The sticky result view must expose its native action button.")
      return
    }
    XCTAssertNotNil(actionButton.iconImage)
    XCTAssertEqual(actionButton.accessibilityRole(), .button)
    XCTAssertEqual(actionButton.frame.minY, 4, accuracy: 0.001)
    let expectedAccessibilityFrame = window.convertToScreen(
      actionView.convert(actionButton.frame, to: nil)
    )
    XCTAssertEqual(
      actionButton.accessibilityFrame(),
      expectedAccessibilityFrame,
      "The AX click target must use the button's live AppKit frame."
    )
    XCTAssertTrue(actionView.hasLocalMouseDownMonitorForTesting)
    let actionPoint = NSPoint(x: actionButton.frame.midX, y: actionButton.frame.midY)
    XCTAssertTrue(actionView.hitTest(actionPoint) === actionView)
    guard
      let clickEvent = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: actionView.convert(actionPoint, to: nil),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
      )
    else {
      XCTFail("The sticky result action must accept a native pointer event.")
      return
    }
    NSApp.sendEvent(clickEvent)
    XCTAssertEqual(actionInvocationCount, 1)
    XCTAssertEqual(actionButton.accessibilityValue() as? String, "copied")
    actionView.configure(
      identifier: "sticky-action-test",
      isLongEntry: true,
      isVisible: false,
      isCopied: true,
      action: {}
    )
    XCTAssertFalse(actionButton.isHidden)
    XCTAssertEqual(actionButton.accessibilityRole(), .button)
    XCTAssertEqual(actionButton.accessibilityValue() as? String, "copied")

    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 180))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    actionView.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      actionButton.frame.minY,
      84,
      accuracy: 0.001,
      "The real AppKit action must track the outer clip view without a SwiftUI update."
    )
    actionView.configure(
      identifier: "sticky-action-test",
      isLongEntry: true,
      isVisible: false,
      isCopied: false,
      action: {}
    )
    XCTAssertTrue(actionButton.isHidden)
    XCTAssertEqual(actionButton.accessibilityValue() as? String, "idle")
    assertTestProcessIsNotFrontmost()
  }

  func testLatestResultCopyShortcutDefersToEditableTextAndSelectedResultText() throws {
    let commandC = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: "c",
        charactersIgnoringModifiers: "c",
        isARepeat: false,
        keyCode: 8
      )
    )
    let commandShiftC = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command, .shift],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: "C",
        charactersIgnoringModifiers: "c",
        isARepeat: false,
        keyCode: 8
      )
    )
    XCTAssertTrue(CopyShortcutRouting.isLatestResultShortcut(commandC))
    XCTAssertFalse(CopyShortcutRouting.isLatestResultShortcut(commandShiftC))

    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
    let window = CidaWindow(
      contentRect: textView.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = textView
    XCTAssertTrue(window.makeFirstResponder(textView))

    textView.isEditable = true
    XCTAssertTrue(CopyShortcutRouting.nativeTextResponderOwnsCopy(window: window))

    textView.isEditable = false
    textView.string = "Selectable result"
    textView.setSelectedRange(NSRange(location: 0, length: 10))
    XCTAssertTrue(CopyShortcutRouting.nativeTextResponderOwnsCopy(window: window))

    textView.setSelectedRange(NSRange(location: 0, length: 0))
    XCTAssertFalse(CopyShortcutRouting.nativeTextResponderOwnsCopy(window: window))
    assertTestProcessIsNotFrontmost()
  }

  func testHistoryPausesAutoFollowWhileTheUserReadsEarlierContent() throws {
    let entries = (0..<24).map { index in
      HistoryEntry(
        mode: .translate,
        source: "Source \(index)",
        result: "Result \(index)\nwith another line",
        detail: "中文 → English",
        timestamp: "18:00"
      )
    }
    let model = AppModel(entries: entries)
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let scrollView = try XCTUnwrap(
      allScrollViews(in: hostingView).max { lhs, rhs in
        lhs.frame.height < rhs.frame.height
      }
    )

    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    NotificationCenter.default.post(
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    model.setGenerationStateForTesting(.revealing(entryID: model.entries.last!.id))
    model.entries[model.entries.count - 1].state = .streaming
    model.entries[model.entries.count - 1].appendPresentationDelta("\nNew streamed line")
    model.requestHistoryFollow(force: false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    XCTAssertFalse(isScrolledToBottom(scrollView), scrollDescription(scrollView))

    let documentView = try XCTUnwrap(scrollView.documentView)
    scrollView.contentView.scroll(
      to: NSPoint(x: 0, y: max(0, documentView.bounds.maxY - scrollView.contentView.bounds.height))
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)
    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveScrollNotification,
      object: scrollView
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    model.entries[model.entries.count - 1].appendPresentationDelta("\nAnother streamed line")
    model.requestHistoryFollow(force: false)
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    XCTAssertTrue(isScrolledToBottom(scrollView), scrollDescription(scrollView))
  }

  func testAPIKeyIsBackedByAnEditableSecureFieldWithoutViewReplacement() {
    var apiKey = "sk-existing-key"
    let binding = Binding(
      get: { apiKey },
      set: { apiKey = $0 }
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MaskedAPIKeyField(apiKey: binding)
        .frame(width: 159, height: 27),
      size: CGSize(width: 159, height: 27)
    )

    let editor = firstTextField(in: hostingView, identifier: "settings-api-key-editor")

    XCTAssertNotNil(editor)
    XCTAssertTrue(editor?.isEditable == true)
    XCTAssertTrue(editor?.isSelectable == true)

    editor?.stringValue = "sk-updated-key"
    editor?.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: editor)
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    XCTAssertEqual(apiKey, "sk-updated-key")
  }

  func testSettingsChangesAreForwardedToPersistence() async throws {
    var persistedSettings: CidaSettings?
    let model = AppModel(
      entries: [],
      settings: .designPreview,
      saveSettings: { settings in persistedSettings = settings }
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: SettingsWindowView(model: model),
      size: CGSize(width: 560, height: 660)
    )

    model.settings.apiKey = "sk-updated-key"
    try await waitUntil(timeout: .seconds(2)) {
      persistedSettings?.apiKey == "sk-updated-key"
    }

    XCTAssertEqual(persistedSettings?.apiKey, "sk-updated-key")
    withExtendedLifetime(hostingView) {}
  }

  func testComposerPreservesLargeMultilineTextAndSubmitsWithReturnAction() async throws {
    let model = AppModel(
      inputText: "",
      entries: [],
      service: ImmediateStreamingService()
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model),
      size: CGSize(width: 860, height: 640)
    )
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))
    let largeInput = String(repeating: "First line\nSecond line with context.\n", count: 2_000)
    input.string = largeInput
    input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
    await Task.yield()
    try await Task.sleep(for: .milliseconds(50))
    hostingView.layoutSubtreeIfNeeded()
    XCTAssertEqual(model.inputText, largeInput)
    let inputScrollView = try XCTUnwrap(input.enclosingScrollView)
    let intermediateEditorHeight = inputScrollView.frame.height
    XCTAssertGreaterThan(intermediateEditorHeight, 27)
    XCTAssertLessThan(intermediateEditorHeight, 220)
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return inputScrollView.frame.height >= 150
    }
    XCTAssertFalse(inputScrollView.hasVerticalScroller)
    XCTAssertFalse(CidaScrollIndicator.installed(in: inputScrollView)?.isHidden ?? true)
    let editorHeight = try XCTUnwrap(input.enclosingScrollView?.frame.height)
    XCTAssertGreaterThanOrEqual(editorHeight, 150)
    XCTAssertLessThanOrEqual(editorHeight, 220)
    XCTAssertGreaterThan(input.bounds.height, editorHeight)

    XCTAssertTrue(
      input.delegate?.textView?(input, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        == true)
    try await waitUntil(timeout: .seconds(2)) {
      model.entries.count == 1
    }
    XCTAssertEqual(model.entries.count, 1)
    XCTAssertEqual(model.entries.first?.source, largeInput)
    XCTAssertEqual(model.inputText, "")
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      let currentInput = self.firstTextView(
        in: hostingView,
        identifier: "composer-input"
      )
      return (currentInput?.enclosingScrollView?.frame.height ?? .greatestFiniteMagnitude) <= 27.5
    }
    let resetInput = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input")
    )
    XCTAssertTrue(resetInput.string.isEmpty, "nativeLength=\(resetInput.string.utf16.count)")
    XCTAssertEqual(
      resetInput.enclosingScrollView?.frame.height ?? 0,
      27,
      accuracy: 0.5
    )
  }

  func testComposerShrinksAsNativeMultilineInputIsDeleted() async throws {
    let model = AppModel(inputText: "", entries: [])
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))
    let inputScrollView = try XCTUnwrap(input.enclosingScrollView)
    let historyScrollView = try XCTUnwrap(
      allScrollViews(in: hostingView).first {
        $0.accessibilityIdentifier() == "history-scroll-view"
      }
    )

    func assertComposerDoesNotCoverHistory(file: StaticString = #filePath, line: UInt = #line) {
      let inputFrame = inputScrollView.convert(inputScrollView.bounds, to: hostingView)
      let historyFrame = historyScrollView.convert(historyScrollView.bounds, to: hostingView)
      XCTAssertLessThanOrEqual(
        inputFrame.intersection(historyFrame).height,
        0.5,
        "The history viewport and composer must use the same presentation state.",
        file: file,
        line: line
      )
    }

    let threeLines = "First line\nSecond line\nThird line"
    input.insertText(threeLines, replacementRange: NSRange(location: 0, length: 0))
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.inputText == threeLines
        && abs((input.enclosingScrollView?.frame.height ?? 0) - 94) <= 0.5
    }
    XCTAssertEqual(input.enclosingScrollView?.frame.height ?? 0, 94, accuracy: 0.5)
    assertComposerDoesNotCoverHistory()

    let thirdLineRange = (input.string as NSString).range(of: "\nThird line")
    input.insertText("", replacementRange: thirdLineRange)
    let twoLines = "First line\nSecond line"
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.inputText == twoLines
        && abs((input.enclosingScrollView?.frame.height ?? 0) - 68) <= 0.5
    }
    XCTAssertEqual(input.enclosingScrollView?.frame.height ?? 0, 68, accuracy: 0.5)
    assertComposerDoesNotCoverHistory()

    let secondLineRange = (input.string as NSString).range(of: "\nSecond line")
    input.insertText("", replacementRange: secondLineRange)
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.inputText == "First line"
        && abs((input.enclosingScrollView?.frame.height ?? 0) - 27) <= 0.5
    }
    XCTAssertEqual(input.enclosingScrollView?.frame.height ?? 0, 27, accuracy: 0.5)
    assertComposerDoesNotCoverHistory()

    input.insertText(
      "",
      replacementRange: NSRange(location: 0, length: (input.string as NSString).length)
    )
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.inputText.isEmpty
        && abs((input.enclosingScrollView?.frame.height ?? 0) - 27) <= 0.5
    }
    XCTAssertEqual(input.enclosingScrollView?.frame.height ?? 0, 27, accuracy: 0.5)
    assertComposerDoesNotCoverHistory()
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testNativeEditAfterPendingComposerResetIsNotCleared() async throws {
    let model = AppModel(
      inputText: "",
      entries: [],
      service: ImmediateStreamingService()
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    hostingView.layoutSubtreeIfNeeded()
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))

    input.string = "first request"
    input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
    XCTAssertEqual(model.inputText, "first request")
    XCTAssertTrue(model.submit())

    input.string = "recovery request"
    input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
    XCTAssertEqual(model.inputText, "recovery request")

    await Task.yield()
    hostingView.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    hostingView.layoutSubtreeIfNeeded()

    XCTAssertEqual(input.string, "recovery request")
    XCTAssertEqual(model.inputText, "recovery request")
    model.cancelProcessing()
  }

  func testPendingComposerResetClearsTheSubmittedNativeDocument() async throws {
    let model = AppModel(
      inputText: "",
      entries: [],
      service: ImmediateStreamingService()
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    hostingView.layoutSubtreeIfNeeded()
    let input = try XCTUnwrap(firstTextView(in: hostingView, identifier: "composer-input"))

    input.string = "submitted through the native responder"
    input.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: input))
    XCTAssertEqual(model.inputText, "submitted through the native responder")
    XCTAssertTrue(model.submit())

    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return input.string.isEmpty
        && (input.enclosingScrollView?.frame.height ?? .greatestFiniteMagnitude) <= 27.5
    }
    XCTAssertEqual(model.entries.last?.source, "submitted through the native responder")
    XCTAssertTrue(input.string.isEmpty)
    model.cancelProcessing()
  }

  func testComposerResetResolutionRejectsAStaleBindingEchoButPreservesANewerEdit() {
    XCTAssertEqual(
      ComposerResetSynchronizer.resolve(
        revision: 4,
        lastAppliedRevision: 3,
        nativeEditRevision: 3
      ),
      .clearSubmittedDocument
    )
    XCTAssertEqual(
      ComposerResetSynchronizer.resolve(
        revision: 4,
        lastAppliedRevision: 3,
        nativeEditRevision: 4
      ),
      .preserveNewerNativeEdit
    )
    XCTAssertEqual(
      ComposerResetSynchronizer.resolve(
        revision: 4,
        lastAppliedRevision: 4,
        nativeEditRevision: 4
      ),
      .none
    )
  }

  func testLongInputUsesThePencilScrollIndicators() async throws {
    let model = AppModel(
      inputText: HistoryEntry.designLongInput,
      entries: HistoryEntry.longDesignSamples,
      settings: .designPreview
    )
    let (window, hostingView) = makeNativeWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    window.alphaValue = 0
    window.orderBack(nil)
    try await Task.sleep(for: .milliseconds(100))
    hostingView.layoutSubtreeIfNeeded()

    let historyIndicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "history-scroll-indicator")
    )
    let composerIndicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "composer-scroll-indicator")
    )
    let resultTextView = try XCTUnwrap(
      firstTextView(
        in: hostingView,
        identifier: "history-result-\(model.entries[0].id.uuidString)"
      )
    )
    let resultContainer = try XCTUnwrap(resultTextView.superview as? HistoryResultTextContainer)
    try await waitUntil(timeout: .seconds(1)) {
      window.displayIfNeeded()
      hostingView.layoutSubtreeIfNeeded()
      hostingView.displayIfNeeded()
      if let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
      }
      historyIndicator.observedScrollView?.layoutSubtreeIfNeeded()
      historyIndicator.refresh()
      return !historyIndicator.isHidden && historyIndicator.doubleValue > 0.9
    }
    XCTAssertFalse(
      historyIndicator.isHidden,
      "frame=\(historyIndicator.frame) knob=\(historyIndicator.knobDrawingRect) result=\(resultContainer.frame) natural=\(resultContainer.naturalTextHeight) text=\(resultTextView.frame)"
    )
    XCTAssertFalse(
      composerIndicator.isHidden,
      "frame=\(composerIndicator.frame) knob=\(composerIndicator.knobDrawingRect)"
    )
    XCTAssertEqual(historyIndicator.knobDrawingRect.width, 4, accuracy: 0.1)
    XCTAssertEqual(historyIndicator.knobDrawingRect.height, 90, accuracy: 0.1)
    XCTAssertGreaterThan(
      historyIndicator.doubleValue,
      0.9,
      "value=\(historyIndicator.doubleValue) knob=\(historyIndicator.knobDrawingRect)"
    )
    XCTAssertEqual(composerIndicator.knobDrawingRect.width, 4, accuracy: 0.1)
    XCTAssertEqual(composerIndicator.knobDrawingRect.height, 64, accuracy: 0.1)
    XCTAssertLessThan(composerIndicator.doubleValue, 0.1)
    let composerIndicatorHost = try XCTUnwrap(composerIndicator.superview)
    let composerKnobPoint = composerIndicator.convert(
      NSPoint(
        x: composerIndicator.knobDrawingRect.midX,
        y: composerIndicator.knobDrawingRect.midY
      ),
      to: composerIndicatorHost
    )
    let composerKnobHit = composerIndicatorHost.hitTest(composerKnobPoint)
    XCTAssertTrue(
      composerKnobHit === composerIndicator,
      "hit=\(String(describing: composerKnobHit)) point=\(composerKnobPoint) hostBounds=\(composerIndicatorHost.bounds) indicator=\(composerIndicator.frame) knob=\(composerIndicator.knobDrawingRect) hidden=\(composerIndicator.isHidden)"
    )
    let historyScrollView = try XCTUnwrap(historyIndicator.observedScrollView)
    historyIndicator.scroll(toNormalizedValue: 0)
    XCTAssertLessThan(historyIndicator.doubleValue, 0.1)
    XCTAssertFalse(isScrolledToBottom(historyScrollView), scrollDescription(historyScrollView))
    historyIndicator.scroll(toNormalizedValue: 1)
    XCTAssertGreaterThan(historyIndicator.doubleValue, 0.9)
    XCTAssertTrue(isScrolledToBottom(historyScrollView), scrollDescription(historyScrollView))
    window.orderOut(nil)
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testPencilScrollIndicatorMovesDownFromDocumentTopToBottom() throws {
    let documentViews: [NSView] = [
      FlippedTestDocumentView(frame: NSRect(x: 0, y: 0, width: 320, height: 600)),
      NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 600)),
    ]

    for documentView in documentViews {
      let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
      scrollView.borderType = .noBorder
      scrollView.hasVerticalScroller = false
      scrollView.hasHorizontalScroller = false
      scrollView.documentView = documentView
      scrollView.layoutSubtreeIfNeeded()

      let indicator = CidaScrollIndicator.install(on: scrollView, configuration: .history)
      indicator.refresh()
      let clipView = scrollView.contentView
      let visibleHeight = clipView.documentVisibleRect.height
      let topOriginY =
        documentView.isFlipped
        ? documentView.bounds.minY
        : documentView.bounds.maxY - visibleHeight
      clipView.scroll(to: NSPoint(x: 0, y: topOriginY))
      scrollView.reflectScrolledClipView(clipView)
      indicator.refresh()

      XCTAssertTrue(indicator.isFlipped)
      XCTAssertEqual(indicator.doubleValue, 0, accuracy: 0.001)
      XCTAssertEqual(
        indicator.knobDrawingRect.minY,
        indicator.rect(for: .knobSlot).minY,
        accuracy: 0.001
      )
      let topKnobOriginY = indicator.knobDrawingRect.minY

      let bottomOriginY =
        documentView.isFlipped
        ? documentView.bounds.maxY - visibleHeight
        : documentView.bounds.minY
      clipView.scroll(to: NSPoint(x: 0, y: bottomOriginY))
      scrollView.reflectScrolledClipView(clipView)
      indicator.refresh()

      XCTAssertEqual(indicator.doubleValue, 1, accuracy: 0.001)
      XCTAssertEqual(
        indicator.knobDrawingRect.maxY,
        indicator.rect(for: .knobSlot).maxY,
        accuracy: 0.001
      )
      XCTAssertGreaterThan(indicator.knobDrawingRect.minY, topKnobOriginY)
    }
  }

  func testPencilScrollIndicatorsNeverUseSystemOverlayRendering() throws {
    let mainModel = AppModel(
      inputText: HistoryEntry.designLongInput,
      entries: HistoryEntry.longDesignSamples,
      settings: .designPreview
    )
    let (mainWindow, mainHostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: mainModel, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )

    var settings = CidaSettings.designPreview
    settings.provider = .openAI
    settings.model = "local-model"
    let (settingsWindow, settingsHostingView) = makeHiddenWindow(
      rootView: SettingsWindowView(model: AppModel(entries: [], settings: settings)),
      size: CGSize(width: 500, height: 500)
    )

    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    mainHostingView.layoutSubtreeIfNeeded()
    settingsHostingView.layoutSubtreeIfNeeded()

    let indicators = try [
      XCTUnwrap(
        firstScroller(in: mainHostingView, identifier: "history-scroll-indicator")
      ),
      XCTUnwrap(
        firstScroller(in: mainHostingView, identifier: "composer-scroll-indicator")
      ),
      XCTUnwrap(
        firstScroller(in: settingsHostingView, identifier: "settings-scroll-indicator")
      ),
    ]

    XCTAssertFalse(CidaScrollIndicator.isCompatibleWithOverlayScrollers)
    for indicator in indicators {
      let originalValue = indicator.doubleValue
      indicator.refresh()
      indicator.scroll(toNormalizedValue: 0.5)
      indicator.layoutSubtreeIfNeeded()
      indicator.displayIfNeeded()

      let systemOverlayLayers =
        indicator.layer?.sublayers?.filter {
          String(describing: $0.delegate).contains("OverlayScroller")
        } ?? []
      let pencilKnobLayers =
        indicator.layer?.sublayers?.filter {
          $0.delegate == nil
            && abs($0.frame.width - CidaScrollIndicator.knobWidth) <= 0.1
            && abs($0.frame.height - indicator.configuration.knobLength) <= 0.1
            && abs($0.cornerRadius - CidaScrollIndicator.knobWidth / 2) <= 0.1
        } ?? []
      XCTAssertEqual(indicator.scrollerStyle, .legacy)
      XCTAssertFalse(
        indicator.observedScrollView?.hasVerticalScroller ?? true,
        indicator.configuration.accessibilityIdentifier
      )
      XCTAssertTrue(
        systemOverlayLayers.isEmpty,
        "System overlay layers must not be mixed with the Pencil indicator: \(systemOverlayLayers)"
      )
      XCTAssertEqual(
        pencilKnobLayers.count,
        1,
        "Each scroll surface must render exactly one Pencil thumb: \(indicator.layer?.sublayers ?? [])"
      )
      XCTAssertEqual(
        indicator.layer?.sublayers?.count,
        1,
        "No second track or proportional thumb may appear while scrolling"
      )
      XCTAssertEqual(
        pencilKnobLayers.first?.backgroundColor,
        CidaScrollIndicator.knobColor.cgColor
      )
      XCTAssertEqual(indicator.knobDrawingRect.width, 4, accuracy: 0.1)

      indicator.scroll(toNormalizedValue: originalValue)
    }

    assertTestProcessIsNotFrontmost()
    withExtendedLifetime((mainWindow, settingsWindow)) {}
  }

  func testPencilScrollIndicatorRemovesScrollerReinstalledDuringLiveScroll() throws {
    let model = AppModel(
      inputText: HistoryEntry.designLongInput,
      entries: HistoryEntry.longDesignSamples,
      settings: .designPreview
    )
    let (window, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )

    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    hostingView.layoutSubtreeIfNeeded()
    let indicator = try XCTUnwrap(
      firstScroller(in: hostingView, identifier: "history-scroll-indicator")
    )
    let scrollView = try XCTUnwrap(indicator.observedScrollView)

    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.verticalScroller = NSScroller()
    scrollView.hasVerticalScroller = true
    XCTAssertTrue(scrollView.hasVerticalScroller)
    XCTAssertNotNil(scrollView.verticalScroller)

    NotificationCenter.default.post(
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )
    XCTAssertFalse(scrollView.hasVerticalScroller)
    XCTAssertNil(scrollView.verticalScroller)
    XCTAssertEqual(scrollView.scrollerStyle, .overlay)
    XCTAssertTrue(scrollView.autohidesScrollers)

    // Reproduce SwiftUI restoring the native scroller after the synchronous
    // live-scroll callback. The deferred guard must remove that second copy.
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.verticalScroller = NSScroller()
    scrollView.hasVerticalScroller = true
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))

    XCTAssertFalse(scrollView.hasVerticalScroller)
    XCTAssertNil(scrollView.verticalScroller)
    XCTAssertEqual(scrollView.scrollerStyle, .overlay)
    XCTAssertTrue(scrollView.autohidesScrollers)

    window.orderOut(nil)
    assertTestProcessIsNotFrontmost()
    withExtendedLifetime(window) {}
  }

  func testComposerVirtualizesLargeDocumentAndLoadsEarlierPagesOnDemand() async throws {
    let model = AppModel(
      inputText: "",
      entries: [],
      service: ImmediateStreamingService()
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let input = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input") as? ComposerNativeTextView
    )
    let largeInput = String(repeating: "123456789\n", count: 12_000)

    let clock = ContinuousClock()
    let startedAt = clock.now
    XCTAssertTrue(input.performPaste(largeInput))
    XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(50))

    try await waitUntil(timeout: .seconds(1)) {
      !input.isPerformingLargeDocumentPaste
        && model.inputDocumentUTF16Count == largeInput.utf16.count
    }
    XCTAssertEqual(input.documentUTF16Length, largeInput.utf16.count)
    XCTAssertEqual(
      input.textStorage?.length,
      ComposerNativeTextView.initialMaterializedUTF16Length
    )
    XCTAssertLessThanOrEqual(
      ComposerNativeTextView.initialMaterializedUTF16Length,
      512,
      "The synchronous paste path must materialize only the visible tail"
    )
    XCTAssertLessThanOrEqual(
      ComposerNativeTextView.materializedPageUTF16Length,
      ComposerNativeTextView.initialMaterializedUTF16Length * 2,
      "Upward scrolling must page text in bounded chunks"
    )
    XCTAssertGreaterThan(input.materializedDocumentRange.location, 0)
    XCTAssertEqual(input.selectedRange().location, input.textStorage?.length)

    let materializedLength = try XCTUnwrap(input.textStorage?.length)
    XCTAssertTrue(input.materializePreviousPage())
    XCTAssertGreaterThan(input.textStorage?.length ?? 0, materializedLength)
    XCTAssertEqual(input.documentStringForBinding(), largeInput)

    XCTAssertTrue(
      input.delegate?.textView?(input, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        == true
    )
    try await waitUntil(timeout: .seconds(1)) {
      hostingView.layoutSubtreeIfNeeded()
      return model.entries.first?.source.utf16.count == largeInput.utf16.count
        && model.inputText.isEmpty
        && (self.firstTextView(in: hostingView, identifier: "composer-input")?
          .enclosingScrollView?.frame.height ?? .greatestFiniteMagnitude) <= 27.5
    }
    XCTAssertEqual(model.entries.first?.source, largeInput)
    let resetInput = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input")
    )
    XCTAssertEqual(resetInput.enclosingScrollView?.frame.height ?? 0, 27, accuracy: 0.5)
    assertTestProcessIsNotFrontmost()
  }

  func testImmediateLargeDocumentSubmissionKeepsComposerCompact() async throws {
    let model = AppModel(
      inputText: "",
      entries: [],
      service: ImmediateStreamingService()
    )
    let (_, hostingView) = makeHiddenWindow(
      rootView: MainWindowView(model: model, automaticallyFocusInput: false),
      size: CGSize(width: 860, height: 640)
    )
    let input = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input") as? ComposerNativeTextView
    )
    let largeInput = String(repeating: "Immediate staged submission.\n", count: 4_500)

    XCTAssertTrue(input.performPaste(largeInput))
    XCTAssertTrue(
      input.delegate?.textView?(input, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        == true
    )

    try await waitUntil(timeout: .seconds(1)) {
      model.entries.first?.source == largeInput
    }
    try await Task.sleep(for: .milliseconds(80))
    hostingView.layoutSubtreeIfNeeded()

    let resetInput = try XCTUnwrap(
      firstTextView(in: hostingView, identifier: "composer-input")
    )
    XCTAssertEqual(model.inputDocumentUTF16Count, 0)
    XCTAssertEqual(resetInput.string, "")
    XCTAssertEqual(resetInput.enclosingScrollView?.frame.height ?? 0, 27, accuracy: 0.5)
    assertTestProcessIsNotFrontmost()
  }

  func testOpenAIEndpointFieldIsEditableWhenOpenAIIsSelected() throws {
    var settings = CidaSettings.designPreview
    settings.provider = .openAI
    settings.model = "gpt-5"
    let model = AppModel(entries: [], settings: settings)
    let (_, hostingView) = makeHiddenWindow(
      rootView: SettingsWindowView(model: model),
      size: CGSize(width: 560, height: 660)
    )

    let endpoint = try XCTUnwrap(
      firstTextField(in: hostingView, identifier: "settings-openai-endpoint")
    )
    endpoint.stringValue = "http://127.0.0.1:8080/v1/chat/completions"
    endpoint.delegate?.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: endpoint)
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))

    XCTAssertEqual(model.settings.openAIEndpoint, endpoint.stringValue)
  }

  private func makeHiddenWindow<Content: View>(
    rootView: Content,
    size: CGSize
  ) -> (CidaWindow, NSHostingView<Content>) {
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    let window = CidaWindow(
      contentRect: hostingView.frame,
      styleMask: [.borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    retainedTestWindows.append(window)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    return (window, hostingView)
  }

  private func waitUntil(
    timeout: Duration,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      if clock.now >= deadline {
        XCTFail("Timed out waiting for condition")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func assertTestProcessIsNotFrontmost(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertFalse(NSApp.isActive, file: file, line: line)
    XCTAssertNotEqual(
      NSWorkspace.shared.frontmostApplication?.processIdentifier,
      ProcessInfo.processInfo.processIdentifier,
      file: file,
      line: line
    )
  }

  private func makeNativeWindow<Content: View>(
    rootView: Content,
    size: CGSize
  ) -> (CidaWindow, NSHostingView<Content>) {
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.autoresizingMask = [.width, .height]
    let window = CidaWindowFactory.makeWindow(size: size, title: "Test")
    window.contentView = hostingView
    window.setContentSize(size)
    retainedTestWindows.append(window)
    hostingView.layoutSubtreeIfNeeded()
    return (window, hostingView)
  }

  private func firstTextField(
    in view: NSView,
    identifier: String
  ) -> NSTextField? {
    let fields = allTextFields(in: view)
    return fields.first { $0.accessibilityIdentifier() == identifier }
      ?? fields.first { $0.isEditable }
  }

  private func allTextFields(in view: NSView) -> [NSTextField] {
    var fields: [NSTextField] = []
    if let field = view as? NSTextField {
      fields.append(field)
    }
    for child in view.subviews {
      fields.append(contentsOf: allTextFields(in: child))
    }
    return fields
  }

  private func allScrollViews(in view: NSView) -> [NSScrollView] {
    var scrollViews: [NSScrollView] = []
    if let scrollView = view as? NSScrollView {
      scrollViews.append(scrollView)
    }
    for child in view.subviews {
      scrollViews.append(contentsOf: allScrollViews(in: child))
    }
    return scrollViews
  }

  private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
    guard let documentView = scrollView.documentView else { return false }
    let visibleRect = scrollView.contentView.documentVisibleRect
    if documentView.isFlipped {
      return visibleRect.maxY >= documentView.bounds.maxY - 24
    }
    return visibleRect.minY <= documentView.bounds.minY + 24
  }

  private func scrollDescription(_ scrollView: NSScrollView) -> String {
    guard let documentView = scrollView.documentView else { return "missing document view" }
    return
      "visible=\(scrollView.contentView.documentVisibleRect) document=\(documentView.bounds) flipped=\(documentView.isFlipped) frame=\(scrollView.frame)"
  }

  private func firstTextView(in view: NSView, identifier: String) -> NSTextView? {
    if let textView = view as? NSTextView,
      textView.accessibilityIdentifier() == identifier
    {
      return textView
    }
    if let container = view as? HistoryResultTextContainer,
      container.subviews.contains(where: {
        $0.accessibilityIdentifier() == identifier
      })
    {
      return container.textView
    }
    for child in view.subviews {
      if let result = firstTextView(in: child, identifier: identifier) {
        return result
      }
    }
    return nil
  }

  private func allHistoryResultContainers(in view: NSView) -> [HistoryResultTextContainer] {
    var containers: [HistoryResultTextContainer] = []
    if let container = view as? HistoryResultTextContainer {
      containers.append(container)
    }
    for child in view.subviews {
      containers.append(contentsOf: allHistoryResultContainers(in: child))
    }
    return containers
  }

  private func minimumAncestorAlpha(from view: NSView) -> CGFloat {
    var minimumAlpha = view.alphaValue
    var ancestor = view.superview
    while let current = ancestor {
      minimumAlpha = min(minimumAlpha, current.alphaValue)
      ancestor = current.superview
    }
    return minimumAlpha
  }

  private func firstHistoryResultContainer(
    in view: NSView,
    identifier: String
  ) -> HistoryResultTextContainer? {
    if let container = view as? HistoryResultTextContainer,
      container.subviews.contains(where: {
        $0.accessibilityIdentifier() == identifier
      })
    {
      return container
    }
    for child in view.subviews {
      if let result = firstHistoryResultContainer(in: child, identifier: identifier) {
        return result
      }
    }
    return nil
  }

  private func nativeHistoryEntryAncestor(of view: NSView) -> HistoryEntryNSView? {
    var ancestor = view.superview
    while let current = ancestor {
      if let historyEntry = current as? HistoryEntryNSView {
        return historyEntry
      }
      ancestor = current.superview
    }
    return nil
  }

  private func firstScroller(in view: NSView, identifier: String) -> CidaScrollIndicator? {
    if let scroller = view as? CidaScrollIndicator,
      scroller.accessibilityIdentifier() == identifier
    {
      return scroller
    }
    for child in view.subviews {
      if let result = firstScroller(in: child, identifier: identifier) {
        return result
      }
    }
    return nil
  }

  private func firstVirtualizedHistoryList(
    in view: NSView
  ) -> VirtualizedFoldedHistoryListNSView? {
    if let list = view as? VirtualizedFoldedHistoryListNSView {
      return list
    }
    for child in view.subviews {
      if let result = firstVirtualizedHistoryList(in: child) {
        return result
      }
    }
    return nil
  }

  private func firstHistoryEntryHoverTracker(
    in view: NSView
  ) -> HistoryEntryHoverTrackingNSView? {
    if let tracker = view as? HistoryEntryHoverTrackingNSView {
      return tracker
    }
    for child in view.subviews {
      if let result = firstHistoryEntryHoverTracker(in: child) {
        return result
      }
    }
    return nil
  }

  private func click(window: NSWindow, at point: NSPoint) {
    Self.clickEventNumber += 1
    let eventNumber = Self.clickEventNumber
    let down = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: 1
    )!
    let up = NSEvent.mouseEvent(
      with: .leftMouseUp,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: 0
    )!
    window.sendEvent(down)
    window.sendEvent(up)
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  }

  private func type(_ value: String, in window: NSWindow) {
    for character in value {
      let text = String(character)
      let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: text,
        charactersIgnoringModifiers: text,
        isARepeat: false,
        keyCode: 0
      )!
      window.sendEvent(event)
    }
  }

  private func clickTextInput(window: NSWindow, at point: NSPoint) {
    Self.clickEventNumber += 1
    let eventNumber = Self.clickEventNumber
    let down = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: 1
    )!
    let up = NSEvent.mouseEvent(
      with: .leftMouseUp,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: 0
    )!
    NSApp.postEvent(up, atStart: true)
    window.sendEvent(down)
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  }

}

@MainActor
private final class HistoryResultHeightProbeView: NSView, HistoryResultHeightChangeHosting {
  private(set) var publishedHeightDeltas: [CGFloat] = []

  func historyResultHeightWillChange(by delta: CGFloat) {
    publishedHeightDeltas.append(delta)
  }
}

@MainActor
private final class FlippedTestDocumentView: NSView {
  override var isFlipped: Bool { true }
}

private struct ImmediateStreamingService: TextProcessingService {
  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield("Done")
      continuation.finish()
    }
  }
}

private struct BackendPauseStreamingService: TextProcessingService {
  func stream(
    _ request: ProcessingRequest,
    settings: CidaSettings
  ) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await Task.sleep(for: .seconds(5))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

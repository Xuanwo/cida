import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import Cida

@MainActor
extension InteractionReproductionTests {
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
    XCTAssertEqual(expandedRenderer.presentation, .manuallyExpanded)
    XCTAssertEqual(latestRenderer.presentation, .current)
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

    // ↺, copy result, and the chevron-down disclosure hint.
    XCTAssertEqual(
      row.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.count,
      3
    )
    XCTAssertEqual(
      (row.accessibilityChildren() ?? []).compactMap { $0 as? NSButton }.count,
      3
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

  func testHistoryRowAtRestMatchesThePencilGeometryAndHoverHighlight() throws {
    let row = HistoryEntryNSView()
    row.configure(
      entryID: UUID(),
      mode: .translate,
      metadata: "中文 → English · 09:14 · 1,846 → 3,214 字",
      preview:
        "Designing distributed systems has never been a matter of simply picking technologies. When we discuss consistency, availability, and partition tolerance, the second line must remain visible and the third line must be clipped under the fade.",
      state: .completed,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )

    // Pencil v2: a long record at rest is the two-line Entry (108 pt) with no
    // card fill or inset; its text shares the expanded record's left rail.
    XCTAssertEqual(row.preferredHeight(for: 804), 108, accuracy: 0.001)
    row.frame = NSRect(x: 0, y: 0, width: 804, height: 108)
    row.layoutSubtreeIfNeeded()
    XCTAssertEqual(row.hoverHighlightOpacityForTesting, 0)
    XCTAssertEqual(row.hoverHighlightFrameForTesting, NSRect(x: -10, y: 0, width: 824, height: 108))
    XCTAssertEqual(row.headerModeFrameForTesting.minX, 18, accuracy: 0.001)
    XCTAssertEqual(row.headerModeFrameForTesting.minY, 16, accuracy: 0.001)
    XCTAssertEqual(
      row.foldedPreviewFrameForTesting,
      NSRect(x: 0, y: 40, width: 780, height: 52)
    )
    XCTAssertTrue(row.foldedPreviewUsesFadeForTesting)
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

    // Hover tints the whole row with surface-fold, bleeding 10 pt past the
    // text column; the text itself never moves.
    XCTAssertEqual(row.hoverHighlightOpacityForTesting, 1)
    let hoverBackground = try XCTUnwrap(row.hoverHighlightColorForTesting)
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

    let actionFrames = Set(
      row.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.map(\.frame)
    )
    XCTAssertEqual(
      actionFrames,
      [
        NSRect(x: 768, y: 18, width: 12, height: 12),  // chevron-down
        NSRect(x: 792, y: 18, width: 12, height: 12),  // ↺
        NSRect(x: 792, y: 44, width: 12, height: 12),  // copy result
      ]
    )
    XCTAssertEqual(
      row.foldedPreviewFrameForTesting,
      NSRect(x: 0, y: 40, width: 780, height: 52),
      "Hover must not reflow the preview; the action column is always reserved."
    )
  }

  func testHistoryRowShowsUpToTwoLinesAndFadesOnlyALongerResult() throws {
    let line = String(repeating: "M", count: 32)
    let row = HistoryEntryNSView()
    func configure(preview: String) {
      row.configure(
        entryID: UUID(),
        mode: .translate,
        metadata: "中文 → English · 09:14",
        preview: preview,
        state: .completed,
        showsSeparator: true,
        onExpand: {},
        onRedo: {},
        onCopyResult: {}
      )
      row.frame = NSRect(x: 0, y: 0, width: 804, height: row.preferredHeight(for: 804))
      row.layoutSubtreeIfNeeded()
      row.foldedPreviewViewForTesting.layoutSubtreeIfNeeded()
    }
    let previewView = row.foldedPreviewViewForTesting
    let fadeLayer = previewView.fadeLayer

    // One line: the Pencil 82 pt row, no fade.
    configure(preview: line)
    XCTAssertEqual(row.frame.height, 83, accuracy: 0.001)
    XCTAssertEqual(previewView.frame, NSRect(x: 0, y: 40, width: 780, height: 26))
    XCTAssertEqual(fadeLayer.opacity, 0)

    // Two lines fit the 52 pt clip exactly at the shared 26 pt line height and
    // stay fully legible.
    configure(preview: "\(line)\n\(line)")
    XCTAssertEqual(row.frame.height, 109, accuracy: 0.001)
    XCTAssertTrue(previewView.layer?.masksToBounds == true)
    XCTAssertFalse(previewView.isHidden)
    XCTAssertEqual(previewView.text, "\(line)\n\(line)")
    XCTAssertEqual(previewView.frame, NSRect(x: 0, y: 40, width: 780, height: 52))
    XCTAssertEqual(previewView.naturalTextHeight, 52, accuracy: 0.001)
    XCTAssertEqual(fadeLayer.opacity, 0, "Two visible lines are not a folded record")

    // Three lines: the same 108 pt row, but the second line dissolves into
    // the 25 pt Pencil fade because more text is clipped below it.
    configure(preview: "\(line)\n\(line)\n\(line)")
    XCTAssertEqual(row.frame.height, 109, accuracy: 0.001)
    XCTAssertEqual(previewView.frame, NSRect(x: 0, y: 40, width: 780, height: 52))
    XCTAssertFalse(fadeLayer.isHidden)
    XCTAssertEqual(fadeLayer.opacity, 1)
    XCTAssertEqual(
      fadeLayer.frame,
      NSRect(x: 0, y: 27, width: 780, height: 25),
      "The Pencil fade covers the bottom 25 pt of the 52 pt preview across its full width"
    )
    XCTAssertTrue(row.foldedPreviewUsesFadeForTesting)
  }

  func testFoldingAndExpandingAnimateThePencilTransitionInsideOneRenderer() async throws {
    try XCTSkipIf(
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      "Reduced motion resolves the fold transition to its end state immediately"
    )
    let entryID = UUID()
    let resultText = "Line one of the result.\nLine two of the result.\nLine three of the result."
    let resultStorage = HistoryResultStorage(resultText)
    let row = HistoryEntryNSView()
    row.frame = NSRect(x: 0, y: 0, width: 804, height: 96)
    let window = CidaWindow(
      contentRect: NSRect(x: 0, y: 0, width: 804, height: 400),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = row
    retainedTestWindows.append(window)

    row.configureExpanded(
      entryID: entryID,
      mode: .translate,
      metadata: "中文 → English · 14:05",
      source: "原文",
      preview: resultStorage.foldedPreview,
      resultStorage: resultStorage,
      presentationRevision: 0,
      latestPresentationDelta: nil,
      state: .completed,
      presentation: .current,
      isLongEntry: false,
      showsSeparator: false,
      onCollapse: {},
      onRedo: {},
      onCopySource: {},
      onCopyResult: {}
    )
    row.frame.size.height = row.preferredHeight(for: 804)
    row.layoutSubtreeIfNeeded()
    try await waitUntil(timeout: .seconds(2)) {
      (row.resultContainerForTesting?.naturalTextHeight ?? 0) >= 78
    }
    let expandedHeight = row.preferredHeight(for: 804)
    XCTAssertGreaterThan(expandedHeight, 108)
    XCTAssertEqual(row.hoverHighlightOpacityForTesting, 0)

    // Fold: the result swaps to the shared TextKit preview at the start and the
    // geometry animates to the two-line row over motion-fold-ms.
    row.configureFolding(
      entryID: entryID,
      mode: .translate,
      metadata: "中文 → English · 14:05",
      source: "原文",
      preview: resultStorage.foldedPreview,
      resultStorage: resultStorage,
      state: .completed,
      isLongEntry: false,
      showsSeparator: false,
      animated: true,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )
    XCTAssertEqual(row.presentation, .folded)
    XCTAssertTrue(row.isTransitioningForTesting)
    XCTAssertEqual(row.preferredHeight(for: 804), 108, accuracy: 0.001)
    XCTAssertNil(row.resultContainerForTesting)
    XCTAssertFalse(row.foldedPreviewViewForTesting.isHidden)
    XCTAssertEqual(
      row.foldedPreviewViewForTesting.text,
      resultText,
      "A short record folds with its complete text so the clip animates over real lines"
    )
    XCTAssertEqual(
      row.foldedPreviewFrameForTesting,
      NSRect(x: 0, y: 40, width: 780, height: 52),
      "The animator commits the Pencil row frame as the model value"
    )
    XCTAssertTrue(row.actionButtonsForTesting.allSatisfy(\.isHidden))
    // A re-render toward the same state keeps the transition running.
    row.configure(
      entryID: entryID,
      mode: .translate,
      metadata: "中文 → English · 14:05",
      preview: resultStorage.foldedPreview,
      state: .completed,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )
    XCTAssertTrue(row.isTransitioningForTesting)

    try await waitUntil(timeout: .seconds(2)) { !row.isTransitioningForTesting }
    XCTAssertEqual(row.foldedPreviewViewForTesting.text, resultStorage.foldedPreview)
    XCTAssertEqual(row.sourceFrameForTesting.height, 0, accuracy: 0.001)
    XCTAssertEqual(row.headerModeFrameForTesting.minX, 18, accuracy: 0.001)
    XCTAssertTrue(row.foldedPreviewUsesFadeForTesting)

    // Expand in place: the natural height is available immediately so SwiftUI
    // can animate the frame.
    row.configureExpanded(
      entryID: entryID,
      mode: .translate,
      metadata: "中文 → English · 14:05",
      source: "原文",
      preview: resultStorage.foldedPreview,
      resultStorage: resultStorage,
      presentationRevision: 0,
      latestPresentationDelta: nil,
      state: .completed,
      presentation: .manuallyExpanded,
      isLongEntry: false,
      showsSeparator: false,
      animated: true,
      onCollapse: {},
      onRedo: {},
      onCopySource: {},
      onCopyResult: {}
    )
    XCTAssertEqual(row.presentation, .manuallyExpanded)
    XCTAssertTrue(row.isTransitioningForTesting)
    XCTAssertEqual(row.preferredHeight(for: 804), expandedHeight, accuracy: 0.001)
    XCTAssertNotNil(row.resultContainerForTesting)
    XCTAssertTrue(row.foldedPreviewViewForTesting.isHidden)
    XCTAssertEqual(row.hoverHighlightOpacityForTesting, 0)

    try await waitUntil(timeout: .seconds(2)) { !row.isTransitioningForTesting }
    row.frame.size.height = row.preferredHeight(for: 804)
    row.layoutSubtreeIfNeeded()
    XCTAssertEqual(row.headerModeFrameForTesting.minX, 18, accuracy: 0.001)
    XCTAssertEqual(row.sourceFrameForTesting, NSRect(x: 0, y: 40, width: 780, height: 21))
    XCTAssertEqual(row.resultFrameForTesting.minY, 69, accuracy: 0.001)
  }

  func testLatestSourcePreviewUsesThePencilClipAndFadeGeometry() {
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourcePreviewHeight, 41)
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourceFadeHeight, 20)
    XCTAssertEqual(HistoryEntryPencilLayout.latestSourceLineLimit, 2)
  }

  func testLatestSingleLineSourceUsesNaturalHeightWithoutFadeOrDeadSpace() throws {
    let row = HistoryEntryNSView()
    row.configureExpanded(
      entryID: UUID(),
      mode: .improve,
      metadata: "English · 语气与语法 · 13:50",
      source: "What's the cost about claude review? We probably should follow the same limit.",
      preview: "What's the cost for Claude review? We should probably follow the same limit.",
      resultStorage: HistoryResultStorage(
        "What's the cost for Claude review? We should probably follow the same limit."
      ),
      presentationRevision: 0,
      latestPresentationDelta: nil,
      state: .completed,
      presentation: .current,
      isLongEntry: false,
      showsSeparator: false,
      onCollapse: {},
      onRedo: {},
      onCopySource: {},
      onCopyResult: {}
    )
    row.frame = NSRect(x: 0, y: 0, width: 804, height: row.preferredHeight(for: 804))
    row.layoutSubtreeIfNeeded()

    XCTAssertEqual(row.sourceFrameForTesting.height, 21, accuracy: 0.001)
    XCTAssertEqual(
      row.resultFrameForTesting.minY - row.sourceFrameForTesting.maxY,
      8,
      accuracy: 0.001
    )
    XCTAssertFalse(row.sourceUsesFadeForTesting)
    for _ in 0..<120 {
      _ = row.preferredHeight(for: 804)
    }
    XCTAssertEqual(row.sourceMeasurementCountForTesting, 1)
  }

  func testMeasuringAnExpandedRecordAtProbeWidthsNeverDisturbsItsLayout() throws {
    // SwiftUI probes `sizeThatFits` at 1 pt and 10 pt while it sizes the
    // column. Laying the result out at those widths left the live container
    // 1 pt wide, so the expanded record's text column collapsed.
    let entry = HistoryEntry.designSamples[1]
    let row = HistoryEntryNSView()
    row.frame = NSRect(x: 0, y: 0, width: 804, height: 82)
    row.configureExpanded(
      entryID: entry.id,
      mode: entry.mode,
      metadata: entry.metadata,
      source: entry.source,
      preview: entry.resultStorage.foldedPreview,
      resultStorage: entry.resultStorage,
      presentationRevision: 0,
      latestPresentationDelta: nil,
      state: .completed,
      presentation: .manuallyExpanded,
      isLongEntry: entry.isLongDocument,
      showsSeparator: true,
      onCollapse: {},
      onRedo: {},
      onCopySource: {},
      onCopyResult: {}
    )
    row.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    let laidOut = row.resultFrameForTesting
    XCTAssertEqual(laidOut.width, 780, accuracy: 0.001)
    // 16 + 16 header + 8 + 21 source + 8 + 26 result + 16 + 1 separator.
    XCTAssertEqual(row.preferredHeight(for: 804), 112, accuracy: 0.001)

    for probeWidth: CGFloat in [1, 10, 400, 1_280] {
      _ = row.preferredHeight(for: probeWidth)
      XCTAssertEqual(
        row.resultFrameForTesting, laidOut,
        "Measuring at \(probeWidth) pt must leave the live result layout alone"
      )
    }
    XCTAssertEqual(row.preferredHeight(for: 804), 112, accuracy: 0.001)
  }

  func testNativeHistoryEntryKeepsOneRendererAndExactGeometryAcrossEveryState() throws {
    let pool = HistoryResultTextContainerPool.shared
    let initialLeaseCount = pool.leasedContainerCountForTesting
    let entryID = UUID()
    let resultStorage = HistoryResultStorage("A complete result")
    let row = HistoryEntryNSView()
    var didCopyExpandedSource = false
    row.frame = NSRect(x: 0, y: 0, width: 804, height: 82)
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
    XCTAssertEqual(row.preferredHeight(for: 804), 82, accuracy: 0.001)
    XCTAssertEqual(row.headerModeFrameForTesting.minX, 18, accuracy: 0.001)
    XCTAssertEqual(row.headerModeFrameForTesting.minY, 16, accuracy: 0.001)
    XCTAssertEqual(
      row.foldedPreviewFrameForTesting,
      NSRect(x: 0, y: 40, width: 780, height: 26)
    )
    XCTAssertFalse(row.foldedPreviewUsesFadeForTesting)
    XCTAssertEqual(row.hoverHighlightOpacityForTesting, 0)
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
      presentation: .manuallyExpanded,
      isLongEntry: false,
      showsSeparator: false,
      onCollapse: {},
      onRedo: {},
      onCopySource: { didCopyExpandedSource = true },
      onCopyResult: {}
    )
    row.frame.size.height = row.preferredHeight(for: 804)
    row.layoutSubtreeIfNeeded()
    let expandedResultContainer = try XCTUnwrap(row.resultContainerForTesting)

    XCTAssertEqual(row.presentation, .manuallyExpanded)
    XCTAssertEqual(row.headerRendererIdentityForTesting, sharedHeaderRenderer)
    // Every presentation shares the Pencil `Entry` left rail: the header and
    // the result start at the entry's leading edge at rest and when expanded.
    XCTAssertEqual(row.headerModeFrameForTesting.minX, 18, accuracy: 0.001)
    XCTAssertEqual(row.resultFrameForTesting.minX, 0, accuracy: 0.001)
    XCTAssertEqual(row.hoverHighlightOpacityForTesting, 0)
    XCTAssertTrue(row.foldedPreviewViewForTesting.isHidden)
    XCTAssertEqual(expandedResultContainer.accessibilityRole(), .group)
    let expandedSource = try XCTUnwrap(
      row.subviews.first {
        $0.accessibilityIdentifier() == "history-source-\(entryID.uuidString.lowercased())"
      }
    )
    XCTAssertFalse(expandedSource.isHidden)
    XCTAssertEqual(expandedSource.accessibilityRole(), .staticText)
    XCTAssertTrue(
      (row.accessibilityChildren() ?? []).contains { ($0 as AnyObject) === expandedSource }
    )
    XCTAssertEqual(
      expandedResultContainer.subviews.first {
        $0.accessibilityIdentifier() == "history-result-\(entryID.uuidString)"
      }?.accessibilityRole(),
      .textArea
    )
    XCTAssertEqual(row.headerModeFrameForTesting.minY, 16, accuracy: 0.001)
    XCTAssertEqual(row.sourceFrameForTesting, NSRect(x: 0, y: 40, width: 780, height: 21))
    XCTAssertFalse(row.sourceUsesFadeForTesting)
    XCTAssertEqual(row.resultFrameForTesting.minY, 69, accuracy: 0.001)
    row.setResolvedHoverState(true)
    let expandedSourceAction = try XCTUnwrap(
      row.subviews.compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier()
          == "history-action-copy-source-\(entryID.uuidString.lowercased())"
      }
    )
    let expandedSourceHitView = row.hitTest(
      NSPoint(x: expandedSourceAction.frame.midX, y: expandedSourceAction.frame.midY)
    )
    XCTAssertFalse(expandedSourceAction.isHidden)
    XCTAssertTrue(row.bounds.contains(expandedSourceAction.frame))
    XCTAssertTrue(
      expandedSourceHitView === expandedSourceAction,
      "Expected source action hit, received \(String(describing: expandedSourceHitView))"
    )
    XCTAssertTrue(
      row.performVisibleAction(
        at: NSPoint(x: expandedSourceAction.frame.midX, y: expandedSourceAction.frame.midY)
      )
    )
    XCTAssertTrue(didCopyExpandedSource)
    XCTAssertEqual(expandedSourceAction.accessibilityValue() as? String, "copied")
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
      presentation: .current,
      isLongEntry: false,
      showsSeparator: false,
      onCollapse: {},
      onRedo: {},
      onCopySource: {},
      onCopyResult: {}
    )
    row.frame.size.height = row.preferredHeight(for: 804)
    row.layoutSubtreeIfNeeded()

    XCTAssertEqual(row.presentation, .current)
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
    XCTAssertTrue(row.sourceUsesFadeForTesting)
    XCTAssertEqual(row.resultFrameForTesting.minY, 89, accuracy: 0.001)
    XCTAssertEqual(
      row.resultFrameForTesting.maxY + 16,
      row.preferredHeight(for: 804),
      accuracy: 0.001
    )

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
      presentation: .current,
      isLongEntry: false,
      showsSeparator: false,
      onCollapse: {},
      onRedo: {},
      onCopySource: {},
      onCopyResult: {}
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
    let accessibilityChildren = row.accessibilityChildren() ?? []
    XCTAssertFalse(accessibilityChildren.contains { $0 is StickyHistoryResultActionNSView })
    let resultAction = try XCTUnwrap(
      accessibilityChildren.compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier()
          == "history-action-copy-result-\(entryID.uuidString.lowercased())"
      }
    )
    XCTAssertEqual(resultAction.accessibilityRole(), .button)
    XCTAssertTrue(
      accessibilityChildren.compactMap { $0 as? NSView }.allSatisfy {
        $0.isAccessibilityElement() && $0.accessibilityRole() != nil
      }
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

  func testExpandedHistorySourceCopyUsesStandardAppKitHitTesting() throws {
    let entryID = UUID()
    let row = HistoryEntryNSView()
    var didCopySource = false
    row.configureExpanded(
      entryID: entryID,
      mode: .improve,
      metadata: "English · 09:14",
      source: "Original source",
      preview: "Complete result",
      resultStorage: HistoryResultStorage("Complete result"),
      presentationRevision: 0,
      latestPresentationDelta: nil,
      state: .completed,
      presentation: .manuallyExpanded,
      isLongEntry: false,
      showsSeparator: false,
      onCollapse: {},
      onRedo: {},
      onCopySource: { didCopySource = true },
      onCopyResult: {}
    )
    row.frame = NSRect(
      x: 0,
      y: 0,
      width: 804,
      height: row.preferredHeight(for: 804)
    )
    let window = CidaWindow(
      contentRect: row.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.contentView = row
    retainedTestWindows.append(window)
    window.orderBack(nil)
    row.layoutSubtreeIfNeeded()
    row.setResolvedHoverState(true)
    row.layoutSubtreeIfNeeded()

    let sourceAction = try XCTUnwrap(
      row.subviews.compactMap { $0 as? HistoryEntryActionButton }.first {
        $0.accessibilityIdentifier()
          == "history-action-copy-source-\(entryID.uuidString.lowercased())"
      }
    )
    XCTAssertFalse(sourceAction.isHidden)
    let actionPoint = NSPoint(x: sourceAction.frame.midX, y: sourceAction.frame.midY)
    guard
      let clickEvent = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: row.convert(actionPoint, to: nil),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
      )
    else {
      XCTFail("The source action must accept a native pointer event.")
      return
    }
    NSApp.sendEvent(clickEvent)

    XCTAssertTrue(didCopySource)
    XCTAssertEqual(sourceAction.accessibilityValue() as? String, "copied")
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
      3
    )

    rows[0].setResolvedHoverState(false)
    rows[1].setResolvedHoverState(true)
    XCTAssertEqual(
      rows.flatMap(\.subviews).compactMap { $0 as? NSButton }.filter { !$0.isHidden }.count,
      3
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

}

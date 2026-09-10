import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import Cida

@MainActor
extension InteractionReproductionTests {
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
    XCTAssertEqual(resultView.glyphRevealFragmentCountForTesting, 1)
    let revealAnimation = try XCTUnwrap(resultView.glyphRevealAnimationForTesting)
    XCTAssertEqual(revealAnimation.duration, 0.12, accuracy: 0.001)
    XCTAssertEqual(
      try XCTUnwrap(revealAnimation.fromValue as? NSNumber).doubleValue,
      0,
      accuracy: 0.001,
      "Pencil T2: glyphs fade in behind the caret from fully transparent"
    )
    XCTAssertEqual(
      resultView.glyphRevealCommittedLengthForTesting,
      0,
      "The rendering view must not paint glyphs that a fragment is still revealing"
    )
    // The caret already follows the presented glyphs on the same pulse.
    XCTAssertGreaterThan(resultView.streamingCaretFrame.minX, 0)
    _ = resultView.updateDocumentLayout()
    resultView.updateStreamingCaretFrame()
    XCTAssertGreaterThan(resultView.streamingCaretFrame.minX, 0)

    resultView.setStreaming(false)
    XCTAssertFalse(resultView.streamingCaretIsVisible)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(
      resultView.glyphRevealFragmentCountForTesting,
      0,
      "Completion lets the last glyphs finish their fade, then commits them"
    )
    XCTAssertEqual(resultView.glyphRevealCommittedLengthForTesting, 4)
  }

  func testGlyphFadeMatchesThePencilOneHundredTwentyMillisecondEaseOut() {
    let initial = StreamGlyphFadeAnimation.style(elapsed: 0)
    let midpoint = StreamGlyphFadeAnimation.style(elapsed: 0.06)
    let complete = StreamGlyphFadeAnimation.style(elapsed: 0.12)

    XCTAssertEqual(initial.opacity, 0, accuracy: 0.001)
    XCTAssertEqual(initial.blurRadius, 2, accuracy: 0.001)
    XCTAssertGreaterThan(midpoint.opacity, initial.opacity)
    XCTAssertEqual(midpoint.opacity, 0.875, accuracy: 0.001)
    XCTAssertEqual(midpoint.blurRadius, 0.25, accuracy: 0.001)
    XCTAssertEqual(complete.opacity, 1, accuracy: 0.001)
    XCTAssertEqual(complete.blurRadius, 0, accuracy: 0.001)
  }

  func testEachPresentedGlyphRunGetsItsOwnPencilRevealAndCommitsInOrder() throws {
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

    resultView.append("First line grows.\n", isStreaming: true)
    resultView.append("Second line grows.", isStreaming: true)
    let expandedHeight = resultView.updateDocumentLayout()

    XCTAssertGreaterThan(expandedHeight, HistoryResultTextContainer.minimumHeight)
    XCTAssertEqual(resultView.glyphRevealFragmentCountForTesting, 2)
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
    let fragmentFrames = resultView.glyphRevealFragmentFramesForTesting
    XCTAssertEqual(fragmentFrames.count, 2)
    XCTAssertGreaterThan(
      fragmentFrames[1].minY,
      fragmentFrames[0].minY,
      "The second run must be positioned on the wrapped second line"
    )
    XCTAssertEqual(resultView.glyphRevealCommittedLengthForTesting, 0)

    // Committing is invisible, so it rides the coalesced layout tick; nothing
    // commits before a fragment's fade has finished.
    resultView.commitCompletedGlyphReveals(now: 0)
    XCTAssertEqual(resultView.glyphRevealFragmentCountForTesting, 2)
    resultView.commitCompletedGlyphReveals(now: .greatestFiniteMagnitude)
    XCTAssertEqual(resultView.glyphRevealFragmentCountForTesting, 0)
    XCTAssertEqual(
      resultView.glyphRevealCommittedLengthForTesting,
      "First line grows.\nSecond line grows.".utf16.count
    )
  }

  func testRecordActionsFadeInOverThePencilIconDurations() throws {
    try XCTSkipIf(
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      "Reduced motion reveals actions without a fade"
    )
    let entryID = UUID()
    let row = HistoryEntryNSView()
    row.frame = NSRect(x: 0, y: 0, width: 804, height: 96)
    let window = CidaWindow(
      contentRect: row.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = row
    retainedTestWindows.append(window)
    row.configure(
      entryID: entryID,
      mode: .translate,
      metadata: "中文 → English · 生成中",
      preview: "Streaming preview",
      state: .streaming,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )
    row.setHoverManagedExternally(true)
    row.layoutSubtreeIfNeeded()

    row.setResolvedHoverState(true)
    XCTAssertTrue(
      row.actionButtonsForTesting.allSatisfy(\.isHidden),
      "A streaming record never shows actions"
    )

    // Pencil T3: completing under the pointer reveals the icons over
    // motion-icon-swap-ms.
    row.configureContent(
      entryID: entryID,
      mode: .translate,
      metadata: "中文 → English · 14:05",
      preview: "Streaming preview",
      state: .completed
    )
    // ↺, copy, and the chevron-down disclosure hint reveal together.
    let revealedOnCompletion = row.actionButtonsForTesting.filter { !$0.isHidden }
    XCTAssertEqual(revealedOnCompletion.count, 3)
    XCTAssertFalse(try XCTUnwrap(row.chevronButtonForTesting).isHidden)
    for button in revealedOnCompletion {
      let reveal = try XCTUnwrap(button.revealAnimationForTesting)
      XCTAssertEqual(reveal.duration, 0.15, accuracy: 0.001)
      XCTAssertEqual(try XCTUnwrap(reveal.fromValue as? NSNumber).doubleValue, 0, accuracy: 0.001)
      XCTAssertEqual(try XCTUnwrap(reveal.toValue as? NSNumber).doubleValue, 1, accuracy: 0.001)
    }

    // Leaving hides the icons immediately; hovering again fades them in over
    // motion-icon-in-ms.
    row.setResolvedHoverState(false)
    XCTAssertTrue(row.actionButtonsForTesting.allSatisfy(\.isHidden))
    row.setResolvedHoverState(true)
    let revealedOnHover = row.actionButtonsForTesting.filter { !$0.isHidden }
    XCTAssertEqual(revealedOnHover.count, 3)
    XCTAssertEqual(
      row.hoverHighlightOpacityForTesting,
      1,
      "Hovering a record at rest tints the whole row"
    )
    for button in revealedOnHover {
      XCTAssertEqual(
        try XCTUnwrap(button.revealAnimationForTesting).duration,
        0.12,
        accuracy: 0.001
      )
    }
  }

  func testRecordActionIconsArePaintedOnceAndKeepTheirFrameCornersClear() throws {
    // The reported defect: the NSButton cell painted its own copy of the
    // template image over the icon view, with blocky strokes and a mark in each
    // corner of the 12 pt frame. The cell keeps its described image for the
    // accessibility audit, so the oracle is the rendering itself: the redo
    // glyph never touches its corners, and a painted corner pixel is the
    // defect's signature.
    let row = HistoryEntryNSView()
    row.frame = NSRect(x: 0, y: 0, width: 804, height: 82)
    let window = CidaWindow(
      contentRect: row.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = row
    retainedTestWindows.append(window)
    row.configure(
      entryID: UUID(),
      mode: .translate,
      metadata: "中文 → English · 09:14",
      preview: "Done",
      state: .completed,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )
    row.setHoverManagedExternally(true)
    row.layoutSubtreeIfNeeded()
    row.setResolvedHoverState(true)
    let redo = try XCTUnwrap(
      row.actionButtonsForTesting.first {
        $0.accessibilityIdentifier().hasPrefix("history-action-redo-")
      }
    )
    XCTAssertFalse(redo.isHidden)
    XCTAssertEqual(redo.image?.accessibilityDescription, redo.accessibilityLabel())

    let scale: CGFloat = 2
    let representation = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(redo.bounds.width * scale),
        pixelsHigh: Int(redo.bounds.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    representation.size = redo.bounds.size
    redo.cacheDisplay(in: redo.bounds, to: representation)
    let last = Int(redo.bounds.width * scale) - 1
    for (x, y) in [(0, 0), (last, 0), (0, last), (last, last)] {
      let alpha = representation.colorAt(x: x, y: y)?.alphaComponent ?? 0
      XCTAssertEqual(alpha, 0, accuracy: 0.02, "Corner (\(x), \(y)) must stay unpainted")
    }
    var paintedPixels = 0
    for x in 0...last {
      for y in 0...last where (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
        paintedPixels += 1
      }
    }
    XCTAssertGreaterThan(paintedPixels, 40, "The glyph itself is painted")
  }

  func testRecordActionsFadeOutOnExitAndCrossfadeTheCopiedCheck() throws {
    try XCTSkipIf(
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      "Reduced motion hides and swaps icons immediately"
    )
    let row = HistoryEntryNSView()
    row.frame = NSRect(x: 0, y: 0, width: 804, height: 82)
    let window = CidaWindow(
      contentRect: row.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = row
    retainedTestWindows.append(window)
    row.configure(
      entryID: UUID(),
      mode: .translate,
      metadata: "中文 → English · 09:14",
      preview: "Done",
      state: .completed,
      onExpand: {},
      onRedo: {},
      onCopyResult: {}
    )
    row.setHoverManagedExternally(true)
    row.layoutSubtreeIfNeeded()
    row.setResolvedHoverState(true)
    let copy = try XCTUnwrap(
      row.actionButtonsForTesting.first {
        $0.accessibilityIdentifier().hasPrefix("history-action-copy-")
      }
    )
    XCTAssertFalse(copy.isHidden)
    XCTAssertNil(copy.iconSwapTransitionForTesting)

    // Copying swaps copy → ✓ over motion-icon-swap-ms instead of snapping.
    copy.performClick(nil)
    let swap = try XCTUnwrap(copy.iconSwapTransitionForTesting)
    XCTAssertEqual(swap.type, .fade)
    XCTAssertEqual(swap.duration, 0.15, accuracy: 0.001)
    XCTAssertEqual(copy.iconImage, LucideIconAsset.image(for: .check))

    // Leaving the record hides the buttons at once for hit-testing and
    // accessibility, while a detached snapshot fades out over
    // motion-icon-in-ms.
    row.setResolvedHoverState(false)
    XCTAssertTrue(row.actionButtonsForTesting.allSatisfy(\.isHidden))
    XCTAssertTrue((row.accessibilityChildren() ?? []).compactMap { $0 as? NSButton }.isEmpty)
    let ghost = try XCTUnwrap(copy.concealGhostLayerForTesting)
    XCTAssertEqual(ghost.frame, copy.frame)
    XCTAssertTrue(ghost.superlayer === row.layer)
    let fade = try XCTUnwrap(copy.concealAnimationForTesting)
    XCTAssertEqual(fade.duration, 0.12, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(fade.toValue as? NSNumber).doubleValue, 0, accuracy: 0.001)
    XCTAssertNil(row.hitTest(NSPoint(x: copy.frame.midX, y: copy.frame.midY)) as? HistoryEntryActionButton)
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

}

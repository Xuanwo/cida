import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import Cida

@MainActor
extension InteractionReproductionTests {
  /// Each edge of a long result with text beyond it fades: as deep as the
  /// hidden text up to `ResultFade.length`, flush with that edge, and painted
  /// over the ink so the last visible line reads as continuing.
  func testALongResultFadesTheEdgesWithTextBeyondThem() async throws {
    let model = AppModel(inputText: ResultRecord.designLongInput, settings: .designPreview)
    model.setResultForTesting(ResultRecord.designLong())
    let controller = makeHiddenPanel(model: model)
    controller.panel.orderBack(nil)
    let hostingView = try XCTUnwrap(controller.contentView)
    try await Task.sleep(for: .milliseconds(100))
    let pane = try XCTUnwrap(firstResultScrollView(in: hostingView))
    let length = CidaDesign.ResultFade.length
    try await waitUntil(timeout: .seconds(2)) {
      hostingView.layoutSubtreeIfNeeded()
      return pane.container.frame.height > pane.contentView.bounds.height + 2 * length
    }
    let fades = pane.subviews.compactMap { $0 as? ResultEdgeFadeView }
    let top = try XCTUnwrap(fades.first { $0.edge == .top })
    let bottom = try XCTUnwrap(fades.first { $0.edge == .bottom })
    func depth(_ fade: ResultEdgeFadeView) -> CGFloat { fade.isHidden ? 0 : fade.frame.height }
    func scroll(to y: CGFloat) {
      pane.contentView.scroll(to: NSPoint(x: 0, y: y))
      pane.reflectScrolledClipView(pane.contentView)
    }
    let end = pane.container.frame.height - pane.contentView.bounds.height

    XCTAssertEqual(depth(top), 0, "Nothing is above the start")
    XCTAssertEqual(depth(bottom), length)
    let clipInWindow = pane.contentView.convert(pane.contentView.bounds, to: nil)
    XCTAssertEqual(bottom.convert(bottom.bounds, to: nil).minY, clipInWindow.minY, accuracy: 0.5)
    XCTAssertEqual(bottom.convert(bottom.bounds, to: nil).width, clipInWindow.width, accuracy: 0.5)
    XCTAssertNil(pane.hitTest(pane.convert(NSPoint(x: bottom.frame.midX, y: bottom.frame.midY), to: pane.superview)) as? ResultEdgeFadeView)

    // The last visible line is painted nearer the paper than a line above it,
    // in the panel as a whole: the fade covers the paper drawn behind the pane.
    let panelRect = hostingView.bounds
    let rep = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: panelRect))
    hostingView.cacheDisplay(in: panelRect, to: rep)
    let scale = CGFloat(rep.pixelsWide) / panelRect.width
    func pixelRows(of rectInClip: NSRect) -> Range<Int> {
      let rect = pane.contentView.convert(rectInClip, to: hostingView)
      let top = hostingView.isFlipped ? rect.minY : panelRect.height - rect.maxY
      return Int(top * scale)..<Int((top + rect.height) * scale)
    }
    func strongestInk(in rectInClip: NSRect) throws -> CGFloat {
      let rows = pixelRows(of: rectInClip)
      // The pane's left inset is bare paper.
      let paper = try XCTUnwrap(rep.colorAt(x: Int(8 * scale), y: rows.lowerBound))
      var strongest: CGFloat = 0
      for y in rows {
        for x in stride(from: Int(CidaDesign.Spacing.windowHorizontal * scale), to: Int(400 * scale), by: 2) {
          guard let color = rep.colorAt(x: x, y: y) else { continue }
          strongest = max(strongest, abs(color.brightnessComponent - paper.brightnessComponent))
        }
      }
      return strongest
    }
    let line = CidaDesign.Typography.resultLineHeight
    let visible = pane.contentView.bounds
    let lastLine = NSRect(x: 0, y: visible.maxY - line, width: visible.width, height: line)
    let middleLine = NSRect(x: 0, y: visible.midY - line / 2, width: visible.width, height: line)
    let middleInk = try strongestInk(in: middleLine)
    XCTAssertGreaterThan(middleInk, 0.5, "A line away from the edges is full ink")
    XCTAssertLessThan(try strongestInk(in: lastLine), middleInk * 0.6, "The last visible line fades")

    scroll(to: 20)
    XCTAssertEqual(depth(top), 20, "The top fade is as deep as the text above")
    XCTAssertEqual(top.convert(top.bounds, to: nil).maxY, clipInWindow.maxY, accuracy: 0.5)
    XCTAssertEqual(depth(bottom), length)
    scroll(to: end / 2)
    XCTAssertEqual(depth(top), length)
    XCTAssertEqual(depth(bottom), length)
    scroll(to: end - 10)
    XCTAssertEqual(depth(bottom), 10, "The bottom fade shrinks away toward the end")
    scroll(to: end)
    XCTAssertEqual(depth(top), length)
    XCTAssertEqual(depth(bottom), 0, "Nothing is below the end")
    assertTestProcessIsNotFrontmost()
  }

  func testLongResultUsesIncrementalNaturalTextLayoutWithoutNestedScrolling() {
    let resultView = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: ResultTextContainer.minimumHeight)
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
    XCTAssertFalse(resultView.textView.isAutomaticTextCompletionEnabled)
    XCTAssertEqual(resultView.textView.enabledTextCheckingTypes, 0)
  }

  func testHighFrequencyResultUpdatesCoalesceNaturalHeightLayout() {
    let entryID = UUID()
    let storage = ResultTextStorage("")
    let resultView = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: ResultTextContainer.minimumHeight)
    )
    let coordinator = ResultTextCoordinator()

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
    XCTAssertGreaterThan(resultView.naturalTextHeight, ResultTextContainer.minimumHeight)
    XCTAssertEqual(resultView.intrinsicContentSize.height, resultView.naturalTextHeight)
  }

  /// A streamed delta reaches the renderer through the storage notification
  /// and grows the pane, without SwiftUI re-rendering the whole panel.
  func testStreamingDeltaGrowsTheResultPaneThroughTheNativeRenderer() async throws {
    let record = ResultRecord(
      mode: .translate,
      source: "Submitted source",
      outputLanguage: .english,
      phase: .streaming
    )
    let model = AppModel(inputText: "Submitted source")
    model.setResultForTesting(record)
    model.setGenerationStateForTesting(.revealing(entryID: record.id))
    let controller = makeHiddenPanel(model: model)
    let contentView = try XCTUnwrap(controller.contentView)
    let scrollView = try XCTUnwrap(firstResultScrollView(in: contentView))
    let container = scrollView.container
    let initialHeight = controller.panel.frame.height

    record.appendPresentationDelta(
      (1...24).map { "Streamed result line \($0)" }.joined(separator: "\n")
    )
    try await waitUntil(timeout: .seconds(2)) {
      contentView.layoutSubtreeIfNeeded()
      return container.naturalTextHeight > 300 && controller.panel.frame.height > initialHeight
    }

    XCTAssertEqual(container.renderedString, record.result)
    XCTAssertFalse(container.selectionTextIsMaterializedForTesting)
    XCTAssertTrue(container.streamingCaretIsVisible)
    assertTestProcessIsNotFrontmost()
  }

  func testNaturalResultRelayoutsWhenThePaneWidthChanges() async throws {
    let entryID = UUID()
    let storage = ResultTextStorage(
      String(repeating: "A translated paragraph must reflow with its pane. ", count: 80)
    )
    let resultView = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: ResultTextContainer.minimumHeight)
    )
    let coordinator = ResultTextCoordinator()
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
      resultView.naturalTextHeight > ResultTextContainer.minimumHeight
        && abs(resultView.textView.frame.height - resultView.naturalTextHeight) <= 0.5
    }
    let wideHeight = resultView.naturalTextHeight

    resultView.setFrameSize(NSSize(width: 320, height: ResultTextContainer.minimumHeight))
    try await waitUntil(timeout: .seconds(1)) {
      resultView.naturalTextHeight > wideHeight
        && abs(resultView.textView.frame.height - resultView.naturalTextHeight) <= 0.5
    }

    XCTAssertGreaterThan(resultView.naturalTextHeight, wideHeight)
    XCTAssertEqual(resultView.textView.frame.height, resultView.naturalTextHeight)
  }

  func testStreamingResultDefersSelectionUntilCompletion() {
    let resultView = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: ResultTextContainer.minimumHeight)
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

    resultView.activateSelectionForTesting()
    XCTAssertTrue(resultView.selectionTextIsMaterializedForTesting)
    XCTAssertTrue(resultView.textView.isSelectable)
    XCTAssertEqual(resultView.textView.string, "Selectable completed result")
  }

  func testStreamingCompletionKeepsTheResultHeightStructurallyStable() {
    let resultView = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 320, height: ResultTextContainer.minimumHeight)
    )
    resultView.replaceText(String(repeating: "Stable streamed line. ", count: 60))
    resultView.setStreaming(true)
    let streamingHeight = resultView.updateDocumentLayout()

    resultView.setStreaming(false)
    let completedHeight = resultView.updateDocumentLayout()

    XCTAssertEqual(completedHeight, streamingHeight, accuracy: 0.5)
    XCTAssertFalse(resultView.selectionTextIsMaterializedForTesting)
  }

  func testStreamingResultGrowsInsideReservedTextViewCapacity() {
    let resultView = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: ResultTextContainer.minimumHeight)
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
  }

  func testCoalescedStreamingRevisionsAppendOnlyTheMissingSuffix() {
    let entryID = UUID()
    let storage = ResultTextStorage("Initial")
    let resultView = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: ResultTextContainer.minimumHeight)
    )
    let coordinator = ResultTextCoordinator()

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

  func testReplacingTheResultTextClearsTheRenderer() {
    let resultView = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: ResultTextContainer.minimumHeight)
    )
    resultView.replaceText("OLD_RESULT_MUST_NOT_SURVIVE_REPLACEMENT")
    XCTAssertEqual(resultView.renderedString, "OLD_RESULT_MUST_NOT_SURVIVE_REPLACEMENT")

    resultView.replaceText("")
    _ = resultView.updateDocumentLayout()

    XCTAssertEqual(resultView.renderedString, "")
    XCTAssertEqual(resultView.naturalTextHeight, ResultTextContainer.minimumHeight)
  }

  func testStreamingResultUsesAnInlineCaretAndRemovesItOnCompletion() throws {
    let resultView = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: ResultTextContainer.minimumHeight)
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
      "Streaming motion T2: glyphs fade in behind the caret from fully transparent"
    )
    XCTAssertEqual(resultView.glyphRevealCommittedLengthForTesting, 0)
    XCTAssertGreaterThan(resultView.streamingCaretFrame.minX, 0)

    resultView.setStreaming(false)
    XCTAssertFalse(resultView.streamingCaretIsVisible)
    // The reveal lasts 120 ms and commits on a display pulse; a busy CI runner can take longer
    // than that to deliver the pulse, so wait for the commit instead of a fixed interval.
    let revealDeadline = Date().addingTimeInterval(2)
    while resultView.glyphRevealFragmentCountForTesting > 0, Date() < revealDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertEqual(resultView.glyphRevealFragmentCountForTesting, 0)
    XCTAssertEqual(resultView.glyphRevealCommittedLengthForTesting, 4)
  }

  func testGlyphFadeMatchesTheDesignOneHundredTwentyMillisecondEaseOut() {
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

  func testEachPresentedGlyphRunGetsItsOwnRevealAndCommitsInOrder() throws {
    let resultView = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 320, height: ResultTextContainer.minimumHeight)
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

    XCTAssertGreaterThan(expandedHeight, ResultTextContainer.minimumHeight)
    XCTAssertEqual(resultView.glyphRevealFragmentCountForTesting, 2)
    XCTAssertEqual(resultView.glyphRevealAnimationForTesting?.duration, 0.12)
    let blurAnimation = try XCTUnwrap(resultView.glyphRevealBlurAnimationForTesting)
    XCTAssertEqual(blurAnimation.duration, 0.12)
    let fragmentFrames = resultView.glyphRevealFragmentFramesForTesting
    XCTAssertEqual(fragmentFrames.count, 2)
    XCTAssertGreaterThan(fragmentFrames[1].minY, fragmentFrames[0].minY)
    XCTAssertEqual(resultView.glyphRevealCommittedLengthForTesting, 0)

    resultView.commitCompletedGlyphReveals(now: 0)
    XCTAssertEqual(resultView.glyphRevealFragmentCountForTesting, 2)
    resultView.commitCompletedGlyphReveals(now: .greatestFiniteMagnitude)
    XCTAssertEqual(resultView.glyphRevealFragmentCountForTesting, 0)
    XCTAssertEqual(
      resultView.glyphRevealCommittedLengthForTesting,
      "First line grows.\nSecond line grows.".utf16.count
    )
  }

  func testResultTypographyFollowsTheOutputLanguage() {
    FontRegistrar.registerBundledFonts()
    let latin = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: ResultTextContainer.minimumHeight)
    )
    latin.language = .english
    latin.replaceText("Latin result")
    _ = latin.updateDocumentLayout()
    let cjk = ResultTextContainer(
      frame: NSRect(x: 0, y: 0, width: 720, height: ResultTextContainer.minimumHeight)
    )
    cjk.language = .chinese
    cjk.replaceText("中文结果")
    _ = cjk.updateDocumentLayout()

    latin.activateSelectionForTesting()
    cjk.activateSelectionForTesting()
    let latinFont = latin.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    let cjkFont = cjk.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    XCTAssertEqual(latinFont?.familyName, "Source Serif 4")
    XCTAssertEqual(cjkFont?.familyName, "Noto Serif SC")
    XCTAssertEqual(latin.naturalTextHeight, 29, accuracy: 0.5)
    XCTAssertEqual(cjk.naturalTextHeight, 31, accuracy: 0.5)
  }

  /// ⌘C: a native selection keeps the system copy; otherwise the result is
  /// copied, even while the editable source is first responder.
  func testResultCopyShortcutDefersOnlyToANativeSelection() throws {
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
    XCTAssertTrue(CopyShortcutRouting.isResultShortcut(commandC))
    XCTAssertFalse(CopyShortcutRouting.isResultShortcut(commandShiftC))
    XCTAssertTrue(CopyShortcutRouting.isImageShortcut(commandShiftC), "⇧⌘C copies the share card")
    XCTAssertFalse(CopyShortcutRouting.isImageShortcut(commandC))

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
    textView.string = "Editable source"
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    XCTAssertFalse(
      CopyShortcutRouting.nativeTextResponderOwnsCopy(window: window),
      "No selection in the source: ⌘C copies the result")

    textView.setSelectedRange(NSRange(location: 0, length: 8))
    XCTAssertTrue(CopyShortcutRouting.nativeTextResponderOwnsCopy(window: window))
    assertTestProcessIsNotFrontmost()
  }
}

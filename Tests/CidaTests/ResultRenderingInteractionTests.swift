import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import Cida

@MainActor
extension InteractionReproductionTests {
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
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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
